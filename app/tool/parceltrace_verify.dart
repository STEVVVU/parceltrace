import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localsend_app/parceltrace/artifact_bundle.dart';

Future<void> main() async {
  final evidenceDirectory = Directory('.verification-evidence/parceltrace');
  await evidenceDirectory.create(recursive: true);
  final workspace = await Directory.systemTemp.createTemp('parceltrace-verification-');
  final evidence = <String, Object?>{'driver': 'app/tool/parceltrace_verify.dart', 'actions': <Object?>[]};
  final actions = evidence['actions']! as List<Object?>;
  final evidenceFile = File('${evidenceDirectory.path}${Platform.pathSeparator}latest.json');
  try {
    var randomState = 0x6d2b79f5;
    final source = Uint8List.fromList(
      List<int>.generate(12 * 1024 * 1024, (_) {
        randomState ^= randomState << 13;
        randomState ^= randomState >>> 17;
        randomState ^= randomState << 5;
        randomState &= 0xffffffff;
        return randomState & 0xff;
      }),
    );
    final bundle = ArtifactBundle.fromBytes(fileName: 'recovered.bin', bytes: source);
    final sourceHash = sha256.convert(source).toString();
    final allParts = bundle.createParts();
    _check(bundle.manifest.chunks.length > 1 && allParts.length > 1, 'normal send batch must contain multiple completed part files');
    actions.add({
      'action': 'create',
      'manifestId': bundle.manifest.id,
      'chunkCount': bundle.manifest.chunks.length,
      'partCount': allParts.length,
      'sourceBytes': source.length,
    });

    final corrupt = Uint8List.fromList(allParts.first)..[allParts.first.length - 1] ^= 1;
    await _expectFailure(() => ArtifactPart.parse(corrupt), 'corrupted part rejected');
    await _expectFailure(() => ArtifactPart.parse(allParts.first.sublist(0, allParts.first.length - 1)), 'truncated part rejected');
    await _expectFailure(
      () => ArtifactPart.parse(Uint8List(artifactBundleMaxPartFileBytes + 1)),
      'oversized part rejected',
    );
    final threeChunkPart = bundle.createParts(onlyChunks: [0, 1, 2]).single;
    final manifestLength = ByteData.sublistView(threeChunkPart).getUint32(8, Endian.big);
    final firstRecord = 8 + 4 + manifestLength + 4;
    final firstLength = ByteData.sublistView(threeChunkPart).getUint32(firstRecord + 4, Endian.big);
    final secondRecord = firstRecord + 8 + firstLength;
    final duplicate = Uint8List.fromList(threeChunkPart);
    ByteData.sublistView(duplicate).setUint32(secondRecord, 0, Endian.big);
    await _expectFailure(() => ArtifactPart.parse(duplicate), 'duplicate part record rejected');
    final reordered = Uint8List.fromList(threeChunkPart);
    ByteData.sublistView(reordered).setUint32(firstRecord, 1, Endian.big);
    await _expectFailure(() => ArtifactPart.parse(reordered), 'reordered part record rejected');
    actions.add({
      'action': 'reject-corrupt-truncated-oversized-duplicate-and-reordered-packs',
      'result': 'all rejected before durable import',
    });

    final initialParts = [allParts.first];
    final receiverRoot = Directory('${workspace.path}${Platform.pathSeparator}receiver');
    final receiver = await BundleReceiverStore.open(receiverRoot);
    for (final part in initialParts) {
      await receiver.importPart(part);
    }
    final missingBeforeRestart = await receiver.missingChunks();
    _check(missingBeforeRestart.isNotEmpty, 'partial import reports missing chunks');
    final reopened = await BundleReceiverStore.open(receiverRoot);
    final missingAfterRestart = await reopened.missingChunks();
    _check(_same(missingBeforeRestart, missingAfterRestart), 'missing chunk state survives store reopen');
    actions.add({
      'action': 'partial-import-and-reopen',
      'completedDefaultPartsImported': initialParts.length,
      'availableChunks': bundle.manifest.chunks.length - missingAfterRestart.length,
      'missingChunks': missingAfterRestart.length,
    });

    final request = await reopened.exportRepairRequest();
    final parsedRequest = ArtifactRepairRequest.parse(request, bundle.manifest);
    final repairBytes = parsedRequest.missingChunks.fold<int>(0, (sum, index) => sum + bundle.manifest.chunks[index].length);
    final repairParts = createRepairParts(sourceBytes: source, fileName: 'recovered.bin', requestBytes: request);
    _check(repairBytes < source.length && repairParts.isNotEmpty, 'repair carries only missing chunk bytes');
    for (final part in repairParts) {
      await reopened.importPart(part);
    }
    for (final part in repairParts) {
      await reopened.importPart(part);
    }
    _check((await reopened.missingChunks()).isEmpty, 'duplicate repair import is idempotent');
    final rebuilt = await reopened.reconstruct();
    final reconstructedHash = sha256.convert(rebuilt).toString();
    _check(reconstructedHash == sourceHash && _same(rebuilt, source), 'repair reconstructs the exact original bytes');
    actions.add({
      'action': 'repair-and-reconstruct',
      'repairBytes': repairBytes,
      'wholeFileRetryBytes': source.length,
      'duplicateRepairImport': 'idempotent',
      'reconstructedSha256': reconstructedHash,
      'exactByteMatch': true,
    });

    final foreign = ArtifactBundle.fromBytes(fileName: 'foreign.bin', bytes: Uint8List.fromList([...source]..[0] ^= 1));
    await _expectFailure(() => reopened.importPart(foreign.createParts().first), 'foreign manifest rejected');
    actions.add({'action': 'reject-foreign-manifest', 'result': 'rejected'});

    final changedSource = Uint8List.fromList([...source]..[7] ^= 1);
    await _expectFailure(
      () => createRepairParts(sourceBytes: changedSource, fileName: 'recovered.bin', requestBytes: request),
      'changed source rejected during repair',
    );
    actions.add({'action': 'reject-changed-source', 'result': 'rejected'});

    await _expectFailure(() => ArtifactBundle.fromBytes(fileName: '../escape.bin', bytes: source), 'unsafe source name rejected');
    final hostileManifest = Map<String, Object?>.from(bundle.manifest.toJson())
      ..['fileName'] = '../escape.bin'
      ..remove('id');
    hostileManifest['id'] = sha256.convert(utf8.encode(jsonEncode(hostileManifest))).toString();
    await _expectFailure(() => ArtifactManifest.parse(utf8.encode(jsonEncode(hostileManifest))), 'path-escaping manifest rejected');
    actions.add({'action': 'reject-unsafe-name-and-path-escape', 'result': 'rejected at manifest boundary'});

    final emptyBundle = ArtifactBundle.fromBytes(fileName: 'empty.dat', bytes: const []);
    final emptyStore = await BundleReceiverStore.open(Directory('${workspace.path}${Platform.pathSeparator}empty-receiver'));
    await emptyStore.importPart(emptyBundle.createParts().single);
    _check((await emptyStore.reconstruct()).isEmpty, 'empty files reconstruct from a manifest-only part');
    actions.add({'action': 'empty-file', 'result': 'manifest-only pack reconstructed'});

    evidence['result'] = 'passed';
  } catch (error) {
    evidence['result'] = 'failed';
    evidence['failure'] = error.toString();
    rethrow;
  } finally {
    try {
      if (await workspace.exists()) await workspace.delete(recursive: true);
    } catch (error) {
      evidence['cleanupFailure'] = error.toString();
    }
    evidence['temporaryWorkspaceRemoved'] = !await workspace.exists();
    await evidenceFile.writeAsString(const JsonEncoder.withIndent('  ').convert(evidence), flush: true);
  }
  final savedEvidence = jsonDecode(await evidenceFile.readAsString()) as Map<String, dynamic>;
  _check(savedEvidence['temporaryWorkspaceRemoved'] == true, 'evidence confirms cleanup completed');
  _check(await evidenceFile.exists(), 'evidence survives temporary-workspace cleanup');
  stdout.writeln('Parceltrace verification ${savedEvidence['result']}. Evidence: ${evidenceFile.path}');
}

Future<void> _expectFailure(FutureOr<Object?> Function() operation, String label) async {
  try {
    await operation();
  } on FormatException {
    return;
  } on FileSystemException {
    return;
  }
  throw StateError('Expected rejection: $label');
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

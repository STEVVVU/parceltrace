import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:localsend_app/parceltrace/artifact_bundle.dart';
import 'package:test/test.dart';

void main() {
  group('ArtifactBundle', () {
    test('chunking and manifest identity are deterministic and bounded', () {
      final source = Uint8List.fromList(List<int>.generate(2 * 1024 * 1024 + 37, (index) => (index * 73 + index ~/ 5) & 0xff));
      final first = ArtifactBundle.fromBytes(fileName: 'payload.bin', bytes: source);
      final second = ArtifactBundle.fromBytes(fileName: 'payload.bin', bytes: source);

      expect(first.manifest.id, second.manifest.id);
      expect(first.manifest.chunks.map((chunk) => chunk.length), second.manifest.chunks.map((chunk) => chunk.length));
      expect(first.manifest.chunks.length, greaterThan(1));
      expect(first.manifest.chunks.every((chunk) => chunk.length <= artifactBundleMaxChunkBytes), isTrue);
      expect(ArtifactManifest.parse(first.manifest.encode()).id, first.manifest.id);
    });

    test('rejects unsafe names and sources above the bound', () {
      expect(() => ArtifactBundle.fromBytes(fileName: '../outside', bytes: const []), throwsFormatException);
      expect(
        () => ArtifactBundle.fromBytes(fileName: 'large.bin', bytes: Uint8List(artifactBundleMaxFileBytes + 1)),
        throwsFormatException,
      );
    });

    test('imports incomplete parts, reopens, repairs, and verifies final output', () async {
      final source = Uint8List.fromList(List<int>.generate(2 * 1024 * 1024, (index) => (index * 19 ^ index ~/ 3) & 0xff));
      final bundle = ArtifactBundle.fromBytes(fileName: 'payload.bin', bytes: source);
      expect(bundle.manifest.chunks.length, greaterThan(1));
      final root = await Directory.systemTemp.createTemp('parceltrace-test-');
      addTearDown(() => root.delete(recursive: true));
      final store = await BundleReceiverStore.open(Directory('${root.path}${Platform.pathSeparator}receiver'));
      await store.importPart(bundle.createParts(onlyChunks: [0]).single);
      final missing = await store.missingChunks();
      expect(missing, isNotEmpty);

      final reopened = await BundleReceiverStore.open(store.root);
      expect(await reopened.missingChunks(), missing);
      final request = await reopened.exportRepairRequest();
      final repairParts = createRepairParts(sourceBytes: source, fileName: 'payload.bin', requestBytes: request);
      for (final part in repairParts) {
        await reopened.importPart(part);
      }

      final reconstructed = await reopened.reconstruct();
      expect(sha256.convert(reconstructed), sha256.convert(source));
      expect(reconstructed, orderedEquals(source));
    });

    test('rejects corrupt and foreign parts before adding them to a receiver', () async {
      final source = Uint8List.fromList(List<int>.generate(100_000, (index) => index & 0xff));
      final bundle = ArtifactBundle.fromBytes(fileName: 'payload.bin', bytes: source);
      final root = await Directory.systemTemp.createTemp('parceltrace-test-');
      addTearDown(() => root.delete(recursive: true));
      final store = await BundleReceiverStore.open(root);
      final corrupted = Uint8List.fromList(bundle.createParts().single)..[bundle.createParts().single.length - 1] ^= 1;
      await expectLater(store.importPart(corrupted), throwsFormatException);
      expect(store.manifest, isNull);
      await store.importPart(bundle.createParts().single);

      final foreign = ArtifactBundle.fromBytes(fileName: 'other.bin', bytes: Uint8List.fromList([...source]..[0] ^= 1));
      await expectLater(store.importPart(foreign.createParts().single), throwsFormatException);
      expect(store.manifest?.id, bundle.manifest.id);
    });

    test('rejects truncated, oversized, duplicate, and reordered part records', () {
      final source = Uint8List.fromList(List<int>.generate(3 * 1024 * 1024, (index) => (index * 31 ^ index ~/ 7) & 0xff));
      final bundle = ArtifactBundle.fromBytes(fileName: 'payload.bin', bytes: source);
      expect(bundle.manifest.chunks.length, greaterThan(2));
      final valid = bundle.createParts(onlyChunks: [0, 1, 2]).single;
      expect(() => ArtifactPart.parse(valid.sublist(0, valid.length - 1)), throwsFormatException);
      expect(() => ArtifactPart.parse(Uint8List(artifactBundleMaxPartFileBytes + 1)), throwsFormatException);

      final manifestLength = ByteData.sublistView(valid).getUint32(8, Endian.big);
      final firstRecord = 8 + 4 + manifestLength + 4;
      final firstLength = ByteData.sublistView(valid).getUint32(firstRecord + 4, Endian.big);
      final secondRecord = firstRecord + 8 + firstLength;

      final duplicate = Uint8List.fromList(valid);
      ByteData.sublistView(duplicate).setUint32(secondRecord, 0, Endian.big);
      expect(() => ArtifactPart.parse(duplicate), throwsFormatException);

      final reordered = Uint8List.fromList(valid);
      ByteData.sublistView(reordered).setUint32(firstRecord, 1, Endian.big);
      expect(() => ArtifactPart.parse(reordered), throwsFormatException);
    });

    test('clears only the active receiver session', () async {
      final first = ArtifactBundle.fromBytes(fileName: 'first.bin', bytes: Uint8List.fromList([1, 2, 3]));
      final second = ArtifactBundle.fromBytes(fileName: 'second.bin', bytes: Uint8List.fromList([4, 5, 6]));
      final root = await Directory.systemTemp.createTemp('parceltrace-test-');
      addTearDown(() => root.delete(recursive: true));
      final store = await BundleReceiverStore.open(root);
      await store.importPart(first.createParts().single);
      await store.clearSession();
      expect(store.manifest, isNull);
      await store.importPart(second.createParts().single);
      expect(await store.reconstruct(), [4, 5, 6]);
    });

    test('rejects a changed source for a manifest-bound repair request', () {
      final source = Uint8List.fromList(List<int>.generate(150_000, (index) => index & 0xff));
      final bundle = ArtifactBundle.fromBytes(fileName: 'payload.bin', bytes: source);
      final request = ArtifactRepairRequest(manifestId: bundle.manifest.id, missingChunks: [0]).encode();
      final changed = Uint8List.fromList([...source]..[3] ^= 1);
      expect(() => createRepairParts(sourceBytes: changed, fileName: 'payload.bin', requestBytes: request), throwsFormatException);
    });

    test('exports an empty file as a manifest-only pack', () async {
      final bundle = ArtifactBundle.fromBytes(fileName: 'empty.dat', bytes: const []);
      final part = ArtifactPart.parse(bundle.createParts().single);
      expect(part.chunks, isEmpty);
      final root = await Directory.systemTemp.createTemp('parceltrace-test-');
      addTearDown(() => root.delete(recursive: true));
      final store = await BundleReceiverStore.open(root);
      await store.importPart(bundle.createParts().single);
      expect(await store.reconstruct(), isEmpty);
    });
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const int artifactBundleMaxFileBytes = 32 * 1024 * 1024;
const int artifactBundleMinChunkBytes = 64 * 1024;
const int artifactBundleTargetChunkBytes = 256 * 1024;
const int artifactBundleMaxChunkBytes = 1024 * 1024;
const int artifactBundleMaxPartBytes = 4 * 1024 * 1024;
const int _maxManifestBytes = 256 * 1024;
const int artifactBundleMaxPartFileBytes = artifactBundleMaxPartBytes + _maxManifestBytes + 32;
const String _packMagic = 'PTPACK01';
const String _chunkingAlgorithm = 'gear-fastcdc-bounded-v1';

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

T _expectType<T>(Object? value, String message) {
  if (value is T) return value;
  throw FormatException(message);
}

bool _isDigest(Object? value) => value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

bool _hasExactKeys(Map<Object?, Object?> map, Set<String> keys) =>
    map.length == keys.length && map.keys.every((key) => key is String && keys.contains(key));

bool _isSafeFileName(String value) {
  final deviceName = value.split('.').first.toUpperCase();
  return value.isNotEmpty &&
      value.length <= 255 &&
      value != '.' &&
      value != '..' &&
      !value.endsWith('.') &&
      value == value.trim() &&
      !RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$').hasMatch(deviceName) &&
      !value.contains('/') &&
      !value.contains(r'\') &&
      !value.contains(':') &&
      !value.contains('\u0000') &&
      !value.contains(RegExp(r'[\x00-\x1f\x7f]'));
}

class ArtifactChunk {
  final int index;
  final int offset;
  final int length;
  final String sha256;

  const ArtifactChunk({required this.index, required this.offset, required this.length, required this.sha256});

  Map<String, Object> toJson() => {'index': index, 'offset': offset, 'length': length, 'sha256': sha256};

  static ArtifactChunk fromJson(Object? value, int expectedIndex, int expectedOffset) {
    final rawMap = _expectType<Map>(value, 'Chunk record must be an object');
    _require(_hasExactKeys(rawMap, {'index', 'offset', 'length', 'sha256'}), 'Chunk record has unknown or missing fields');
    final map = Map<String, Object?>.from(rawMap);
    final index = map['index'];
    final offset = map['offset'];
    final length = map['length'];
    final digest = map['sha256'];
    if (index is! int || index != expectedIndex) throw const FormatException('Chunk indices must be contiguous');
    if (offset is! int || offset != expectedOffset) throw const FormatException('Chunk offsets must be contiguous');
    if (length is! int || length <= 0 || length > artifactBundleMaxChunkBytes) {
      throw const FormatException('Chunk length is outside bounds');
    }
    _require(_isDigest(digest), 'Chunk digest is invalid');
    return ArtifactChunk(index: index, offset: offset, length: length, sha256: digest as String);
  }
}

class ArtifactManifest {
  final String fileName;
  final int fileSize;
  final String fileSha256;
  final List<ArtifactChunk> chunks;
  final String id;

  const ArtifactManifest._({required this.fileName, required this.fileSize, required this.fileSha256, required this.chunks, required this.id});

  Map<String, Object> _unsignedJson() => {
    'version': 1,
    'fileName': fileName,
    'fileSize': fileSize,
    'fileSha256': fileSha256,
    'chunking': {
      'algorithm': _chunkingAlgorithm,
      'minBytes': artifactBundleMinChunkBytes,
      'targetBytes': artifactBundleTargetChunkBytes,
      'maxBytes': artifactBundleMaxChunkBytes,
    },
    'chunks': chunks.map((chunk) => chunk.toJson()).toList(growable: false),
  };

  Map<String, Object> toJson() => {..._unsignedJson(), 'id': id};

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static ArtifactManifest parse(List<int> bytes) {
    _require(bytes.length <= _maxManifestBytes, 'Manifest exceeds the size limit');
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Manifest is not valid UTF-8 JSON');
    }
    _require(decoded is Map, 'Manifest must be an object');
    final rawMap = _expectType<Map>(decoded, 'Manifest must be an object');
    _require(
      _hasExactKeys(rawMap, {'version', 'fileName', 'fileSize', 'fileSha256', 'chunking', 'chunks', 'id'}),
      'Manifest has unknown or missing fields',
    );
    final map = Map<String, Object?>.from(rawMap);
    _require(map['version'] == 1, 'Unsupported manifest version');
    final name = _expectType<String>(map['fileName'], 'Manifest filename is invalid');
    final size = _expectType<int>(map['fileSize'], 'Manifest file size is invalid');
    final fileDigest = map['fileSha256'];
    final claimedId = map['id'];
    _require(_isSafeFileName(name), 'Manifest filename is unsafe');
    _require(size >= 0 && size <= artifactBundleMaxFileBytes, 'Manifest file size is outside bounds');
    _require(_isDigest(fileDigest), 'Whole-file digest is invalid');
    _require(_isDigest(claimedId), 'Manifest id is invalid');
    final chunking = map['chunking'];
    final chunkingMap = _expectType<Map>(chunking, 'Chunking configuration is missing');
    _require(
      _hasExactKeys(chunkingMap, {'algorithm', 'minBytes', 'targetBytes', 'maxBytes'}),
      'Chunking configuration has unknown or missing fields',
    );
    _require(
      chunkingMap['algorithm'] == _chunkingAlgorithm &&
          chunkingMap['minBytes'] == artifactBundleMinChunkBytes &&
          chunkingMap['targetBytes'] == artifactBundleTargetChunkBytes &&
          chunkingMap['maxBytes'] == artifactBundleMaxChunkBytes,
      'Unsupported chunking configuration',
    );
    final rawChunks = _expectType<List>(map['chunks'], 'Chunk list is invalid');
    _require(rawChunks.length <= (artifactBundleMaxFileBytes ~/ artifactBundleMinChunkBytes) + 1, 'Chunk list is invalid');
    final chunks = <ArtifactChunk>[];
    var offset = 0;
    for (var i = 0; i < rawChunks.length; i++) {
      final chunk = ArtifactChunk.fromJson(rawChunks[i], i, offset);
      chunks.add(chunk);
      offset += chunk.length;
    }
    _require(offset == size, 'Chunk lengths do not match the file size');
    _require(size != 0 || chunks.isEmpty, 'Empty files cannot contain chunks');
    final manifest = ArtifactManifest._(
      fileName: name,
      fileSize: size,
      fileSha256: fileDigest as String,
      chunks: List.unmodifiable(chunks),
      id: claimedId as String,
    );
    _require(_sha256(utf8.encode(jsonEncode(manifest._unsignedJson()))) == manifest.id, 'Manifest identity does not match its contents');
    return manifest;
  }
}

class ArtifactPart {
  final ArtifactManifest manifest;
  final Map<int, Uint8List> chunks;

  ArtifactPart({required this.manifest, required Map<int, Uint8List> chunks}) : chunks = Map.unmodifiable(chunks);

  Uint8List encode() {
    final manifestBytes = manifest.encode();
    _require(manifestBytes.length <= _maxManifestBytes, 'Manifest exceeds the size limit');
    final sortedIndices = chunks.keys.toList()..sort();
    var total = 8 + 4 + manifestBytes.length + 4;
    for (final index in sortedIndices) {
      _require(index >= 0 && index < manifest.chunks.length, 'Part contains an unknown chunk');
      final bytes = chunks[index]!;
      final description = manifest.chunks[index];
      _require(bytes.length == description.length && _sha256(bytes) == description.sha256, 'Part chunk does not match the manifest');
      total += 8 + bytes.length;
    }
    _require(total <= artifactBundleMaxPartFileBytes, 'Part exceeds the size limit');
    final data = ByteData(total);
    final output = Uint8List.view(data.buffer);
    var cursor = 0;
    output.setRange(cursor, cursor + 8, ascii.encode(_packMagic));
    cursor += 8;
    data.setUint32(cursor, manifestBytes.length, Endian.big);
    cursor += 4;
    output.setRange(cursor, cursor + manifestBytes.length, manifestBytes);
    cursor += manifestBytes.length;
    data.setUint32(cursor, sortedIndices.length, Endian.big);
    cursor += 4;
    for (final index in sortedIndices) {
      final bytes = chunks[index]!;
      data.setUint32(cursor, index, Endian.big);
      data.setUint32(cursor + 4, bytes.length, Endian.big);
      cursor += 8;
      output.setRange(cursor, cursor + bytes.length, bytes);
      cursor += bytes.length;
    }
    return output;
  }

  static ArtifactPart parse(List<int> bytes) {
    _require(bytes.length <= artifactBundleMaxPartFileBytes, 'Part exceeds the size limit');
    _require(bytes.length >= 16, 'Part is truncated');
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final input = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    _require(ascii.decode(input.sublist(0, 8), allowInvalid: true) == _packMagic, 'Part magic is invalid');
    var cursor = 8;
    final manifestLength = data.getUint32(cursor, Endian.big);
    cursor += 4;
    _require(
      manifestLength > 0 && manifestLength <= _maxManifestBytes && cursor + manifestLength + 4 <= bytes.length,
      'Part manifest length is invalid',
    );
    final manifest = ArtifactManifest.parse(input.sublist(cursor, cursor + manifestLength));
    cursor += manifestLength;
    final chunkCount = data.getUint32(cursor, Endian.big);
    cursor += 4;
    _require(chunkCount <= manifest.chunks.length, 'Part has too many chunks');
    _require((manifest.fileSize == 0 && chunkCount == 0) || (manifest.fileSize > 0 && chunkCount > 0), 'Part must contain at least one file chunk');
    final chunks = <int, Uint8List>{};
    var previousIndex = -1;
    for (var i = 0; i < chunkCount; i++) {
      _require(cursor + 8 <= bytes.length, 'Part chunk header is truncated');
      final index = data.getUint32(cursor, Endian.big);
      final length = data.getUint32(cursor + 4, Endian.big);
      cursor += 8;
      _require(
        index > previousIndex && index < manifest.chunks.length && !chunks.containsKey(index),
        'Part has a duplicate, reordered, or unknown chunk',
      );
      previousIndex = index;
      final description = manifest.chunks[index];
      _require(length == description.length && cursor + length <= bytes.length, 'Part chunk length is invalid');
      final content = Uint8List.fromList(input.sublist(cursor, cursor + length));
      _require(_sha256(content) == description.sha256, 'Part chunk digest does not match');
      chunks[index] = content;
      cursor += length;
    }
    _require(cursor == bytes.length, 'Part contains trailing bytes');
    return ArtifactPart(manifest: manifest, chunks: chunks);
  }
}

class ArtifactBundle {
  final ArtifactManifest manifest;
  final List<Uint8List> _chunkBytes;

  ArtifactBundle._(this.manifest, this._chunkBytes);

  factory ArtifactBundle.fromBytes({required String fileName, required List<int> bytes}) {
    _require(_isSafeFileName(fileName), 'Filename is unsafe');
    _require(bytes.length <= artifactBundleMaxFileBytes, 'Source exceeds the 32 MiB limit');
    final source = Uint8List.fromList(bytes);
    final chunkBytes = _splitChunks(source);
    var offset = 0;
    final chunks = <ArtifactChunk>[];
    for (var index = 0; index < chunkBytes.length; index++) {
      final chunk = chunkBytes[index];
      chunks.add(ArtifactChunk(index: index, offset: offset, length: chunk.length, sha256: _sha256(chunk)));
      offset += chunk.length;
    }
    final unsigned = {
      'version': 1,
      'fileName': fileName,
      'fileSize': source.length,
      'fileSha256': _sha256(source),
      'chunking': {
        'algorithm': _chunkingAlgorithm,
        'minBytes': artifactBundleMinChunkBytes,
        'targetBytes': artifactBundleTargetChunkBytes,
        'maxBytes': artifactBundleMaxChunkBytes,
      },
      'chunks': chunks.map((chunk) => chunk.toJson()).toList(growable: false),
    };
    final manifest = ArtifactManifest._(
      fileName: fileName,
      fileSize: source.length,
      fileSha256: _sha256(source),
      chunks: List.unmodifiable(chunks),
      id: _sha256(utf8.encode(jsonEncode(unsigned))),
    );
    return ArtifactBundle._(manifest, chunkBytes);
  }

  List<Uint8List> createParts({Iterable<int>? onlyChunks}) {
    final selected = onlyChunks?.toSet() ?? {for (var i = 0; i < _chunkBytes.length; i++) i};
    for (final index in selected) {
      _require(index >= 0 && index < _chunkBytes.length, 'Requested chunk index is invalid');
    }
    if (selected.isEmpty) {
      return onlyChunks == null ? [ArtifactPart(manifest: manifest, chunks: const {}).encode()] : const [];
    }
    final sorted = selected.toList()..sort();
    final groups = <Map<int, Uint8List>>[];
    var current = <int, Uint8List>{};
    var currentBytes = 16 + manifest.encode().length;
    for (final index in sorted) {
      final chunk = _chunkBytes[index];
      if (current.isNotEmpty && currentBytes + chunk.length + 8 > artifactBundleMaxPartBytes) {
        groups.add(current);
        current = <int, Uint8List>{};
        currentBytes = 16 + manifest.encode().length;
      }
      current[index] = chunk;
      currentBytes += chunk.length + 8;
    }
    groups.add(current);
    return groups.map((group) => ArtifactPart(manifest: manifest, chunks: group).encode()).toList(growable: false);
  }
}

List<Uint8List> _splitChunks(Uint8List bytes) {
  if (bytes.isEmpty) return const [];
  final result = <Uint8List>[];
  var start = 0;
  var gearHash = 0;
  for (var index = 0; index < bytes.length; index++) {
    gearHash = ((gearHash << 1) + _gear[bytes[index]]) & 0xffffffff;
    final length = index - start + 1;
    final reachedLimit = length >= artifactBundleMaxChunkBytes;
    final reachedBoundary =
        length >= artifactBundleMinChunkBytes && (length < artifactBundleTargetChunkBytes ? (gearHash & 0x3ffff) == 0 : (gearHash & 0x1ffff) == 0);
    if (reachedLimit || reachedBoundary) {
      result.add(Uint8List.fromList(bytes.sublist(start, index + 1)));
      start = index + 1;
      gearHash = 0;
    }
  }
  if (start < bytes.length) result.add(Uint8List.fromList(bytes.sublist(start)));
  return result;
}

final List<int> _gear = List<int>.generate(256, (index) {
  var value = (index + 1) * 0x9e3779b9;
  value ^= value >>> 16;
  value = (value * 0x85ebca6b) & 0xffffffff;
  value ^= value >>> 13;
  return value & 0xffffffff;
}, growable: false);

class ArtifactRepairRequest {
  final String manifestId;
  final List<int> missingChunks;

  ArtifactRepairRequest({required this.manifestId, required Iterable<int> missingChunks}) : missingChunks = List.unmodifiable(missingChunks);

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({'version': 1, 'manifestId': manifestId, 'missingChunks': missingChunks})));

  static ArtifactRepairRequest parse(List<int> bytes, ArtifactManifest manifest) {
    _require(bytes.length <= 64 * 1024, 'Repair request exceeds the size limit');
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    final map = _expectType<Map>(decoded, 'Repair request must be an object');
    _require(_hasExactKeys(map, {'version', 'manifestId', 'missingChunks'}), 'Repair request has unknown or missing fields');
    _require(map['version'] == 1 && map['manifestId'] == manifest.id, 'Repair request belongs to another manifest');
    final indices = map['missingChunks'];
    _require(indices is List && indices.length <= manifest.chunks.length, 'Repair request chunk list is invalid');
    final seen = <int>{};
    var previousIndex = -1;
    for (final index in indices) {
      _require(
        index is int && index > previousIndex && index < manifest.chunks.length && seen.add(index),
        'Repair request has a duplicate, reordered, or invalid chunk index',
      );
      previousIndex = index as int;
    }
    return ArtifactRepairRequest(manifestId: manifest.id, missingChunks: indices.cast<int>());
  }
}

/// One in-process owner may access a receiver root at a time.
/// The caller coordinates operations; this store does not provide a cross-process lock.
class BundleReceiverStore {
  final Directory root;
  ArtifactManifest? _manifest;

  BundleReceiverStore._(this.root, this._manifest);

  static Future<BundleReceiverStore> open(Directory root) async {
    await root.create(recursive: true);
    final manifestFile = File(p.join(root.path, 'manifest.json'));
    ArtifactManifest? manifest;
    if (await manifestFile.exists()) {
      final bytes = await manifestFile.readAsBytes();
      manifest = ArtifactManifest.parse(bytes);
    }
    return BundleReceiverStore._(root, manifest);
  }

  ArtifactManifest? get manifest => _manifest;

  Future<void> importPart(List<int> bytes) async {
    final part = ArtifactPart.parse(bytes);
    final current = _manifest;
    _require(current == null || current.id == part.manifest.id, 'Receiver store already contains a different manifest');
    if (current == null) {
      await _writeAtomically(File(p.join(root.path, 'manifest.json')), part.manifest.encode());
      _manifest = part.manifest;
    }
    final chunkDirectory = Directory(p.join(root.path, 'chunks'));
    await chunkDirectory.create(recursive: true);
    for (final entry in part.chunks.entries) {
      final description = part.manifest.chunks[entry.key];
      final target = File(p.join(chunkDirectory.path, '${description.sha256}.chunk'));
      if (await target.exists()) {
        final existing = await target.readAsBytes();
        _require(existing.length == description.length && _sha256(existing) == description.sha256, 'Cached chunk is corrupt');
        continue;
      }
      await _writeAtomically(target, entry.value);
    }
  }

  Future<void> clearSession() async {
    final chunkDirectory = Directory(p.join(root.path, 'chunks'));
    if (await chunkDirectory.exists()) await chunkDirectory.delete(recursive: true);
    final manifestFile = File(p.join(root.path, 'manifest.json'));
    if (await manifestFile.exists()) await manifestFile.delete();
    _manifest = null;
  }

  Future<List<int>> missingChunks() async {
    final manifest = _manifest ?? (throw const FormatException('Receiver store has no imported parts'));
    final missing = <int>[];
    for (final chunk in manifest.chunks) {
      final file = File(p.join(root.path, 'chunks', '${chunk.sha256}.chunk'));
      if (!await file.exists()) {
        missing.add(chunk.index);
      } else {
        final bytes = await file.readAsBytes();
        _require(bytes.length == chunk.length && _sha256(bytes) == chunk.sha256, 'Cached chunk is corrupt');
      }
    }
    return List.unmodifiable(missing);
  }

  Future<Uint8List> exportRepairRequest() async {
    final manifest = _manifest ?? (throw const FormatException('Receiver store has no imported parts'));
    return ArtifactRepairRequest(manifestId: manifest.id, missingChunks: await missingChunks()).encode();
  }

  Future<Uint8List> reconstruct() async {
    final manifest = _manifest ?? (throw const FormatException('Receiver store has no imported parts'));
    _require((await missingChunks()).isEmpty, 'Receiver is missing chunks');
    final output = BytesBuilder(copy: false);
    for (final chunk in manifest.chunks) {
      output.add(await File(p.join(root.path, 'chunks', '${chunk.sha256}.chunk')).readAsBytes());
    }
    final result = output.takeBytes();
    _require(result.length == manifest.fileSize && _sha256(result) == manifest.fileSha256, 'Reconstructed file does not match its manifest');
    return result;
  }

  Future<void> _writeAtomically(File target, List<int> bytes) async {
    final temporaryDirectory = await target.parent.createTemp('.parceltrace-tmp-');
    final temporary = File(p.join(temporaryDirectory.path, 'data'));
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporaryDirectory.exists()) await temporaryDirectory.delete(recursive: true);
    }
  }
}

List<Uint8List> createRepairParts({required List<int> sourceBytes, required String fileName, required List<int> requestBytes}) {
  final bundle = ArtifactBundle.fromBytes(fileName: fileName, bytes: sourceBytes);
  final requested = ArtifactRepairRequest.parse(requestBytes, bundle.manifest);
  return bundle.createParts(onlyChunks: requested.missingChunks);
}

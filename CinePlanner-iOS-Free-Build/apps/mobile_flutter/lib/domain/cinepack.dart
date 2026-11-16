import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'production.dart';

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String canonicalJson(Object? value) => jsonEncode(_canonical(value));
String canonicalRecord(ProductionRecord record) =>
    canonicalJson(record.toJson());

class CinepackSnapshot {
  final List<ProductionRecord> records;
  final DateTime exportedAt;
  CinepackSnapshot(
    Iterable<ProductionRecord> records, {
    required this.exportedAt,
  }) : records = List.unmodifiable(records) {
    final ids = <String>{};
    for (final record in this.records) {
      if (!ids.add(record.id)) {
        throw const FormatException('Duplicate record ID');
      }
    }
    final roots = this.records
        .where((r) => r.kind == EntityKind.organization)
        .toList();
    final projects = this.records
        .where((r) => r.kind == EntityKind.project)
        .toList();
    if (roots.length != 1 ||
        projects.length != 1 ||
        this.records.any(
          (r) =>
              r.organizationId != roots.single.id ||
              (r.kind != EntityKind.organization &&
                  r.projectId != projects.single.id),
        )) {
      throw const FormatException(
        'Archive must contain one organization and one project',
      );
    }
    final byId = {for (final record in this.records) record.id: record};
    for (final record in this.records) {
      if (record.parentId == null) continue;
      final parent = byId[record.parentId];
      if (parent == null ||
          parent.kind.index != record.kind.index - 1 ||
          (record.deletedAt == null && parent.deletedAt != null)) {
        throw const FormatException('Archive contains an invalid hierarchy');
      }
    }
  }
  Uint8List encode() {
    final payload = utf8.encode(
      jsonEncode(records.map((r) => r.toJson()).toList()),
    );
    if (records.length > 50000 || payload.length > 64 * 1024 * 1024) {
      throw const FormatException('Snapshot exceeds metadata archive limits');
    }
    final manifest = utf8.encode(
      jsonEncode({
        'format': 'cinepack',
        'schema_version': 1,
        'exported_at': exportedAt.toUtc().toIso8601String(),
        'record_count': records.length,
        'backup_flavor': 'metadata_snapshot',
        'media_mode': 'none',
        'originals_included': false,
        'payloads': [
          {
            'path': 'records.json',
            'bytes': payload.length,
            'sha256': sha256.convert(payload).toString(),
          },
        ],
      }),
    );
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', manifest.length, manifest))
      ..addFile(ArchiveFile('records.json', payload.length, payload));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  factory CinepackSnapshot.decode(Uint8List bytes) {
    if (bytes.length > 64 * 1024 * 1024) {
      throw const FormatException('Archive exceeds the metadata import limit');
    }
    // Inspect central headers before the ZIP decoder can expand any content,
    // including symlink targets. Only two bounded regular files are accepted.
    final names = <String>{};
    var total = 0;
    for (final header in ZipDirectory().headers(
      InputMemoryStream(bytes),
      verify: true,
      files: false,
    )) {
      final name = header.filename;
      final type = (header.externalFileAttributes >> 16) & 0xf000;
      final limit = name == 'manifest.json' ? 16384 : 64 * 1024 * 1024;
      total += header.uncompressedSize;
      if (!{'manifest.json', 'records.json'}.contains(name) ||
          !names.add(name) ||
          (type != 0 && type != 0x8000) ||
          (header.generalPurposeBitFlag & 1) != 0 ||
          !{0, 8}.contains(header.compressionMethod) ||
          header.uncompressedSize < 0 ||
          header.uncompressedSize > limit ||
          total > 64 * 1024 * 1024) {
        throw const FormatException('Unsafe or excessive archive entries');
      }
    }
    if (names.length != 2) {
      throw const FormatException('Missing archive payload');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final entries = archive.files;
    if (entries.length != 2 ||
        entries.any(
          (f) =>
              !f.isFile || !{'manifest.json', 'records.json'}.contains(f.name),
        ) ||
        entries.map((f) => f.name).toSet().length != 2 ||
        entries.any((f) => f.size > 64 * 1024 * 1024)) {
      throw const FormatException(
        'Unexpected archive entries or excessive size',
      );
    }
    final manifestBytes = entries
        .singleWhere((f) => f.name == 'manifest.json')
        .content;
    if (manifestBytes.length > 16384) {
      throw const FormatException('Manifest exceeds limit');
    }
    final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map;
    if (manifest['format'] != 'cinepack' ||
        manifest['schema_version'] != 1 ||
        manifest['backup_flavor'] != 'metadata_snapshot' ||
        manifest['media_mode'] != 'none' ||
        manifest['originals_included'] != false) {
      throw const FormatException('Unsupported archive schema or media mode');
    }
    final payload = entries
        .singleWhere((f) => f.name == 'records.json')
        .content;
    final descriptors = manifest['payloads'] as List;
    if (descriptors.length != 1) {
      throw const FormatException('Invalid payload manifest');
    }
    final descriptor = descriptors.single as Map;
    if (descriptor['path'] != 'records.json' ||
        descriptor['bytes'] != payload.length ||
        descriptor['sha256'] != sha256.convert(payload).toString()) {
      throw const FormatException('Archive checksum or size mismatch');
    }
    final json = jsonDecode(utf8.decode(payload)) as List;
    if (json.length > 50000 || json.length != manifest['record_count']) {
      throw const FormatException('Invalid record count');
    }
    return CinepackSnapshot(
      json.map(
        (r) => ProductionRecord.fromJson(Map<String, dynamic>.from(r as Map)),
      ),
      exportedAt: DateTime.parse(manifest['exported_at'] as String),
    );
  }
}

class RestorePreview {
  final int newRecords, identicalRecords;
  final List<String> conflictingIds;
  const RestorePreview({
    required this.newRecords,
    required this.identicalRecords,
    required this.conflictingIds,
  });
  bool get canRestore => conflictingIds.isEmpty;
}

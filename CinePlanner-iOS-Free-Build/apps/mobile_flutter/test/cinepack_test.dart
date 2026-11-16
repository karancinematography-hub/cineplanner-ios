import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cineplanner/domain/cinepack.dart';
import 'package:cineplanner/domain/production.dart';

CinepackSnapshot fixture() {
  final time = DateTime.utc(2026, 11, 10);
  ProductionRecord record(String id, EntityKind kind, String? parent) =>
      ProductionRecord(
        id: id,
        kind: kind,
        organizationId: 'org',
        projectId: parent == null ? null : 'project',
        parentId: parent,
        title: id,
        revision: 1,
        createdAt: time,
        updatedAt: time,
        createdBy: 'user',
        updatedBy: 'user',
      );
  return CinepackSnapshot([
    record('org', EntityKind.organization, null),
    record('project', EntityKind.project, 'org'),
  ], exportedAt: time);
}

void main() {
  test(
    'cinepack ZIP round trip preserves IDs, revisions and manifest mode',
    () {
      final snapshot = fixture();
      final restored = CinepackSnapshot.decode(snapshot.encode());
      expect(
        restored.records.map(canonicalRecord),
        snapshot.records.map(canonicalRecord),
      );
      expect(restored.exportedAt, snapshot.exportedAt);
      final archive = ZipDecoder().decodeBytes(snapshot.encode());
      final manifest = jsonDecode(
        utf8.decode(archive.findFile('manifest.json')!.content),
      );
      expect(manifest['media_mode'], 'none');
      expect(manifest['originals_included'], isFalse);
    },
  );
  test(
    'modified payload and path traversal are rejected without extraction',
    () {
      final source = ZipDecoder().decodeBytes(fixture().encode());
      final changed = List<int>.from(source.findFile('records.json')!.content);
      changed[10] ^= 1;
      final forged = Archive()
        ..addFile(source.findFile('manifest.json')!)
        ..addFile(ArchiveFile('records.json', changed.length, changed));
      expect(
        () => CinepackSnapshot.decode(
          Uint8List.fromList(ZipEncoder().encode(forged)),
        ),
        throwsFormatException,
      );
      final traversal = Archive()
        ..addFile(ArchiveFile('../records.json', 2, utf8.encode('[]')));
      expect(
        () => CinepackSnapshot.decode(
          Uint8List.fromList(ZipEncoder().encode(traversal)),
        ),
        throwsFormatException,
      );
    },
  );
}

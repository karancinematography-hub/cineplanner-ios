import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';
import '../domain/production.dart';
import '../domain/camera_settings.dart';
import '../domain/lighting_plan.dart';
import '../domain/cinepack.dart';
import '../domain/frame_grab.dart';
import '../domain/lighting_preset.dart';
import '../domain/production_details.dart';
import '../domain/light_plan.dart';
part 'workspace_media.dart';
part 'workspace_workflows.dart';
part 'workspace_light_plan.dart';

class WorkspaceRepository {
  static const schemaVersion = 3;
  final Database db;
  final String deviceId;
  final String actorId;
  WorkspaceRepository(this.db, {required this.deviceId, required this.actorId});

  static Future<void> migrate(Database db, int version) async {
    await db.execute(
      'CREATE TABLE records (id TEXT PRIMARY KEY, kind TEXT NOT NULL, organization_id TEXT NOT NULL, project_id TEXT, parent_id TEXT, revision INTEGER NOT NULL, deleted_at TEXT, payload TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX hierarchy ON records(parent_id, deleted_at)',
    );
    await db.execute(
      'CREATE TABLE operations (sequence INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT NOT NULL UNIQUE, entity_id TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL DEFAULT \'Local only\')',
    );
    await db.execute(
      'CREATE TABLE cursors (project_id TEXT PRIMARY KEY, server_sequence INTEGER NOT NULL)',
    );
    await _createMediaTables(db);
    await _addCaptureDestination(db);
  }

  static Future<void> _createMediaTables(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS frame_assets (asset_id TEXT PRIMARY KEY, organization_id TEXT NOT NULL, project_id TEXT NOT NULL, shot_id TEXT NOT NULL, checksum TEXT NOT NULL, preview_checksum TEXT NOT NULL, mime TEXT NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL, created_at TEXT NOT NULL, created_by TEXT NOT NULL, original BLOB NOT NULL, preview BLOB NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS capture_intents (id INTEGER PRIMARY KEY CHECK (id = 1), shot_id TEXT NOT NULL, slot INTEGER NOT NULL, asset_id TEXT NOT NULL, base_revision INTEGER NOT NULL, source_path TEXT)',
    );
  }

  static Future<void> upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createMediaTables(db);
    }
    if (oldVersion < 3) {
      await _addCaptureDestination(db);
    }
  }

  static Future<void> _addCaptureDestination(DatabaseExecutor db) => db.execute(
    'ALTER TABLE capture_intents ADD COLUMN destination_take_id TEXT',
  );

  Future<ProductionRecord?> get(String id) async => _get(db, id);
  Future<ProductionRecord?> _get(DatabaseExecutor tx, String id) async {
    final rows = await tx.query('records', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty
        ? null
        : ProductionRecord.fromJson(
            jsonDecode(rows.single['payload'] as String),
          );
  }

  Future<List<ProductionRecord>> children(String? parentId) async {
    final rows = await db.query(
      'records',
      where: parentId == null
          ? 'parent_id IS NULL AND deleted_at IS NULL'
          : 'parent_id = ? AND deleted_at IS NULL',
      whereArgs: parentId == null ? null : [parentId],
      orderBy: 'rowid',
    );
    return rows
        .map(
          (r) => ProductionRecord.fromJson(jsonDecode(r['payload'] as String)),
        )
        .toList();
  }

  /// Materialized state and outgoing operation commit together or not at all.
  Future<void> save(
    ProductionRecord record, {
    required int baseRevision,
  }) async {
    await db.transaction((tx) => _save(tx, record, baseRevision));
  }

  Future<void> _save(
    DatabaseExecutor tx,
    ProductionRecord record,
    int baseRevision, {
    bool restoreCreation = false,
  }) async {
    final existing = await _get(tx, record.id);
    if ((existing?.revision ?? 0) != baseRevision ||
        record.revision != baseRevision + 1) {
      throw StateError('Revision conflict: reload before editing');
    }
    if (existing?.deletedAt != null &&
        !(restoreCreation && record.deletedAt == null)) {
      throw StateError('Cannot edit tombstone');
    }
    final details = Map<String, Object?>.from(
      normalizeProductionDetails(
        record.kind,
        record.data['details'],
        now: record.updatedAt,
      ),
    );
    if (record.kind == EntityKind.take && existing != null) {
      final old = normalizeProductionDetails(
        existing.kind,
        existing.data['details'],
        now: existing.updatedAt,
      );
      if (old['locked'] == true &&
          canonicalJson(existing.data['camera_overrides'] ?? {}) !=
              canonicalJson(record.data['camera_overrides'] ?? {})) {
        throw StateError(
          'Unlock the recorded take before changing camera overrides',
        );
      }
      if (old['recorded_at_utc'] != null) {
        details['recorded_at_utc'] = old['recorded_at_utc'];
      }
    }
    if (record.data.containsKey('details') ||
        (existing?.data.containsKey('details') ?? false)) {
      record = ProductionRecord.fromJson({
        ...record.toJson(),
        'data': {...record.data, 'details': details},
      });
    }
    if (existing == null &&
        record.kind == EntityKind.shot &&
        record.data['cameras'] == null) {
      final project = await _get(tx, record.projectId!);
      final defaults = normalizeProductionDetails(
        EntityKind.project,
        project?.data['details'],
        now: record.updatedAt,
      );
      final camera = <String, Object?>{
        if (defaults['default_fps'] != null) 'fps': defaults['default_fps'],
        if (defaults['camera_format'] != null)
          'format': defaults['camera_format'],
      };
      if (camera.isNotEmpty) {
        record = ProductionRecord.fromJson({
          ...record.toJson(),
          'data': {
            ...record.data,
            'cameras': {'A Cam': camera},
          },
        });
      }
    }
    if (existing != null &&
        (existing.kind != record.kind ||
            existing.parentId != record.parentId ||
            existing.organizationId != record.organizationId ||
            existing.projectId != record.projectId)) {
      throw StateError('Identity and hierarchy are immutable');
    }
    ProductionRecord? parentRecord;
    if (record.parentId != null) {
      final parent = await _get(tx, record.parentId!);
      parentRecord = parent;
      if (parent == null ||
          parent.deletedAt != null ||
          parent.kind.index != record.kind.index - 1 ||
          parent.organizationId != record.organizationId ||
          (parent.kind != EntityKind.organization &&
              parent.projectId != record.projectId)) {
        throw StateError('Invalid or inaccessible parent');
      }
    }
    if (isLightNumberedKind(record.kind) && record.deletedAt == null) {
      final previousNumber = lightRecordNumber(existing);
      if (previousNumber != null &&
          existing!.title != record.title &&
          !record.data.containsKey(lightNumberKey) &&
          lightRecordNumber(record) != previousNumber) {
        record = ProductionRecord.fromJson({
          ...record.toJson(),
          'data': {...record.data, lightNumberKey: previousNumber},
        });
      }
      final stored = record.data[lightNumberKey];
      if (record.data.containsKey(lightNumberKey) &&
          (stored is! String || parseLightNumber(stored) == null)) {
        throw const FormatException('Enter a number using digits only.');
      }
      final number = lightRecordNumber(record);
      if (number != null && (restoreCreation || number != previousNumber)) {
        await _checkLightNumber(tx, record, number, exceptId: record.id);
      }
    }
    if (record.kind == EntityKind.project) {
      _readPresets(record);
    }
    if (record.kind == EntityKind.shot) {
      readCameras(record.data['cameras']);
      if (record.data['lighting_plan'] != null) {
        LightingPlan.fromJson(
          Map<String, dynamic>.from(record.data['lighting_plan'] as Map),
        );
      }
      for (final id in _frameDependencies(record)) {
        final assets = await tx.query(
          'frame_assets',
          columns: ['shot_id'],
          where: 'asset_id = ?',
          whereArgs: [id],
        );
        if (assets.isNotEmpty && assets.single['shot_id'] != record.id) {
          throw StateError('Frame grab belongs to another shot');
        }
      }
    }
    if (record.kind == EntityKind.take) {
      await _validateLightPlanContent(tx, record);
      final overrides = readCameras(record.data['camera_overrides']);
      final baseline = existing == null
          ? readCameras(parentRecord!.data['cameras'])
          : readCameras(existing.data['camera_baseline']);
      if (overrides.keys.any((id) => !baseline.containsKey(id))) {
        throw StateError(
          'Take override references an unknown historical camera',
        );
      }
      final data = {
        ...record.data,
        'camera_baseline': baseline,
        'baseline_shot_revision': existing == null
            ? parentRecord!.revision
            : existing.data['baseline_shot_revision'],
      };
      record = ProductionRecord.fromJson({...record.toJson(), 'data': data});
    }
    if (record.deletedAt != null) {
      final children = await tx.query(
        'records',
        columns: ['id'],
        where: 'parent_id = ? AND deleted_at IS NULL',
        whereArgs: [record.id],
        limit: 1,
      );
      if (children.isNotEmpty) {
        throw StateError('Delete children before parent');
      }
    }
    final json = record.toJson();
    final values = {
      'id': record.id,
      'kind': record.kind.name,
      'organization_id': record.organizationId,
      'project_id': record.projectId,
      'parent_id': record.parentId,
      'revision': record.revision,
      'deleted_at': record.deletedAt?.toIso8601String(),
      'payload': jsonEncode(json),
    };
    if (existing == null) {
      await tx.insert('records', values);
    } else {
      await tx.update(
        'records',
        values,
        where: 'id = ?',
        whereArgs: [record.id],
      );
    }
    final operationId = const Uuid().v4();
    await tx.insert('operations', {
      'operation_id': operationId,
      'entity_id': record.id,
      'payload': jsonEncode({
        'operation_id': operationId,
        'device_id': deviceId,
        'actor_id': actorId,
        'project_id': record.projectId,
        'entity_type': record.kind.name,
        'entity_id': record.id,
        'base_revision': baseRevision,
        'patch': json,
        'timestamp': record.updatedAt.toIso8601String(),
        'attachment_dependencies': _frameDependencies(record),
      }),
    });
  }

  Future<int> pendingCount() async =>
      (await db.rawQuery(
            'SELECT COUNT(*) AS count FROM operations',
          )).single['count']
          as int;

  Future<CinepackSnapshot> projectSnapshot(String projectId) => db.transaction((
    tx,
  ) async {
    final project = await _get(tx, projectId);
    if (project == null || project.kind != EntityKind.project) {
      throw StateError('Project not found');
    }
    final rows = await tx.query(
      'records',
      where: 'organization_id = ? AND (project_id = ? OR id = ?)',
      whereArgs: [project.organizationId, projectId, project.organizationId],
    );
    final records =
        rows
            .map(
              (r) =>
                  ProductionRecord.fromJson(jsonDecode(r['payload'] as String)),
            )
            .toList()
          ..sort((a, b) => a.kind.index.compareTo(b.kind.index));
    return CinepackSnapshot(records, exportedAt: DateTime.now().toUtc());
  });

  Future<RestorePreview> previewRestore(CinepackSnapshot snapshot) =>
      db.transaction((tx) => _previewRestore(tx, snapshot));
  Future<RestorePreview> _previewRestore(
    DatabaseExecutor tx,
    CinepackSnapshot snapshot,
  ) async {
    var added = 0, identical = 0;
    final conflicts = <String>[];
    for (final record in snapshot.records) {
      final normalizedDetails = normalizeProductionDetails(
        record.kind,
        record.data['details'],
        now: record.updatedAt,
      );
      final rawDetails = record.data['details'] as Map? ?? {};
      for (final key in ['call_at_utc', 'recorded_at_utc']) {
        if (normalizedDetails[key] != rawDetails[key]) {
          throw const FormatException(
            'Archive production timestamps are missing or inconsistent',
          );
        }
      }
      if (record.kind == EntityKind.project) {
        _readPresets(record);
      }
      for (final id in _frameDependencies(record)) {
        final media = await tx.query(
          'frame_assets',
          columns: ['shot_id'],
          where: 'asset_id = ?',
          whereArgs: [id],
        );
        final ownerId = record.kind == EntityKind.take
            ? record.parentId
            : record.id;
        if (media.isNotEmpty && media.single['shot_id'] != ownerId) {
          throw const FormatException('Frame grab belongs to another shot');
        }
      }
      if (record.kind == EntityKind.shot) {
        readCameras(record.data['cameras']);
        if (record.data['lighting_plan'] != null) {
          LightingPlan.fromJson(
            Map<String, dynamic>.from(record.data['lighting_plan'] as Map),
          );
        }
      }
      if (record.kind == EntityKind.take) {
        readLightCanvas(record);
        final baseline = readCameras(record.data['camera_baseline']);
        final overrides = readCameras(record.data['camera_overrides']);
        if (overrides.keys.any((id) => !baseline.containsKey(id))) {
          throw const FormatException('Invalid take camera override');
        }
      }
      final current = await _get(tx, record.id);
      if (current == null) {
        added++;
      } else if (canonicalRecord(current) == canonicalRecord(record)) {
        identical++;
      } else {
        conflicts.add(record.id);
      }
    }
    return RestorePreview(
      newRecords: added,
      identicalRecords: identical,
      conflictingIds: List.unmodifiable(conflicts),
    );
  }

  /// Restore is atomic and repeatable. Divergent IDs require explicit resolution;
  /// the original records and archive remain intact. Restore intents must use a
  /// separately authorized import path when server sync is implemented.
  Future<RestorePreview> restoreSnapshot(CinepackSnapshot snapshot) =>
      db.transaction((tx) async {
        final preview = await _previewRestore(tx, snapshot);
        if (!preview.canRestore) {
          throw StateError(
            'Restore conflicts: ${preview.conflictingIds.join(', ')}',
          );
        }
        for (final record in snapshot.records) {
          if (await _get(tx, record.id) != null) continue;
          await tx.insert('records', {
            'id': record.id,
            'kind': record.kind.name,
            'organization_id': record.organizationId,
            'project_id': record.projectId,
            'parent_id': record.parentId,
            'revision': record.revision,
            'deleted_at': record.deletedAt?.toIso8601String(),
            'payload': jsonEncode(record.toJson()),
          });
          final operationId = const Uuid().v4();
          await tx.insert('operations', {
            'operation_id': operationId,
            'entity_id': record.id,
            'payload': jsonEncode({
              'operation_id': operationId,
              'device_id': deviceId,
              'actor_id': actorId,
              'project_id': record.projectId,
              'entity_type': record.kind.name,
              'entity_id': record.id,
              'base_revision': 0,
              'intent': 'restore_snapshot',
              'patch': record.toJson(),
              'timestamp': DateTime.now().toUtc().toIso8601String(),
              'attachment_dependencies': <String>[],
            }),
          });
        }
        return preview;
      });
}

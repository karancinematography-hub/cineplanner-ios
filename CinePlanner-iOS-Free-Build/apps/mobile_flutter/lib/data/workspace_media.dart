part of 'workspace_repository.dart';

Map<String, dynamic> _frameSlots(ProductionRecord record) {
  final slots = Map<String, dynamic>.from(
    record.data['frame_grabs'] as Map? ?? {},
  );
  for (final entry in slots.entries) {
    if (!{'1', '2'}.contains(entry.key) || entry.value is! Map) {
      throw const FormatException('Invalid comparison slot');
    }
    final ref = entry.value as Map;
    if (ref['asset_id'] is! String ||
        (ref['asset_id'] as String).isEmpty ||
        (ref['notes'] != null &&
            (ref['notes'] is! String ||
                (ref['notes'] as String).length > 4000)) ||
        (ref['camera'] != null && ref['camera'] is! String) ||
        (ref['take_id'] != null && ref['take_id'] is! String)) {
      throw const FormatException('Invalid frame grab reference');
    }
  }
  return slots;
}

List<String> _frameDependencies(ProductionRecord record) => _frameSlots(
  record,
).values.map((v) => (v as Map)['asset_id'] as String).toSet().toList();

extension WorkspaceMedia on WorkspaceRepository {
  Future<ProductionRecord> attachFrame({
    required String shotId,
    required int slot,
    required String assetId,
    required PreparedFrame frame,
    required int expectedRevision,
    String notes = '',
    String? camera,
    String? takeId,
    String? destinationTakeId,
  }) => db.transaction((tx) async {
    if (slot != 1 && slot != 2) {
      throw ArgumentError('Expected GRAB 1 or GRAB 2');
    }
    final shot = await _get(tx, shotId);
    if (shot == null ||
        shot.kind != EntityKind.shot ||
        shot.deletedAt != null) {
      throw StateError('Shot unavailable');
    }
    if (camera != null &&
        !readCameras(shot.data['cameras']).containsKey(camera)) {
      throw StateError('Camera does not belong to this shot');
    }
    if (takeId != null) {
      final take = await _get(tx, takeId);
      if (take == null ||
          take.parentId != shotId ||
          take.kind != EntityKind.take ||
          take.deletedAt != null) {
        throw StateError('Take does not belong to this shot');
      }
    }
    final destination = destinationTakeId == null
        ? shot
        : await _active(tx, destinationTakeId, EntityKind.take);
    if (destinationTakeId != null && destination.parentId != shotId) {
      throw StateError('Take does not belong to this shot');
    }
    final slots = _frameSlots(destination);
    final existing = await tx.query(
      'frame_assets',
      where: 'asset_id = ?',
      whereArgs: [assetId],
      columns: ['shot_id', 'checksum'],
    );
    if (existing.isNotEmpty) {
      if (existing.single['shot_id'] != shotId ||
          existing.single['checksum'] != frame.checksum) {
        throw StateError('Asset ID checksum conflict');
      }
      if ((slots['$slot'] as Map?)?['asset_id'] == assetId) {
        await tx.delete(
          'capture_intents',
          where: 'asset_id = ?',
          whereArgs: [assetId],
        );
        return destination;
      }
    }
    if (destination.revision != expectedRevision) {
      throw StateError(
        'Shot changed. Reopen and retry; the selected image has not been discarded.',
      );
    }
    if (existing.isEmpty) {
      await tx.insert('frame_assets', {
        'asset_id': assetId,
        'organization_id': shot.organizationId,
        'project_id': shot.projectId,
        'shot_id': shotId,
        'checksum': frame.checksum,
        'preview_checksum': frame.previewChecksum,
        'mime': frame.mime,
        'width': frame.width,
        'height': frame.height,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'created_by': actorId,
        'original': frame.original,
        'preview': frame.preview,
      });
    }
    slots['$slot'] = {
      'asset_id': assetId,
      'notes': notes,
      'camera': camera,
      'take_id': destinationTakeId ?? takeId,
    };
    final updated = destination.edit(
      actor: actorId,
      at: DateTime.now(),
      data: {...destination.data, 'frame_grabs': slots},
    );
    await _save(tx, updated, destination.revision);
    await tx.delete(
      'capture_intents',
      where: 'asset_id = ?',
      whereArgs: [assetId],
    );
    return (await _get(tx, updated.id))!;
  });

  Future<FrameGrab?> framePreview(String shotId, String assetId) async {
    final rows = await db.query(
      'frame_assets',
      columns: [
        'asset_id',
        'shot_id',
        'checksum',
        'preview_checksum',
        'mime',
        'width',
        'height',
        'created_at',
        'created_by',
        'preview',
      ],
      where: 'asset_id = ? AND shot_id = ?',
      whereArgs: [assetId, shotId],
    );
    if (rows.isEmpty) return null;
    final r = rows.single;
    final preview = r['preview'] as Uint8List;
    if (sha256.convert(preview).toString() != r['preview_checksum']) {
      throw StateError('Preview checksum mismatch; original retained');
    }
    return FrameGrab(
      assetId: r['asset_id'] as String,
      shotId: shotId,
      checksum: r['checksum'] as String,
      mime: r['mime'] as String,
      createdBy: r['created_by'] as String,
      width: r['width'] as int,
      height: r['height'] as int,
      createdAt: DateTime.parse(r['created_at'] as String),
      preview: preview,
    );
  }

  Future<Uint8List?> originalFrame(String shotId, String assetId) async {
    final rows = await db.query(
      'frame_assets',
      columns: ['original', 'checksum'],
      where: 'asset_id = ? AND shot_id = ?',
      whereArgs: [assetId, shotId],
    );
    if (rows.isEmpty) return null;
    final bytes = rows.single['original'] as Uint8List;
    if (sha256.convert(bytes).toString() != rows.single['checksum']) {
      throw StateError('Original checksum mismatch');
    }
    return bytes.asUnmodifiableView();
  }

  Future<void> startCapture(
    String shotId,
    int slot,
    String assetId,
    int baseRevision, {
    String? destinationTakeId,
  }) => db.transaction((tx) async {
    if (slot != 1 && slot != 2) throw ArgumentError('Invalid slot');
    if ((await tx.query('capture_intents', limit: 1)).isNotEmpty) {
      throw StateError(
        'Recover or dismiss the pending camera image before starting another capture',
      );
    }
    if (destinationTakeId != null) {
      final take = await _active(tx, destinationTakeId, EntityKind.take);
      if (take.parentId != shotId || take.revision != baseRevision) {
        throw StateError('Take changed. Reopen Light Plan.');
      }
    }
    await tx.insert('capture_intents', {
      'id': 1,
      'shot_id': shotId,
      'slot': slot,
      'asset_id': assetId,
      'base_revision': baseRevision,
      'destination_take_id': ?destinationTakeId,
    });
  });

  Future<void> stageCapturePath(String path) async {
    await db.update('capture_intents', {'source_path': path}, where: 'id = 1');
  }

  Future<Map<String, Object?>?> pendingCapture() async {
    final rows = await db.query('capture_intents');
    return rows.isEmpty ? null : rows.single;
  }

  Future<void> clearCapture() async {
    await db.delete('capture_intents');
  }
}

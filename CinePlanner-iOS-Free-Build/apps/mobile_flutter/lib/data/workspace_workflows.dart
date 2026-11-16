part of 'workspace_repository.dart';

List<LightingPreset> _readPresets(ProductionRecord project) {
  final presets = (project.data['lighting_presets'] as List? ?? [])
      .map((p) => LightingPreset.fromJson(Map<String, dynamic>.from(p as Map)))
      .toList(growable: false);
  final ids = <String>{};
  for (final preset in presets) {
    if (!ids.add(preset.id)) throw const FormatException('Duplicate preset ID');
  }
  return presets;
}

class ShotDuplication {
  final ProductionRecord shot;
  final int copiedMedia, missingMedia;
  const ShotDuplication(
    this.shot, {
    required this.copiedMedia,
    required this.missingMedia,
  });
}

extension WorkspaceWorkflows on WorkspaceRepository {
  Future<ShotDuplication> duplicateShot(
    String shotId, {
    required int expectedRevision,
    required String title,
    bool includeFrames = true,
  }) => db.transaction((tx) async {
    final source = await _get(tx, shotId);
    if (source == null ||
        source.kind != EntityKind.shot ||
        source.deletedAt != null ||
        source.revision != expectedRevision) {
      throw StateError(
        'Shot changed or is unavailable. Reopen before duplicating.',
      );
    }
    final now = DateTime.now().toUtc(), id = const Uuid().v4();
    final sourcePlan = source.data['lighting_plan'] == null
        ? LightingPlan([])
        : LightingPlan.fromJson(
            Map<String, dynamic>.from(source.data['lighting_plan'] as Map),
          );
    final plan = sourcePlan.freshCopy(() => const Uuid().v4());
    final frames = <String, dynamic>{};
    var copied = 0, missing = 0;
    if (includeFrames) {
      for (final entry in _frameSlots(source).entries) {
        final ref = entry.value as Map;
        final newAssetId = const Uuid().v4();
        final assets = await tx.query(
          'frame_assets',
          where: 'asset_id = ? AND shot_id = ?',
          whereArgs: [ref['asset_id'], source.id],
        );
        if (assets.isEmpty) {
          missing++;
        } else {
          final asset = assets.single;
          if (sha256.convert(asset['original'] as Uint8List).toString() !=
                  asset['checksum'] ||
              sha256.convert(asset['preview'] as Uint8List).toString() !=
                  asset['preview_checksum']) {
            throw StateError(
              'Source media checksum failed. No duplicate was created.',
            );
          }
          await tx.insert('frame_assets', {
            ...asset,
            'asset_id': newAssetId,
            'shot_id': id,
            'created_by': actorId,
            'created_at': now.toIso8601String(),
          });
          copied++;
        }
        frames[entry.key] = {
          ...ref,
          'asset_id': newAssetId,
          'take_id': null,
          'source_asset_id': ref['asset_id'],
          'source_shot_id': source.id,
        };
      }
    }
    final data =
        {
            ...source.data,
            'cameras': readCameras(source.data['cameras']),
            'lighting_plan': plan.toJson(),
            'frame_grabs': frames,
            'duplicated_from': source.id,
            'duplicated_source_revision': source.revision,
            'review_state': 'draft',
          }
          ..remove('approval')
          ..remove('approvals')
          ..remove('approved_revision');
    final shot = ProductionRecord(
      id: id,
      kind: EntityKind.shot,
      organizationId: source.organizationId,
      projectId: source.projectId,
      parentId: source.parentId,
      title: title,
      revision: 1,
      createdAt: now,
      updatedAt: now,
      createdBy: actorId,
      updatedBy: actorId,
      data: data,
    );
    await _save(tx, shot, 0);
    return ShotDuplication(shot, copiedMedia: copied, missingMedia: missing);
  });

  Future<String> saveLightingPreset({
    required String projectId,
    required String name,
    required LightingPlan plan,
    required String sourceShotId,
    required int sourceRevision,
  }) => db.transaction((tx) async {
    if (name.trim().isEmpty || name.length > 80) {
      throw ArgumentError('Preset names must contain 1–80 characters');
    }
    final project = await _get(tx, projectId),
        source = await _get(tx, sourceShotId);
    if (project == null ||
        project.kind != EntityKind.project ||
        project.deletedAt != null ||
        source == null ||
        source.kind != EntityKind.shot ||
        source.deletedAt != null ||
        source.projectId != projectId ||
        source.organizationId != project.organizationId ||
        source.revision != sourceRevision) {
      throw StateError('Project or shot revision is no longer available');
    }
    final id = const Uuid().v4(), now = DateTime.now().toUtc();
    final presets = List<Object?>.from(
      project.data['lighting_presets'] as List? ?? [],
    );
    presets.add(
      LightingPreset(
        id: id,
        name: name.trim(),
        sourceShotId: sourceShotId,
        sourceRevision: sourceRevision,
        createdAt: now,
        createdBy: actorId,
        plan: plan,
      ).toJson(),
    );
    await _save(
      tx,
      project.edit(
        actor: actorId,
        at: now,
        data: {...project.data, 'lighting_presets': presets},
      ),
      project.revision,
    );
    return id;
  });
  Future<List<LightingPreset>> lightingPresets(String projectId) async {
    final project = await get(projectId);
    if (project == null ||
        project.kind != EntityKind.project ||
        project.deletedAt != null) {
      throw StateError('Project unavailable');
    }
    return _readPresets(project);
  }
}

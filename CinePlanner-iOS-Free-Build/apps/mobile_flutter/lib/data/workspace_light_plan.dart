part of 'workspace_repository.dart';

Future<void> _checkLightNumber(
  DatabaseExecutor tx,
  ProductionRecord record,
  String label, {
  String? exceptId,
}) async {
  final number = parseLightNumber(label)!;
  final siblings = await tx.query(
    'records',
    columns: ['payload'],
    where: 'parent_id = ? AND deleted_at IS NULL',
    whereArgs: [record.parentId],
  );
  for (final row in siblings) {
    final sibling = ProductionRecord.fromJson(
      jsonDecode(row['payload'] as String),
    );
    if (sibling.id == exceptId) continue;
    if (number == parseLightNumber(lightRecordNumber(sibling))) {
      final parentKind = EntityKind.values[record.kind.index - 1].label;
      throw StateError(
        '${record.kind.label} number $label already exists in this $parentKind.',
      );
    }
  }
}

Future<void> _validateLightPlanContent(
  DatabaseExecutor tx,
  ProductionRecord take,
) async {
  readLightCanvas(take);
  for (final id in _frameDependencies(take)) {
    final asset = await tx.query(
      'frame_assets',
      columns: ['shot_id'],
      where: 'asset_id = ?',
      whereArgs: [id],
    );
    if (asset.isNotEmpty && asset.single['shot_id'] != take.parentId) {
      throw StateError('Frame grab belongs to another shot.');
    }
  }
}

extension WorkspaceLightPlan on WorkspaceRepository {
  Future<ProductionRecord> _active(
    DatabaseExecutor tx,
    String id,
    EntityKind kind,
  ) async {
    final record = await _get(tx, id);
    if (record == null || record.kind != kind || record.deletedAt != null) {
      throw StateError('The ${kind.label} is unavailable. Reopen Light Plan.');
    }
    return record;
  }

  Future<ProductionRecord> openLightTake(String id) =>
      db.transaction((tx) async {
        final take = await _active(tx, id, EntityKind.take);
        if (take.data.containsKey('lighting_plan')) return take;
        final shot = await _active(tx, take.parentId!, EntityKind.shot);
        final seeded = take.edit(
          actor: actorId,
          at: DateTime.now(),
          data: {
            ...take.data,
            'lighting_plan': readLightCanvas(shot).toJson(),
            'frame_grabs':
                take.data['frame_grabs'] ?? shot.data['frame_grabs'] ?? {},
            'light_plan_source': {'id': shot.id, 'revision': shot.revision},
          },
        );
        await _save(tx, seeded, take.revision);
        return (await _get(tx, id))!;
      });

  Future<ProductionRecord> setLightNumber(
    ProductionRecord base,
    String number,
  ) => db.transaction((tx) async {
    if (!isLightNumberedKind(base.kind) || parseLightNumber(number) == null) {
      throw const FormatException('Enter a number using digits only.');
    }
    final record = base.edit(
      actor: actorId,
      at: DateTime.now(),
      data: {...base.data, lightNumberKey: number},
    );
    await _save(tx, record, base.revision);
    return (await _get(tx, record.id))!;
  });

  Future<List<ProductionRecord>> createLightRecord({
    required LightPlanCreation kind,
    required String shootDayId,
    String? sceneId,
    String? shotId,
    ProductionRecord? source,
    bool copyCanvas = false,
    List<String> numbers = const [],
  }) => db.transaction((tx) async {
    final day = await _active(tx, shootDayId, EntityKind.shootDay);
    final scene = sceneId == null
        ? null
        : await _active(tx, sceneId, EntityKind.scene);
    final shot = shotId == null
        ? null
        : await _active(tx, shotId, EntityKind.shot);
    if ((scene != null && scene.parentId != day.id) ||
        (shot != null && shot.parentId != scene?.id)) {
      throw StateError('The active hierarchy changed. Reopen Light Plan.');
    }
    ProductionRecord? current;
    if (source != null) {
      current = await _active(tx, source.id, EntityKind.take);
      if (current.parentId != shot?.id || current.revision != source.revision) {
        throw StateError('The source take changed. Reopen Light Plan.');
      }
    }

    final now = DateTime.now().toUtc();
    final created = <ProductionRecord>[];
    Future<ProductionRecord> insert(
      EntityKind kind,
      ProductionRecord parent,
      String number, [
      Map<String, Object?> extra = const {},
    ]) async {
      final record = ProductionRecord(
        id: const Uuid().v4(),
        kind: kind,
        organizationId: day.organizationId,
        projectId: day.projectId,
        parentId: parent.id,
        title: number,
        revision: 1,
        createdAt: now,
        updatedAt: now,
        createdBy: actorId,
        updatedBy: actorId,
        data: {lightNumberKey: number, ...extra},
      );
      await _save(tx, record, 0);
      final saved = (await _get(tx, record.id))!;
      created.add(saved);
      return saved;
    }

    late final ProductionRecord parentShot;
    late final String takeNumber;
    ProductionRecord? canvasSource;
    if (kind == LightPlanCreation.take) {
      if (shot == null) throw StateError('Open a shot before creating a take.');
      parentShot = shot;
      if (current == null) {
        final takes = await tx.query(
          'records',
          where: 'parent_id = ? AND deleted_at IS NULL',
          whereArgs: [shot.id],
          limit: 1,
        );
        if (takes.isNotEmpty) throw StateError('Open an existing take first.');
        takeNumber = '01';
        canvasSource = shot;
      } else {
        final label = lightRecordNumber(current);
        final number = parseLightNumber(label);
        if (number == null) {
          throw StateError(
            'Use a numeric take label before creating the next take.',
          );
        }
        takeNumber = (number + BigInt.one).toString().padLeft(
          label!.length,
          '0',
        );
        canvasSource = current;
      }
    } else {
      final creatingScene = kind == LightPlanCreation.scene;
      if (numbers.length != (creatingScene ? 3 : 2) ||
          numbers.any((number) => parseLightNumber(number) == null)) {
        throw const FormatException(
          'Enter all record numbers using digits only.',
        );
      }
      if (!creatingScene && lightRecordNumber(scene) == null) {
        throw StateError(
          'Set the current scene number in Go to before adding a shot.',
        );
      }
      final parentScene = creatingScene
          ? await insert(EntityKind.scene, day, numbers.first)
          : scene!;
      parentShot = await insert(
        EntityKind.shot,
        parentScene,
        numbers[numbers.length - 2],
        {'cameras': <String, Object?>{}},
      );
      takeNumber = numbers.last;
      canvasSource = copyCanvas ? current : null;
    }

    final canvas = readLightCanvas(
      canvasSource,
    ).freshCopy(() => const Uuid().v4());
    await insert(EntityKind.take, parentShot, takeNumber, {
      'lighting_plan': canvas.toJson(),
      'frame_grabs': <String, Object?>{},
      if (canvasSource != null)
        'light_plan_source': {
          'id': canvasSource.id,
          'revision': canvasSource.revision,
        },
    });
    return created;
  });

  Future<List<ProductionRecord>> setLightCreationVisible(
    List<ProductionRecord> branch, {
    required bool visible,
  }) => db.transaction((tx) async {
    final changed = <ProductionRecord>[];
    for (final expected in visible ? branch : branch.reversed) {
      final current = await _get(tx, expected.id);
      if (current == null ||
          current.revision != expected.revision ||
          (current.deletedAt != null) != visible) {
        throw StateError('The created records changed. Reopen Light Plan.');
      }
      final revision = current.edit(
        actor: actorId,
        at: DateTime.now(),
        delete: !visible,
      );
      final updated = visible
          ? ProductionRecord.fromJson({
              ...revision.toJson(),
              'deleted_at': null,
            })
          : revision;
      await _save(tx, updated, current.revision, restoreCreation: visible);
      changed.add((await _get(tx, updated.id))!);
    }
    return visible ? changed : changed.reversed.toList();
  });
}

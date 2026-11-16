import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cineplanner/data/workspace_repository.dart';
import 'package:cineplanner/domain/production.dart';
import 'package:cineplanner/domain/camera_settings.dart';
import 'package:cineplanner/domain/cinepack.dart';
import 'package:cineplanner/domain/frame_grab.dart';
import 'package:cineplanner/domain/lighting_plan.dart';
import 'package:cineplanner/domain/light_plan.dart';

void main() {
  sqfliteFfiInit();
  late Directory temp;
  late Database db;
  late WorkspaceRepository repo;
  final time = DateTime.utc(2026, 11, 10);
  ProductionRecord record(
    EntityKind kind,
    String id, {
    String? parent,
    String org = 'org',
    String? project,
  }) => ProductionRecord(
    id: id,
    kind: kind,
    organizationId: org,
    projectId: project,
    parentId: parent,
    title: id,
    revision: 1,
    createdAt: time,
    updatedAt: time,
    createdBy: 'user',
    updatedBy: 'user',
  );
  Future<void> open() async {
    db = await databaseFactoryFfi.openDatabase(
      '${temp.path}/test.db',
      options: OpenDatabaseOptions(
        version: WorkspaceRepository.schemaVersion,
        onCreate: WorkspaceRepository.migrate,
      ),
    );
    repo = WorkspaceRepository(db, deviceId: 'device', actorId: 'user');
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cineplanner-test-');
    await open();
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<ProductionRecord> seedShot() async {
    final chain = [
      record(EntityKind.organization, 'org'),
      record(EntityKind.project, 'project', parent: 'org', project: 'project'),
      record(EntityKind.shootDay, 'day', parent: 'project', project: 'project'),
      record(EntityKind.scene, 'scene', parent: 'day', project: 'project'),
    ];
    for (final item in chain) {
      await repo.save(item, baseRevision: 0);
    }
    final shot = ProductionRecord.fromJson({
      ...record(
        EntityKind.shot,
        'shot',
        parent: 'scene',
        project: 'project',
      ).toJson(),
      'data': {
        'cameras': {
          'A Cam': {'iso': 800, 'focal_mm': 35},
        },
        'lighting_plan': LightingPlan([
          const PlanObject(
            id: 'fixture',
            symbol: SymbolKind.ledPanel,
            x: 2,
            y: 3,
            kelvin: 5600,
          ),
        ]).toJson(),
      },
    });
    await repo.save(shot, baseRevision: 0);
    return shot;
  }

  test(
    'Light Plan seeds a legacy take once and copies only the canvas',
    () async {
      final shot = await seedShot();
      await repo.attachFrame(
        shotId: shot.id,
        slot: 1,
        assetId: 'legacy-image',
        expectedRevision: shot.revision,
        frame: prepareFrame(
          Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
        ),
      );
      final legacy = record(
        EntityKind.take,
        '02',
        parent: shot.id,
        project: shot.projectId,
      );
      await repo.save(legacy, baseRevision: 0);
      final source = await repo.openLightTake(legacy.id);
      expect((source.data['frame_grabs'] as Map).keys, ['1']);
      expect(readLightCanvas(source).objects.single.kelvin, 5600);

      final scene = (await repo.get('scene'))!;
      final numberedScene = await repo.setLightNumber(scene, '02');
      expect(numberedScene.title, 'scene');
      for (final kind in [LightPlanCreation.scene, LightPlanCreation.shot]) {
        for (final copy in [false, true]) {
          final branch = await repo.createLightRecord(
            kind: kind,
            shootDayId: 'day',
            sceneId: 'scene',
            shotId: shot.id,
            source: source,
            copyCanvas: copy,
            numbers: [
              if (kind == LightPlanCreation.scene) copy ? '04' : '03',
              copy ? '04' : '03',
              '01',
            ],
          );
          final take = branch.last;
          final newShot = branch[branch.length - 2];
          expect(take.data['frame_grabs'], isEmpty);
          expect(take.data['details'], isNull);
          expect(lightRecordNumber(take), '01');
          final plan = readLightCanvas(take);
          expect(plan.objects, hasLength(copy ? 1 : 0));
          if (copy) {
            expect(plan.objects.single.id, isNot('fixture'));
            expect(
              plan.objects.single.y,
              readLightCanvas(source).objects.single.y,
            );
          }
          if (kind == LightPlanCreation.shot) {
            final scene = (await repo.get('scene'))!;
            expect(newShot.parentId, scene.id);
            expect(scene.title, 'scene');
            expect(lightRecordNumber(scene), '02');
            expect(newShot.data['light_plan_scene_alias'], isNull);
          }
        }
      }
      await db.close();
      await open();
      expect((await repo.openLightTake(source.id)).revision, source.revision);
      expect(((await repo.get(shot.id))!.data['frame_grabs'] as Map).keys, [
        '1',
      ]);
    },
  );

  test(
    'Light Plan numbering preserves names and rejects padded duplicates',
    () async {
      final shot = await seedShot();
      expect(lightRecordNumber(shot), isNull);
      await expectLater(
        repo.setLightNumber(shot, '03B'),
        throwsFormatException,
      );
      final numbered = await repo.setLightNumber(shot, '03');
      expect(numbered.title, shot.title);
      expect(numbered.id, shot.id);
      expect(numbered.parentId, shot.parentId);
      expect(lightRecordNumber(numbered), '03');
      final sibling = record(
        EntityKind.shot,
        'Reverse',
        parent: 'scene',
        project: 'project',
      );
      await repo.save(sibling, baseRevision: 0);
      await expectLater(repo.setLightNumber(sibling, '3'), throwsStateError);
      final next = await repo.setLightNumber(sibling, '10');
      expect(compareLightRecords(numbered, next), lessThan(0));
      expect(
        parseLightNumber('0003'),
        parseLightNumber(lightRecordNumber(numbered)),
      );
      final day = record(
        EntityKind.shootDay,
        'other-day',
        parent: 'project',
        project: 'project',
      );
      await repo.save(day, baseRevision: 0);
      final scene = (await repo.get('scene'))!;
      await repo.setLightNumber(scene, '02');
      final other = record(
        EntityKind.scene,
        'Other day scene',
        parent: day.id,
        project: 'project',
      );
      await repo.save(other, baseRevision: 0);
      expect(lightRecordNumber(await repo.setLightNumber(other, '2')), '2');
    },
  );

  test(
    'Light Plan rejects a concurrent next take and restores creation atomically',
    () async {
      final shot = await seedShot();
      Future<List<ProductionRecord>> create([ProductionRecord? source]) =>
          repo.createLightRecord(
            kind: LightPlanCreation.take,
            shootDayId: 'day',
            sceneId: 'scene',
            shotId: shot.id,
            source: source,
          );
      final first = (await create()).single;
      expect(first.title, '01');
      expect(readLightCanvas(first).objects, hasLength(1));
      final results = await Future.wait([
        for (var i = 0; i < 2; i++)
          create(
            first,
          ).then<Object>((value) => value, onError: (Object error) => error),
      ]);
      expect(results.whereType<StateError>(), hasLength(1));
      final branch = results.whereType<List<ProductionRecord>>().single;
      expect(branch.single.title, '02');
      expect(branch.single.data['frame_grabs'], isEmpty);
      final hidden = await repo.setLightCreationVisible(branch, visible: false);
      expect(await repo.children(shot.id), hasLength(1));
      final restored = await repo.setLightCreationVisible(
        hidden,
        visible: true,
      );
      expect(restored.single.id, branch.single.id);
      expect(await repo.children(shot.id), hasLength(2));
    },
  );

  test(
    'Light Plan creation rolls back on a failed take journal insert',
    () async {
      await seedShot();
      await db.execute(r"""
      CREATE TRIGGER reject_take BEFORE INSERT ON operations
      WHEN json_extract(NEW.payload, '$.entity_type') = 'take'
      BEGIN SELECT RAISE(ABORT, 'test rollback'); END
    """);
      final count = await repo.pendingCount();
      await expectLater(
        repo.createLightRecord(
          kind: LightPlanCreation.scene,
          shootDayId: 'day',
          numbers: const ['02', '01', '01'],
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(await repo.children('day'), hasLength(1));
      expect(await repo.pendingCount(), count);
    },
  );

  test('pending take capture reopens with its exact take and slot', () async {
    final shot = await seedShot();
    final take = (await repo.createLightRecord(
      kind: LightPlanCreation.take,
      shootDayId: 'day',
      sceneId: 'scene',
      shotId: shot.id,
    )).single;
    await repo.startCapture(
      shot.id,
      2,
      'take-image',
      take.revision,
      destinationTakeId: take.id,
    );
    await db.close();
    await open();
    final pending = (await repo.pendingCapture())!;
    final saved = await repo.attachFrame(
      shotId: pending['shot_id'] as String,
      slot: pending['slot'] as int,
      assetId: pending['asset_id'] as String,
      destinationTakeId: pending['destination_take_id'] as String,
      expectedRevision: pending['base_revision'] as int,
      frame: prepareFrame(
        Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
      ),
    );
    expect(saved.id, take.id);
    expect((saved.data['frame_grabs'] as Map).keys, ['2']);
    expect((await repo.get(shot.id))!.data['frame_grabs'], isNull);
    expect(await repo.pendingCapture(), isNull);
  });

  test(
    'project camera defaults initialize only new shots and preserve existing take baselines',
    () async {
      final oldShot = await seedShot();
      final project = (await repo.get('project'))!;
      await repo.save(
        project.edit(
          actor: 'user',
          at: time,
          data: {
            'details': {
              'default_fps': 24,
              'camera_format': 'ProRes',
              'timezone': 'Asia/Kolkata',
            },
          },
        ),
        baseRevision: project.revision,
      );
      await repo.save(
        record(
          EntityKind.shot,
          'new-shot',
          parent: 'scene',
          project: 'project',
        ),
        baseRevision: 0,
      );
      final newShot = (await repo.get('new-shot'))!;
      expect(readCameras(newShot.data['cameras'])['A Cam'], {
        'fps': 24,
        'format': 'ProRes',
      });
      expect(
        readCameras(
          (await repo.get(oldShot.id))!.data['cameras'],
        )['A Cam']!['iso'],
        800,
      );
      await repo.save(
        record(
          EntityKind.take,
          'new-take',
          parent: 'new-shot',
          project: 'project',
        ),
        baseRevision: 0,
      );
      final latestProject = (await repo.get('project'))!;
      await repo.save(
        latestProject.edit(
          actor: 'user',
          at: time,
          data: {
            'details': {
              'default_fps': 60,
              'camera_format': 'RAW',
              'timezone': 'UTC',
            },
          },
        ),
        baseRevision: latestProject.revision,
      );
      expect(
        readCameras(
          (await repo.get('new-take'))!.data['camera_baseline'],
        )['A Cam']!['fps'],
        24,
      );
      expect(
        readCameras(
          (await repo.get('new-shot'))!.data['cameras'],
        )['A Cam']!['format'],
        'ProRes',
      );
      await repo.save(
        record(
          EntityKind.shot,
          'later-shot',
          parent: 'scene',
          project: 'project',
        ),
        baseRevision: 0,
      );
      expect(
        readCameras(
          (await repo.get('later-shot'))!.data['cameras'],
        )['A Cam']!['fps'],
        60,
      );
    },
  );
  test(
    'recorded take time survives edits and locked camera overrides require an explicit unlock',
    () async {
      await seedShot();
      final take = ProductionRecord.fromJson({
        ...record(
          EntityKind.take,
          'logged',
          parent: 'shot',
          project: 'project',
        ).toJson(),
        'data': {
          'details': {'status': 'recorded', 'locked': true},
        },
      });
      await repo.save(take, baseRevision: 0);
      final saved = (await repo.get('logged'))!;
      final timestamp = (saved.data['details'] as Map)['recorded_at_utc'];
      await expectLater(
        repo.save(
          saved.edit(
            actor: 'user',
            at: time,
            data: {
              ...saved.data,
              'camera_overrides': {
                'A Cam': {'iso': 1600},
              },
            },
          ),
          baseRevision: 1,
        ),
        throwsStateError,
      );
      await repo.save(
        saved.edit(
          actor: 'user',
          at: time.add(const Duration(days: 1)),
          data: {
            ...saved.data,
            'details': {
              ...(saved.data['details'] as Map<String, Object?>),
              'locked': false,
              'recorded_at_utc': '2030-01-01T00:00:00.000Z',
            },
          },
        ),
        baseRevision: 1,
      );
      final unlocked = (await repo.get('logged'))!;
      expect((unlocked.data['details'] as Map)['recorded_at_utc'], timestamp);
      await repo.save(
        unlocked.edit(
          actor: 'user',
          at: time,
          data: {
            ...unlocked.data,
            'camera_overrides': {
              'A Cam': {'iso': 1600},
            },
          },
        ),
        baseRevision: 2,
      );
      expect(
        readCameras(
          (await repo.get('logged'))!.data['camera_baseline'],
        )['A Cam']!['iso'],
        800,
      );
      expect(
        readCameras(
          (await repo.get('logged'))!.data['camera_overrides'],
        )['A Cam']!['iso'],
        1600,
      );
    },
  );

  test(
    'shot duplication clones geometry and media with fresh IDs without copying takes',
    () async {
      final shot = await seedShot();
      final frame = prepareFrame(
        Uint8List.fromList(img.encodePng(img.Image(width: 32, height: 18))),
      );
      final source = await repo.attachFrame(
        shotId: shot.id,
        slot: 1,
        assetId: 'source-asset',
        frame: frame,
        expectedRevision: 1,
      );
      await repo.save(
        record(EntityKind.take, 'take', parent: shot.id, project: 'project'),
        baseRevision: 0,
      );
      final result = await repo.duplicateShot(
        shot.id,
        expectedRevision: source.revision,
        title: 'Alternate shot',
      );
      expect(result.copiedMedia, 1);
      expect(result.missingMedia, 0);
      expect(result.shot.id, isNot(shot.id));
      expect(result.shot.parentId, shot.parentId);
      expect(result.shot.data['cameras'], source.data['cameras']);
      final copiedPlan = LightingPlan.fromJson(
        Map<String, dynamic>.from(result.shot.data['lighting_plan'] as Map),
      );
      expect(copiedPlan.objects.single.id, isNot('fixture'));
      expect(copiedPlan.objects.single.x, 2);
      final asset =
          ((result.shot.data['frame_grabs'] as Map)['1'] as Map)['asset_id']
              as String;
      expect(asset, isNot('source-asset'));
      expect(await repo.originalFrame(result.shot.id, asset), frame.original);
      expect(await repo.originalFrame(shot.id, 'source-asset'), frame.original);
      expect(await repo.children(result.shot.id), isEmpty);
      final recordCount = (await db.query('records')).length,
          mediaCount = (await db.query('frame_assets')).length;
      await db.execute(
        "CREATE TRIGGER fail_duplicate BEFORE INSERT ON operations BEGIN SELECT RAISE(ABORT, 'disk simulation'); END",
      );
      await expectLater(
        repo.duplicateShot(
          shot.id,
          expectedRevision: source.revision,
          title: 'Must roll back',
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect((await db.query('records')).length, recordCount);
      expect((await db.query('frame_assets')).length, mediaCount);
    },
  );
  test(
    'duplication preserves unavailable media state and rejects stale source revisions',
    () async {
      final shot = await seedShot();
      final source = shot.edit(
        actor: 'user',
        at: time,
        data: {
          ...shot.data,
          'frame_grabs': {
            '2': {'asset_id': 'unavailable', 'notes': 'Reference pending'},
          },
        },
      );
      await repo.save(source, baseRevision: 1);
      await expectLater(
        repo.duplicateShot(shot.id, expectedRevision: 1, title: 'Stale'),
        throwsStateError,
      );
      final duplicate = await repo.duplicateShot(
        shot.id,
        expectedRevision: 2,
        title: 'Recovered copy',
      );
      expect(duplicate.missingMedia, 1);
      expect(duplicate.copiedMedia, 0);
      final ref = (duplicate.shot.data['frame_grabs'] as Map)['2'] as Map;
      expect(ref['asset_id'], isNot('unavailable'));
      expect(
        await repo.framePreview(duplicate.shot.id, ref['asset_id'] as String),
        isNull,
      );
      final noFrames = await repo.duplicateShot(
        shot.id,
        expectedRevision: 2,
        title: 'No grabs',
        includeFrames: false,
      );
      expect(noFrames.shot.data['frame_grabs'], isEmpty);
    },
  );
  test(
    'project presets persist through restart and portable backup, with scope/revision checks',
    () async {
      final shot = await seedShot();
      final plan = LightingPlan.fromJson(
        Map<String, dynamic>.from(shot.data['lighting_plan'] as Map),
      );
      await repo.saveLightingPreset(
        projectId: 'project',
        name: 'Window key',
        plan: plan,
        sourceShotId: 'shot',
        sourceRevision: 1,
      );
      await db.close();
      await open();
      final preset = (await repo.lightingPresets('project')).single;
      expect(preset.name, 'Window key');
      expect(preset.plan.objects.single.kelvin, 5600);
      final archive = CinepackSnapshot.decode(
        (await repo.projectSnapshot('project')).encode(),
      );
      expect(
        (archive.records
                    .singleWhere((r) => r.kind == EntityKind.project)
                    .data['lighting_presets']
                as List)
            .length,
        1,
      );
      await expectLater(
        repo.saveLightingPreset(
          projectId: 'project',
          name: 'Stale',
          plan: plan,
          sourceShotId: 'shot',
          sourceRevision: 999,
        ),
        throwsStateError,
      );
      await repo.save(
        record(EntityKind.project, 'other', parent: 'org', project: 'other'),
        baseRevision: 0,
      );
      await expectLater(
        repo.saveLightingPreset(
          projectId: 'other',
          name: 'Wrong project',
          plan: plan,
          sourceShotId: 'shot',
          sourceRevision: 1,
        ),
        throwsStateError,
      );
      expect((await repo.lightingPresets('project')).length, 1);
      expect(await repo.lightingPresets('other'), isEmpty);
    },
  );

  test(
    'complete hierarchy, rename and journal survive database reopen',
    () async {
      final chain = [
        record(EntityKind.organization, 'org'),
        record(
          EntityKind.project,
          'project',
          parent: 'org',
          project: 'project',
        ),
        record(
          EntityKind.shootDay,
          'day',
          parent: 'project',
          project: 'project',
        ),
        record(EntityKind.scene, 'scene', parent: 'day', project: 'project'),
        record(EntityKind.shot, 'shot', parent: 'scene', project: 'project'),
        record(EntityKind.take, 'take', parent: 'shot', project: 'project'),
      ];
      for (final item in chain) {
        await repo.save(item, baseRevision: 0);
      }
      await repo.save(
        chain.last.edit(title: 'Take 02', actor: 'user', at: time),
        baseRevision: 1,
      );
      await db.close();
      await open();
      expect((await repo.get('take'))!.title, 'Take 02');
      expect(await repo.pendingCount(), 7);
      expect((await repo.children('shot')).single.id, 'take');
      final restored = ProductionRecord.fromJson(
        (await repo.get('take'))!.toJson(),
      );
      expect(restored.revision, 2);
      expect(restored.updatedAt.isUtc, isTrue);
    },
  );
  test(
    'take baselines survive changed shot defaults, sparse overrides and reopen',
    () async {
      final chain = [
        record(EntityKind.organization, 'org'),
        record(
          EntityKind.project,
          'project',
          parent: 'org',
          project: 'project',
        ),
        record(
          EntityKind.shootDay,
          'day',
          parent: 'project',
          project: 'project',
        ),
        record(EntityKind.scene, 'scene', parent: 'day', project: 'project'),
      ];
      for (final item in chain) {
        await repo.save(item, baseRevision: 0);
      }
      final shot = ProductionRecord.fromJson({
        ...record(
          EntityKind.shot,
          'shot',
          parent: 'scene',
          project: 'project',
        ).toJson(),
        'data': {
          'cameras': {
            'A Cam': {'iso': 800, 'focal_mm': 35},
            'B Cam': {'iso': 400},
          },
        },
      });
      await repo.save(shot, baseRevision: 0);
      final take = record(
        EntityKind.take,
        'take',
        parent: 'shot',
        project: 'project',
      );
      await repo.save(take, baseRevision: 0);
      await repo.save(
        shot.edit(
          actor: 'user',
          at: time,
          data: {
            'cameras': {
              'A Cam': {'iso': 1600},
              'B Cam': {'iso': 640},
            },
          },
        ),
        baseRevision: 1,
      );
      final savedTake = (await repo.get('take'))!;
      await repo.save(
        savedTake.edit(
          actor: 'user',
          at: time,
          data: {
            ...savedTake.data,
            'camera_overrides': {
              'A Cam': {'iso': 1250},
            },
          },
        ),
        baseRevision: 1,
      );
      await db.close();
      await open();
      final restored = (await repo.get('take'))!;
      final cameras = readCameras(restored.data['camera_baseline']);
      expect(cameras['A Cam']!['iso'], 800);
      expect(cameras['B Cam']!['iso'], 400);
      expect(restored.data['baseline_shot_revision'], 1);
      expect(
        effectiveSettings(
          cameras['A Cam']!,
          readCameras(restored.data['camera_overrides'])['A Cam']!,
        ),
        {'iso': 1250, 'focal_mm': 35},
      );
      await repo.save(
        record(EntityKind.take, 'later', parent: 'shot', project: 'project'),
        baseRevision: 0,
      );
      expect(
        readCameras(
          (await repo.get('later'))!.data['camera_baseline'],
        )['A Cam']!['iso'],
        1600,
      );
      final tampered = restored.edit(
        actor: 'user',
        at: time,
        data: {
          ...restored.data,
          'camera_baseline': {
            'A Cam': {'iso': 999},
          },
          'baseline_shot_revision': 999,
        },
      );
      await repo.save(tampered, baseRevision: 2);
      expect(
        readCameras(
          (await repo.get('take'))!.data['camera_baseline'],
        )['A Cam']!['iso'],
        800,
      );
    },
  );
  test(
    'project backup restore is atomic, idempotent and conflict-aware',
    () async {
      await repo.save(record(EntityKind.organization, 'org'), baseRevision: 0);
      final project = record(
        EntityKind.project,
        'project',
        parent: 'org',
        project: 'project',
      );
      await repo.save(project, baseRevision: 0);
      await repo.save(
        project.edit(title: 'Production', actor: 'user', at: time),
        baseRevision: 1,
      );
      final snapshot = CinepackSnapshot.decode(
        (await repo.projectSnapshot('project')).encode(),
      );
      final targetDb = await databaseFactoryFfi.openDatabase(
        '${temp.path}/restore.db',
        options: OpenDatabaseOptions(
          version: WorkspaceRepository.schemaVersion,
          onCreate: WorkspaceRepository.migrate,
        ),
      );
      final target = WorkspaceRepository(
        targetDb,
        deviceId: 'recovery-device',
        actorId: 'recovery-user',
      );
      try {
        expect((await target.previewRestore(snapshot)).newRecords, 2);
        await targetDb.execute(
          "CREATE TRIGGER fail_restore BEFORE INSERT ON operations BEGIN SELECT RAISE(ABORT, 'disk simulation'); END",
        );
        await expectLater(
          target.restoreSnapshot(snapshot),
          throwsA(isA<DatabaseException>()),
        );
        expect(await target.get('org'), isNull);
        await targetDb.execute('DROP TRIGGER fail_restore');
        await target.restoreSnapshot(snapshot);
        expect((await target.get('project'))!.revision, 2);
        expect((await target.get('project'))!.title, 'Production');
        expect(await target.pendingCount(), 2);
        expect((await target.restoreSnapshot(snapshot)).identicalRecords, 2);
        expect(await target.pendingCount(), 2);
        final local = (await target.get('project'))!;
        await target.save(
          local.edit(
            title: 'Local alternative',
            actor: 'recovery-user',
            at: time,
          ),
          baseRevision: local.revision,
        );
        final preview = await target.previewRestore(snapshot);
        expect(preview.conflictingIds, ['project']);
        await expectLater(target.restoreSnapshot(snapshot), throwsStateError);
        expect((await target.get('project'))!.title, 'Local alternative');
        expect(await target.pendingCount(), 3);
      } finally {
        await targetDb.close();
      }
    },
  );
  test(
    'frame bytes, references and dependencies persist atomically and retry idempotently',
    () async {
      final chain = [
        record(EntityKind.organization, 'org'),
        record(
          EntityKind.project,
          'project',
          parent: 'org',
          project: 'project',
        ),
        record(
          EntityKind.shootDay,
          'day',
          parent: 'project',
          project: 'project',
        ),
        record(EntityKind.scene, 'scene', parent: 'day', project: 'project'),
        record(EntityKind.shot, 'shot', parent: 'scene', project: 'project'),
      ];
      for (final item in chain) {
        await repo.save(item, baseRevision: 0);
      }
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 32, height: 18)),
      );
      final frame = prepareFrame(bytes);
      await repo.startCapture('shot', 1, 'asset-one', 1);
      await db.execute(
        "CREATE TRIGGER fail_media_journal BEFORE INSERT ON operations BEGIN SELECT RAISE(ABORT, 'disk simulation'); END",
      );
      await expectLater(
        repo.attachFrame(
          shotId: 'shot',
          slot: 1,
          assetId: 'asset-one',
          frame: frame,
          expectedRevision: 1,
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(await repo.framePreview('shot', 'asset-one'), isNull);
      expect((await repo.pendingCapture())!['asset_id'], 'asset-one');
      expect((await repo.get('shot'))!.revision, 1);
      await db.execute('DROP TRIGGER fail_media_journal');
      await repo.attachFrame(
        shotId: 'shot',
        slot: 1,
        assetId: 'asset-one',
        frame: frame,
        expectedRevision: 1,
      );
      await repo.attachFrame(
        shotId: 'shot',
        slot: 1,
        assetId: 'asset-one',
        frame: frame,
        expectedRevision: 1,
      );
      expect(await repo.pendingCount(), 6);
      expect(await repo.pendingCapture(), isNull);
      final op = jsonDecode(
        (await db.query(
              'operations',
              orderBy: 'sequence DESC',
              limit: 1,
            )).single['payload']
            as String,
      );
      expect(op['attachment_dependencies'], ['asset-one']);
      await db.close();
      await open();
      expect(await repo.originalFrame('shot', 'asset-one'), bytes);
      expect((await repo.framePreview('shot', 'asset-one'))!.width, 32);
      expect(await repo.originalFrame('unrelated-shot', 'asset-one'), isNull);
      await repo.attachFrame(
        shotId: 'shot',
        slot: 1,
        assetId: 'replacement',
        frame: frame,
        expectedRevision: 2,
      );
      expect(await repo.originalFrame('shot', 'asset-one'), bytes);
      await db.update(
        'frame_assets',
        {
          'original': Uint8List.fromList([1, 2, 3]),
        },
        where: 'asset_id = ?',
        whereArgs: ['asset-one'],
      );
      await expectLater(
        repo.originalFrame('shot', 'asset-one'),
        throwsStateError,
      );
    },
  );
  test(
    'schema upgrade preserves v1 records and adds media/capture recovery tables',
    () async {
      await db.execute('DROP TABLE frame_assets');
      await db.execute('DROP TABLE capture_intents');
      await db.setVersion(1);
      await repo.save(record(EntityKind.organization, 'org'), baseRevision: 0);
      await db.close();
      db = await databaseFactoryFfi.openDatabase(
        '${temp.path}/test.db',
        options: OpenDatabaseOptions(
          version: WorkspaceRepository.schemaVersion,
          onUpgrade: WorkspaceRepository.upgrade,
        ),
      );
      repo = WorkspaceRepository(db, deviceId: 'device', actorId: 'user');
      expect((await repo.get('org'))!.title, 'org');
      expect(await db.query('frame_assets'), isEmpty);
      await repo.startCapture('shot', 2, 'capture-id', 4);
      await repo.stageCapturePath('test-camera-cache.jpg');
      await db.close();
      await open();
      expect(
        (await repo.pendingCapture())!['source_path'],
        'test-camera-cache.jpg',
      );
      await expectLater(
        repo.startCapture('other', 1, 'second', 1),
        throwsStateError,
      );
    },
  );
  test('wrong hierarchy and cross-organization inserts roll back', () async {
    await repo.save(record(EntityKind.organization, 'org'), baseRevision: 0);
    await expectLater(
      repo.save(
        record(EntityKind.scene, 'bad', parent: 'org', project: 'p'),
        baseRevision: 0,
      ),
      throwsStateError,
    );
    await expectLater(
      repo.save(
        record(
          EntityKind.project,
          'other',
          parent: 'org',
          project: 'other',
          org: 'outsider',
        ),
        baseRevision: 0,
      ),
      throwsStateError,
    );
    expect(await repo.get('bad'), isNull);
    expect(await repo.pendingCount(), 1);
  });
  test('stale write cannot overwrite a saved revision', () async {
    final root = record(EntityKind.organization, 'org');
    await repo.save(root, baseRevision: 0);
    await repo.save(
      root.edit(title: 'First', actor: 'user', at: time),
      baseRevision: 1,
    );
    await expectLater(
      repo.save(
        root.edit(title: 'Stale', actor: 'user', at: time),
        baseRevision: 1,
      ),
      throwsStateError,
    );
    expect((await repo.get('org'))!.title, 'First');
    expect(await repo.pendingCount(), 2);
  });
  test(
    'parent deletion protected; tombstone retained and cannot be edited',
    () async {
      final root = record(EntityKind.organization, 'org');
      final project = record(
        EntityKind.project,
        'p',
        parent: 'org',
        project: 'p',
      );
      await repo.save(root, baseRevision: 0);
      await repo.save(project, baseRevision: 0);
      await expectLater(
        repo.save(
          root.edit(actor: 'user', at: time, delete: true),
          baseRevision: 1,
        ),
        throwsStateError,
      );
      await repo.save(
        project.edit(actor: 'user', at: time, delete: true),
        baseRevision: 1,
      );
      expect(await repo.children('org'), isEmpty);
      final tombstone = (await repo.get('p'))!;
      expect(tombstone.deletedAt, isNotNull);
      await expectLater(
        repo.save(
          tombstone.edit(title: 'revive', actor: 'user', at: time),
          baseRevision: 2,
        ),
        throwsStateError,
      );
    },
  );
  test('journal failure rolls back the materialized record', () async {
    await db.execute(
      "CREATE TRIGGER fail_journal BEFORE INSERT ON operations BEGIN SELECT RAISE(ABORT, 'disk simulation'); END",
    );
    await expectLater(
      repo.save(record(EntityKind.organization, 'org'), baseRevision: 0),
      throwsA(isA<DatabaseException>()),
    );
    expect(await repo.get('org'), isNull);
    expect(await repo.pendingCount(), 0);
  });
}

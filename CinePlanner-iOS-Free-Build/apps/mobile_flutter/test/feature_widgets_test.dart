import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart' as fs;
import 'package:image/image.dart' as img;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cineplanner/data/workspace_repository.dart';
import 'package:cineplanner/domain/production.dart';
import 'package:cineplanner/domain/lighting_plan.dart';
import 'package:cineplanner/domain/camera_settings.dart';
import 'package:cineplanner/domain/frame_grab.dart';
import 'package:cineplanner/domain/light_plan.dart';
import 'package:cineplanner/features/light_plan_screen.dart';
import 'package:cineplanner/features/plan_editor.dart';
import 'package:cineplanner/features/camera_editor.dart';
import 'package:cineplanner/features/frame_grabs.dart';
import 'package:cineplanner/main.dart';
import 'package:cineplanner/features/production_details_editor.dart';
import 'package:cineplanner/ui/cine_theme.dart';

void main() {
  sqfliteFfiInit();
  Future<WorkspaceRepository> prepare(WidgetTester tester) async {
    return (await tester.runAsync(() async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: WorkspaceRepository.schemaVersion,
          onCreate: WorkspaceRepository.migrate,
          singleInstance: false,
        ),
      );
      final repo = WorkspaceRepository(
        db,
        deviceId: 'test-device',
        actorId: 'test-user',
      );
      final now = DateTime.utc(2026, 11, 10);
      String? parent;
      for (final kind in EntityKind.values.take(5)) {
        final id = kind.name;
        await repo.save(
          ProductionRecord(
            id: id,
            kind: kind,
            organizationId: 'organization',
            projectId: kind == EntityKind.organization ? null : 'project',
            parentId: parent,
            title: id,
            revision: 1,
            createdAt: now,
            updatedAt: now,
            createdBy: 'test-user',
            updatedBy: 'test-user',
          ),
          baseRevision: 0,
        );
        parent = id;
      }
      return repo;
    }))!;
  }

  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
  }

  Future<void> settleLightPlan(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 80));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'import and swap frame grab slots persist bytes and stable asset references',
    (tester) async {
      final repo = await prepare(tester);
      final shot = (await tester.runAsync<ProductionRecord?>(
        () => repo.get('shot'),
      ))!;
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 32, height: 18)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: FrameGrabsScreen(
            repository: repo,
            shot: shot,
            chooseFile: () async => fs.XFile.fromData(bytes, name: 'frame.png'),
          ),
        ),
      );
      await settleIo(tester);
      await tester.ensureVisible(find.text('Import GRAB 1'));
      await tester.tap(find.text('Import GRAB 1'));
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        if (find.text('32 × 18 • Local only').evaluate().isNotEmpty) break;
      }
      expect(find.text('32 × 18 • Local only'), findsOneWidget);
      final saved = (await tester.runAsync<ProductionRecord?>(
        () => repo.get('shot'),
      ))!;
      final asset =
          ((saved.data['frame_grabs'] as Map)['1'] as Map)['asset_id']
              as String;
      expect(
        await tester.runAsync(() => repo.originalFrame('shot', asset)),
        bytes,
      );
      await tester.tap(find.byTooltip('Swap grabs'));
      await settleIo(tester);
      final swapped = (await tester.runAsync<ProductionRecord?>(
        () => repo.get('shot'),
      ))!;
      expect((swapped.data['frame_grabs'] as Map).containsKey('1'), isFalse);
      expect(
        ((swapped.data['frame_grabs'] as Map)['2'] as Map)['asset_id'],
        asset,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(repo.db.close);
    },
  );
  testWidgets(
    'object drag commits one snapped world-space move and polyline taps persist',
    (tester) async {
      final repo = await prepare(tester);
      final shot = (await tester.runAsync<ProductionRecord?>(
        () => repo.get('shot'),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: PlanEditor(repository: repo, shot: shot),
        ),
      );
      await tester.tap(find.text('camera'));
      await settleIo(tester);
      await tester.tap(find.text('Snap 25 cm'));
      await tester.pumpAndSettle();
      final canvas = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is LightingPainter,
      );
      final start = tester.getTopLeft(canvas) + const Offset(150, 150);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(22, 0));
      await tester.pump();
      expect(await tester.runAsync(() => repo.pendingCount()), 6);
      await gesture.up();
      await settleIo(tester);
      final saved = (await tester.runAsync<ProductionRecord?>(
        () => repo.get('shot'),
      ))!;
      final plan = LightingPlan.fromJson(
        Map<String, dynamic>.from(saved.data['lighting_plan'] as Map),
      );
      expect(plan.objects.single.x, 2.75);
      expect(plan.objects.single.y, 2);
      expect(await tester.runAsync(() => repo.pendingCount()), 7);
      final resize = await tester.startGesture(
        tester.getTopLeft(canvas) + const Offset(225, 180),
      );
      await resize.moveBy(const Offset(30, 30));
      await tester.pump();
      await resize.up();
      await settleIo(tester);
      final resized = (await tester.runAsync<ProductionRecord?>(
        () => repo.get('shot'),
      ))!;
      final resizedPlan = LightingPlan.fromJson(
        Map<String, dynamic>.from(resized.data['lighting_plan'] as Map),
      );
      expect(resizedPlan.objects.single.width, 1.5);
      expect(resizedPlan.objects.single.height, 1.5);
      expect(await tester.runAsync(() => repo.pendingCount()), 8);
      await tester.tap(find.text('Pan / zoom'));
      await tester.pumpAndSettle();
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      final center =
          tester.getTopLeft(find.byType(InteractiveViewer)) +
          const Offset(220, 140);
      final fingerOne = await tester.startGesture(
        center - const Offset(40, 0),
        pointer: 10,
      );
      final fingerTwo = await tester.startGesture(
        center + const Offset(40, 0),
        pointer: 11,
      );
      await tester.pump();
      await fingerOne.moveTo(center - const Offset(90, 0));
      await fingerTwo.moveTo(center + const Offset(90, 0));
      await tester.pump();
      await fingerOne.up();
      await fingerTwo.up();
      await tester.pumpAndSettle();
      expect(
        viewer.transformationController!.value.getMaxScaleOnAxis(),
        greaterThan(1),
      );
      expect(await tester.runAsync(() => repo.pendingCount()), 8);
      viewer.transformationController!.value = Matrix4.identity();
      await tester.pump();
      await tester.tap(find.text('Polyline'));
      await tester.pumpAndSettle();
      final origin = tester.getTopLeft(canvas);
      await tester.tapAt(origin + const Offset(60, 60));
      await tester.pump();
      await tester.tapAt(origin + const Offset(120, 120));
      await tester.pump();
      await tester.tapAt(origin + const Offset(180, 60));
      await tester.pump();
      await tester.tap(find.text('Finish polyline'));
      await settleIo(tester);
      final after = (await tester.runAsync<ProductionRecord?>(
        () => repo.get('shot'),
      ))!;
      final restored = LightingPlan.fromJson(
        Map<String, dynamic>.from(after.data['lighting_plan'] as Map),
      );
      expect(restored.strokes.single.kind, 'polyline');
      expect(restored.strokes.single.points.length, 3);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(repo.db.close);
    },
  );
  testWidgets(
    'save and repeatedly apply a project preset with independent identities',
    (tester) async {
      final repo = await prepare(tester);
      final shot = (await tester.runAsync<ProductionRecord?>(() async {
        final old = (await repo.get('shot'))!;
        final updated = old.edit(
          actor: 'test-user',
          at: DateTime.now(),
          data: {
            'cameras': {
              'A Cam': {'iso': 800},
            },
          },
        );
        await repo.save(updated, baseRevision: old.revision);
        return updated;
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          home: PlanEditor(repository: repo, shot: shot),
        ),
      );
      await tester.tap(find.text('camera'));
      await settleIo(tester);
      await tester.tap(find.byTooltip('Save lighting preset'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Night setup');
      await tester.tap(find.text('Save preset'));
      await settleIo(tester);
      expect(
        (await tester.runAsync(
          () => repo.lightingPresets('project'),
        ))!.single.name,
        'Night setup',
      );
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('Apply lighting preset'));
        await settleLightPlan(tester);
        await tester.tap(find.text('Night setup'));
        await settleLightPlan(tester);
      }
      final saved = (await tester.runAsync<ProductionRecord?>(
        () => repo.get('shot'),
      ))!;
      final plan = LightingPlan.fromJson(
        Map<String, dynamic>.from(saved.data['lighting_plan'] as Map),
      );
      expect(plan.objects.length, 3);
      expect(plan.objects.map((o) => o.id).toSet().length, 3);
      expect(readCameras(saved.data['cameras'])['A Cam']!['iso'], 800);
      expect(
        (await tester.runAsync(
          () => repo.lightingPresets('project'),
        ))!.single.plan.objects.length,
        1,
      );
      await tester.tap(find.byTooltip('Undo'));
      await settleIo(tester);
      final undone = (await tester.runAsync<ProductionRecord?>(
        () => repo.get('shot'),
      ))!;
      expect(
        LightingPlan.fromJson(
          Map<String, dynamic>.from(undone.data['lighting_plan'] as Map),
        ).objects.length,
        2,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(repo.db.close);
    },
  );
  testWidgets(
    'Light Plan navigates by number and keeps the responsive image-first layout',
    (tester) async {
      final repo = await prepare(tester);
      final boundary = GlobalKey();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 768);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.runAsync(() async {
        final text = FontLoader('Noto Sans')
          ..addFont(rootBundle.load('assets/fonts/NotoSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/NotoSans-Bold.ttf'));
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await Future.wait([text.load(), icons.load()]);
      });

      Widget review(Widget home) => RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: CineTheme.data,
          home: home,
        ),
      );
      Future<void> capture(String name) async {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            final file = File(
              'build/verification/touch-navigation-checks/$name.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      final scene = (await tester.runAsync<ProductionRecord?>(
        () => repo.get('scene'),
      ))!;
      await tester.runAsync(() async {
        final shot = (await repo.get('shot'))!;
        await repo.save(
          shot.edit(
            title: '03B · Kitchen wide',
            actor: repo.actorId,
            at: DateTime.now(),
            data: {
              'lighting_plan': LightingPlan([
                const PlanObject(
                  id: 'key',
                  symbol: SymbolKind.ledPanel,
                  x: 2,
                  y: 2,
                  label: 'Key light',
                ),
                const PlanObject(
                  id: 'subject',
                  symbol: SymbolKind.actor,
                  x: 4.2,
                  y: 3.3,
                  label: 'Subject',
                ),
                const PlanObject(
                  id: 'camera',
                  symbol: SymbolKind.camera,
                  x: 4.2,
                  y: 5.2,
                  label: 'A Camera',
                ),
              ]).toJson(),
            },
          ),
          baseRevision: shot.revision,
        );
      });
      await tester.pumpWidget(
        review(HierarchyScreen(repository: repo, parent: scene)),
      );
      await settleLightPlan(tester);
      await capture('workspace-1024x768');
      expect(find.text('Add shot'), findsNothing);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Duplicate shot'), findsNothing);
      await tester.tap(find.text('Open Light Plan'));
      await settleLightPlan(tester);
      expect(find.byTooltip('Add'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
        isNotNull,
      );
      expect(find.byTooltip('Print Data'), findsOneWidget);
      expect(find.byTooltip('Retake Grab 2'), findsNothing);
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New Take'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await settleLightPlan(tester);
      final take = (await tester.runAsync(() => repo.children('shot')))!.single;
      expect(take.title, '01');
      await tester.tap(find.byTooltip('Undo'));
      await settleLightPlan(tester);
      expect(await tester.runAsync(() => repo.children('shot')), isEmpty);
      await tester.tap(find.byTooltip('Redo'));
      await settleLightPlan(tester);
      expect(
        (await tester.runAsync(() => repo.children('shot')))!.single.id,
        take.id,
      );
      await tester.pumpWidget(const SizedBox());
      final populated = (await tester.runAsync(() async {
        var current = (await repo.get(take.id))!;
        for (final slot in [1, 2]) {
          final reference = img.Image(width: 160, height: 90);
          img.fill(
            reference,
            color: slot == 1
                ? img.ColorRgb8(101, 114, 104)
                : img.ColorRgb8(142, 105, 83),
          );
          img.fillRect(
            reference,
            x1: 20,
            y1: 14,
            x2: 70,
            y2: 70,
            color: img.ColorRgb8(224, 208, 167),
          );
          img.fillRect(
            reference,
            x1: 90,
            y1: 30,
            x2: 134,
            y2: 89,
            color: img.ColorRgb8(39, 43, 37),
          );
          current = await repo.attachFrame(
            shotId: 'shot',
            slot: slot,
            assetId: 'tablet-reference-$slot',
            expectedRevision: current.revision,
            destinationTakeId: take.id,
            frame: prepareFrame(Uint8List.fromList(img.encodePng(reference))),
          );
        }
        final next = (await repo.createLightRecord(
          kind: LightPlanCreation.take,
          shootDayId: 'shootDay',
          sceneId: 'scene',
          shotId: 'shot',
          source: current,
        )).single;
        await repo.setLightNumber(next, '05');
        await repo.save(
          ProductionRecord(
            id: 'other-day',
            kind: EntityKind.shootDay,
            organizationId: 'organization',
            projectId: 'project',
            parentId: 'project',
            title: 'Other day',
            revision: 1,
            createdAt: current.createdAt,
            updatedAt: current.updatedAt,
            createdBy: repo.actorId,
            updatedBy: repo.actorId,
          ),
          baseRevision: 0,
        );
        await repo.save(
          ProductionRecord(
            id: 'other-scene',
            kind: EntityKind.scene,
            organizationId: 'organization',
            projectId: 'project',
            parentId: 'other-day',
            title: 'Other day scene',
            revision: 1,
            createdAt: current.createdAt,
            updatedAt: current.updatedAt,
            createdBy: repo.actorId,
            updatedBy: repo.actorId,
          ),
          baseRevision: 0,
        );
        return current;
      }))!;
      await tester.pumpWidget(
        review(LightPlanScreen(repository: repo, entry: populated)),
      );
      await settleLightPlan(tester);
      expect(find.byType(Image), findsNWidgets(2));
      final slider = find.byKey(const ValueKey('light-take-slider'));
      expect(tester.widget<Slider>(slider).value, 0);
      expect(tester.widget<Slider>(slider).divisions, 1);
      final track = tester.getRect(slider);
      final drag = await tester.startGesture(
        Offset(track.left + 24, track.center.dy),
      );
      await drag.moveTo(Offset(track.right - 24, track.center.dy));
      await tester.pump();
      expect(find.byTooltip('Go to Take number'), findsOneWidget);
      expect(find.byType(Image), findsNWidgets(2));
      expect(tester.widget<Slider>(slider).value, 1);
      await drag.up();
      await settleLightPlan(tester);
      expect(
        find.descendant(
          of: find.byTooltip('Go to Take number'),
          matching: find.text('05'),
        ),
        findsOneWidget,
      );
      expect(find.byType(Image), findsNothing);
      expect(tester.widget<Slider>(slider).value, 1);
      await tester.tapAt(Offset(track.left + 24, track.center.dy));
      await settleLightPlan(tester);
      expect(tester.widget<Slider>(slider).value, 0);
      expect(find.byType(Image), findsNWidgets(2));
      expect(find.text('LIGHT PLAN'), findsNothing);
      expect(find.text('LIGHT + CAMERA PLAN'), findsNothing);

      await tester.tap(find.text('Go to'));
      await settleLightPlan(tester);
      final sceneRow = find.byKey(const ValueKey('light-go-to-scene'));
      expect(sceneRow, findsOneWidget);
      expect(find.text('Other day scene'), findsNothing);
      await tester.tap(
        find.descendant(of: sceneRow, matching: find.byTooltip('Set number')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '02');
      await tester.tap(find.text('Save number'));
      await settleLightPlan(tester);
      expect(find.text('scene'), findsOneWidget);
      await tester.tap(sceneRow);
      await settleLightPlan(tester);
      await tester.tap(find.byKey(const ValueKey('light-go-to-shot')));
      await settleLightPlan(tester);
      final second = (await tester.runAsync(
        () => repo.children('shot'),
      ))!.singleWhere((record) => lightRecordNumber(record) == '05');
      await tester.tap(find.byKey(ValueKey('light-go-to-${second.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open take'));
      await settleLightPlan(tester);
      expect(
        find.descendant(
          of: find.byTooltip('Go to Take number'),
          matching: find.text('05'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Go to Take number'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '1');
      await tester.tap(find.text('Go'));
      await settleLightPlan(tester);
      expect(find.text('01'), findsOneWidget);
      expect(find.byType(Image), findsNWidgets(2));
      final viewport = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      final viewer = find.byType(InteractiveViewer);
      final initialSize = tester.getSize(viewer);
      final center = viewport.toScene(initialSize.center(Offset.zero));
      double relativeZoom(Size size) =>
          viewport.value.getMaxScaleOnAxis() /
          math.min(size.width / 10, size.height / 8);
      final zoom = relativeZoom(initialSize);
      for (final size in [
        const Size(1024, 768),
        const Size(1280, 800),
        const Size(640, 360),
        const Size(390, 650),
      ]) {
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = size.width < 600
            ? 1.5
            : 1;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester
              .widget<InteractiveViewer>(find.byType(InteractiveViewer))
              .transformationController,
          same(viewport),
        );
        final sizeOnScreen = tester.getSize(viewer);
        final currentCenter = viewport.toScene(
          sizeOnScreen.center(Offset.zero),
        );
        expect((currentCenter - center).distance, closeTo(0, 0.001));
        expect(relativeZoom(sizeOnScreen), closeTo(zoom, 0.001));
        final redo = tester.getRect(find.byTooltip('Redo'));
        final add = tester.getRect(find.byTooltip('Add'));
        expect(add.left, greaterThanOrEqualTo(redo.right));
        expect(add.center.dy, closeTo(redo.center.dy, 0.001));
        expect(find.byTooltip('Upload Grab 1'), findsNothing);
        final canvas = tester.getRect(find.byType(PlanEditor));
        final firstGrab = tester.getRect(
          find.byTooltip('Show Grab 1 controls'),
        );
        if (size.width >= 600) {
          expect(canvas.right, lessThan(firstGrab.left));
          expect(canvas.width, greaterThan(size.width * .6));
        } else {
          expect(canvas.bottom, lessThan(firstGrab.top));
        }
        await capture(
          'light-plan-${size.width.toInt()}x${size.height.toInt()}',
        );
        final firstPreview = find.byTooltip('Show Grab 1 controls');
        await tester.ensureVisible(firstPreview);
        await tester.tap(firstPreview);
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byTooltip('Upload Grab 1')),
          const Size(48, 48),
        );
        expect(find.text('GRAB 1'), findsOneWidget);
        final secondPreview = find.byTooltip('Show Grab 2 controls');
        await tester.ensureVisible(secondPreview);
        await tester.tap(secondPreview);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Upload Grab 1'), findsNothing);
        expect(find.byTooltip('Retake Grab 2'), findsOneWidget);
        await tester.tap(find.byTooltip('Hide Grab 2 controls'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Retake Grab 2'), findsNothing);
      }

      tester.view.physicalSize = const Size(1280, 800);
      tester.platformDispatcher.textScaleFactorTestValue = 1;
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New Shot'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      final labels = find.byType(TextFormField);
      expect(labels, findsNWidgets(2));
      expect(
        tester.getTopLeft(labels.first).dy,
        tester.getTopLeft(labels.last).dy,
      );
      await capture('label-entry-1280x800');
      await tester.enterText(labels.first, '017');
      tester.view.physicalSize = const Size(390, 650);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('017'), findsOneWidget);
      expect(
        tester.getTopLeft(labels.first).dx,
        tester.getTopLeft(labels.last).dx,
      );
      expect(tester.getBottomRight(find.text('Save')).dy, lessThan(390));
      expect(find.text('Cancel').hitTestable(), findsOneWidget);
      await capture('label-entry-keyboard-390x650');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('01'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(repo.db.close);
    },
  );
  testWidgets(
    'shoot-day tap opens the first populated branch and header numbers settle on touch',
    (tester) async {
      final repo = await prepare(tester);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 768);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final project = (await tester.runAsync(() async {
        final stamp = DateTime.utc(2026, 11, 10);
        Future<void> add(
          String id,
          EntityKind kind,
          String parent, {
          String? number,
        }) => repo.save(
          ProductionRecord(
            id: id,
            kind: kind,
            title: id,
            organizationId: 'organization',
            projectId: 'project',
            parentId: parent,
            revision: 1,
            createdAt: stamp,
            updatedAt: stamp,
            createdBy: repo.actorId,
            updatedBy: repo.actorId,
            data: {lightNumberKey: ?number},
          ),
          baseRevision: 0,
        );
        await add('empty-day', EntityKind.shootDay, 'project');
        await add(
          'first-scene-empty',
          EntityKind.scene,
          'shootDay',
          number: '01',
        );
        await add('ready-scene', EntityKind.scene, 'shootDay', number: '02');
        await add('second-scene', EntityKind.scene, 'shootDay', number: '08');
        await add(
          'first-shot-empty',
          EntityKind.shot,
          'ready-scene',
          number: '01',
        );
        await add('ready-shot', EntityKind.shot, 'ready-scene', number: '03');
        await add('second-shot', EntityKind.shot, 'ready-scene', number: '08');
        await add('other-shot', EntityKind.shot, 'second-scene', number: '07');
        await add('ready-take-9', EntityKind.take, 'ready-shot', number: '09');
        await add('ready-take-3', EntityKind.take, 'ready-shot', number: '03');
        await add('second-take', EntityKind.take, 'second-shot', number: '06');
        await add('other-take', EntityKind.take, 'other-shot', number: '07');
        return repo.get('project');
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          theme: CineTheme.data,
          home: HierarchyScreen(repository: repo, parent: project),
        ),
      );
      await settleLightPlan(tester);
      await tester.tap(find.text('empty-day'));
      await settleLightPlan(tester);
      expect(find.byType(LightPlanScreen), findsOneWidget);
      expect(find.byType(PlanEditor), findsNothing);
      expect(find.byTooltip('Add'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settleLightPlan(tester);
      expect(find.text('shootDay'), findsOneWidget);
      await tester.tap(find.text('shootDay'));
      await settleLightPlan(tester);
      void currentTake(String number) => expect(
        find.descendant(
          of: find.byTooltip('Go to Take number'),
          matching: find.text(number),
        ),
        findsOneWidget,
      );
      currentTake('03');
      expect(find.byType(PlanEditor), findsOneWidget);
      final editor = find.byType(InteractiveViewer);
      final oldController = tester
          .widget<InteractiveViewer>(editor)
          .transformationController;
      await tester.tap(find.byTooltip('Pan / zoom'));
      await tester.drag(editor, const Offset(-80, 0));
      await tester.pumpAndSettle();
      currentTake('03');
      expect(
        tester.widget<InteractiveViewer>(editor).transformationController,
        same(oldController),
      );

      Future<void> scrollNext(String label, String destination) async {
        final scroller = find.byKey(ValueKey('light-numbers-$label'));
        final viewer = tester.widget<PageView>(scroller);
        final distance =
            tester.getSize(scroller).width *
            viewer.controller!.viewportFraction;
        final initialPage = viewer.controller!.page!;
        final gesture = await tester.startGesture(tester.getCenter(scroller));
        await gesture.moveBy(const Offset(-24, 0));
        await tester.pump();
        await gesture.moveBy(Offset(-distance * .85, 0));
        await tester.pump();
        expect(viewer.controller!.page!, greaterThan(initialPage + .5));
        expect(
          tester.widget<PlanEditor>(find.byType(PlanEditor)).shot.id,
          isNot(destination),
        );
        await gesture.up();
        await tester.pumpAndSettle();
        await settleLightPlan(tester);
        expect(
          tester.widget<PlanEditor>(find.byType(PlanEditor)).shot.id,
          destination,
        );
      }

      await scrollNext('Take', 'ready-take-9');
      currentTake('09');
      await scrollNext('Shot', 'second-take');
      currentTake('06');
      await scrollNext('Scene', 'other-take');
      currentTake('07');

      await tester.binding.handlePopRoute();
      await settleLightPlan(tester);
      final dayMenu = find.descendant(
        of: find.widgetWithText(ListTile, 'shootDay'),
        matching: find.byType(PopupMenuButton<String>),
      );
      await tester.tap(dayMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Browse scenes'));
      await settleLightPlan(tester);
      expect(find.text('ready-scene'), findsOneWidget);
      expect(find.byType(LightPlanScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(repo.db.close);
    },
  );

  testWidgets('production details editor saves typed project defaults', (
    tester,
  ) async {
    final repo = await prepare(tester);
    final project = (await tester.runAsync<ProductionRecord?>(
      () => repo.get('project'),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: ProductionDetailsEditor(repository: repo, record: project),
      ),
    );
    await settleIo(tester);
    await tester.enterText(
      find.byKey(const ValueKey('1:client')),
      'Northlight Films',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('1:default_fps')));
    await tester.enterText(find.byKey(const ValueKey('1:default_fps')), '24');
    await tester.ensureVisible(find.byKey(const ValueKey('1:timezone')));
    await tester.enterText(
      find.byKey(const ValueKey('1:timezone')),
      'Asia/Kolkata',
    );
    await tester.tap(find.text('Save locally'));
    await settleIo(tester);
    final saved = (await tester.runAsync<ProductionRecord?>(
      () => repo.get('project'),
    ))!;
    expect((saved.data['details'] as Map)['default_fps'], 24);
    expect((saved.data['details'] as Map)['client'], 'Northlight Films');
    expect((saved.data['details'] as Map)['timezone'], 'Asia/Kolkata');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(repo.db.close);
  });
  testWidgets(
    'hierarchy search, natural sorting and archive visibility do not create operations',
    (tester) async {
      final repo = await prepare(tester);
      await tester.runAsync(() async {
        final original = (await repo.get('project'))!;
        await repo.save(
          original.edit(
            title: 'Project 10',
            actor: 'test-user',
            at: DateTime.now(),
            data: {
              'details': {'client': 'Northlight'},
            },
          ),
          baseRevision: 1,
        );
        for (final pair in [
          ('second', 'Project 2', false),
          ('archived', 'Project 1', true),
        ]) {
          final now = DateTime.now().toUtc();
          await repo.save(
            ProductionRecord(
              id: pair.$1,
              kind: EntityKind.project,
              organizationId: 'organization',
              projectId: pair.$1,
              parentId: 'organization',
              title: pair.$2,
              revision: 1,
              createdAt: now,
              updatedAt: now,
              createdBy: 'test-user',
              updatedBy: 'test-user',
              data: {
                'details': {
                  'archived': pair.$3,
                  'client': pair.$3 ? 'Elsewhere' : 'Northlight',
                },
              },
            ),
            baseRevision: 0,
          );
        }
      });
      final org = (await tester.runAsync<ProductionRecord?>(
        () => repo.get('organization'),
      ))!;
      final before = await tester.runAsync(() => repo.pendingCount());
      await tester.pumpWidget(
        MaterialApp(
          home: HierarchyScreen(repository: repo, parent: org),
        ),
      );
      await settleIo(tester);
      expect(find.text('Project 1'), findsNothing);
      await tester.tap(find.byTooltip('Sort items'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Name / number'));
      await tester.pumpAndSettle();
      final titles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((tile) => (tile.title as Text).data)
          .toList();
      expect(titles, ['Project 2', 'Project 10']);
      await tester.tap(find.byTooltip('Show archived projects'));
      await tester.pumpAndSettle();
      expect(find.text('Project 1'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Northlight');
      await tester.pumpAndSettle();
      expect(find.text('Project 1'), findsNothing);
      expect(find.text('Project 2'), findsOneWidget);
      expect(await tester.runAsync(() => repo.pendingCount()), before);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(repo.db.close);
    },
  );
  testWidgets(
    'locked recorded takes show a lock notice and disable technical edits',
    (tester) async {
      final repo = await prepare(tester);
      final take = (await tester.runAsync<ProductionRecord?>(() async {
        final source = (await repo.get('shot'))!;
        await repo.save(
          source.edit(
            actor: 'test-user',
            at: DateTime.now(),
            data: {
              'cameras': {
                'A Cam': {'iso': 800},
              },
            },
          ),
          baseRevision: source.revision,
        );
        final now = DateTime.now().toUtc();
        final value = ProductionRecord(
          id: 'take-locked',
          kind: EntityKind.take,
          organizationId: 'organization',
          projectId: 'project',
          parentId: 'shot',
          title: 'Take 1',
          revision: 1,
          createdAt: now,
          updatedAt: now,
          createdBy: 'test-user',
          updatedBy: 'test-user',
          data: {
            'details': {'status': 'recorded', 'locked': true},
          },
        );
        await repo.save(value, baseRevision: 0);
        return repo.get(value.id);
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          home: CameraEditor(repository: repo, record: take),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This take is locked. Unlock it in Production details to edit camera overrides.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Save locally'))
            .onPressed,
        isNull,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('A Cam:iso')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('A Cam:iso')))
            .enabled,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(repo.db.close);
    },
  );
  testWidgets('camera editor saves typed shot settings through UI', (
    tester,
  ) async {
    final repo = await prepare(tester);
    final shot = (await tester.runAsync<ProductionRecord?>(
      () => repo.get('shot'),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: CameraEditor(repository: repo, record: shot),
      ),
    );
    final modelField = find.byKey(const ValueKey('A Cam:model'));
    await tester.enterText(modelField, 'Cinema camera');
    await tester.tap(find.text('Save locally'));
    await settleIo(tester);
    final saved = (await tester.runAsync<ProductionRecord?>(
      () => repo.get('shot'),
    ))!;
    expect(
      readCameras(saved.data['cameras'])['A Cam']!['model'],
      'Cinema camera',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(repo.db.close);
  });
  testWidgets('canvas add, undo, redo and freehand persist structured data', (
    tester,
  ) async {
    final repo = await prepare(tester);
    final shot = (await tester.runAsync<ProductionRecord?>(
      () => repo.get('shot'),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: PlanEditor(repository: repo, shot: shot),
      ),
    );
    await tester.tap(find.text('camera'));
    await settleIo(tester);
    LightingPlan decode(ProductionRecord record) => LightingPlan.fromJson(
      Map<String, dynamic>.from(record.data['lighting_plan'] as Map),
    );
    expect(
      decode(
        (await tester.runAsync<ProductionRecord?>(() => repo.get('shot')))!,
      ).objects.single.symbol,
      SymbolKind.camera,
    );
    await tester.tap(find.byTooltip('Undo'));
    await settleIo(tester);
    expect(
      decode(
        (await tester.runAsync<ProductionRecord?>(() => repo.get('shot')))!,
      ).objects,
      isEmpty,
    );
    await tester.tap(find.byTooltip('Redo'));
    await settleIo(tester);
    await tester.tap(find.text('Freehand pen'));
    await tester.pumpAndSettle();
    final canvas = find.byWidgetPredicate(
      (widget) => widget is CustomPaint && widget.painter is LightingPainter,
    );
    final start = tester.getTopLeft(canvas) + const Offset(100, 100);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(30, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 20));
    await tester.pump();
    await gesture.up();
    await settleIo(tester);
    final restored = decode(
      (await tester.runAsync<ProductionRecord?>(() => repo.get('shot')))!,
    );
    expect(restored.objects.length, 1);
    expect(restored.strokes.length, 1);
    expect(restored.strokes.single.points.length, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(repo.db.close);
  });
}

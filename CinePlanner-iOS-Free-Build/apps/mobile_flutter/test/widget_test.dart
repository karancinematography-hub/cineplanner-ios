import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cineplanner/data/workspace_repository.dart';
import 'package:cineplanner/main.dart';
import 'package:cineplanner/domain/production.dart';
import 'package:cineplanner/features/light_plan_screen.dart';
import 'package:cineplanner/features/capture_recovery.dart';
import 'package:cineplanner/ui/cine_theme.dart';

void main() {
  testWidgets(
    'iPad Light Plan exposes Back navigation and handles a fresh capture recovery',
    (tester) async {
      sqfliteFfiInit();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 768);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final repo = (await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: WorkspaceRepository.schemaVersion,
            onCreate: WorkspaceRepository.migrate,
            singleInstance: false,
          ),
        );
        final repository = WorkspaceRepository(
          db,
          deviceId: 'ios-test',
          actorId: 'tester',
        );
        final time = DateTime.utc(2026, 11, 10);
        String? parent;
        for (final kind in EntityKind.values.take(3)) {
          await repository.save(
            ProductionRecord(
              id: kind.name,
              kind: kind,
              organizationId: 'organization',
              projectId: kind == EntityKind.organization ? null : 'project',
              parentId: parent,
              title: kind.name,
              revision: 1,
              createdAt: time,
              updatedAt: time,
              createdBy: 'tester',
              updatedBy: 'tester',
            ),
            baseRevision: 0,
          );
          parent = kind.name;
        }
        // On a non-Android host, startup must not invoke Android lost-data recovery.
        expect(await recoverPendingCapture(repository), isNull);
        return repository;
      }))!;
      addTearDown(() => tester.runAsync(repo.db.close));
      final day = (await tester.runAsync(() => repo.get('shootDay')))!;
      await tester.pumpWidget(
        MaterialApp(
          theme: CineTheme.data,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        LightPlanScreen(repository: repo, entry: day),
                  ),
                ),
                child: const Text('Open day'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open day'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      }
      await tester.pumpAndSettle();
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byTooltip('Add'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Open day'), findsOneWidget);
      expect(find.byType(LightPlanScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('organization creation persists and shows local status', (
    tester,
  ) async {
    sqfliteFfiInit();
    final db = (await tester.runAsync(
      () => databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: WorkspaceRepository.schemaVersion,
          onCreate: WorkspaceRepository.migrate,
        ),
      ),
    ))!;
    final repo = WorkspaceRepository(db, deviceId: 'test', actorId: 'tester');
    await tester.pumpWidget(CinePlanner(repository: repo));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add organization'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Northlight Films',
    );
    await tester.tap(find.text('Save locally'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('Northlight Films'), findsOneWidget);
    expect(
      (await tester.runAsync(() => repo.children(null)))!.single.title,
      'Northlight Films',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
  });
}

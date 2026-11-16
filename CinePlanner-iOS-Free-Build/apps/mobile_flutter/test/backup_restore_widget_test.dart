import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cineplanner/domain/cinepack.dart';
import 'package:cineplanner/domain/production.dart';
import 'package:cineplanner/data/workspace_repository.dart';
import 'package:cineplanner/features/backup_restore.dart';

void main() {
  testWidgets(
    'backup UI validates a selected file before an explicit atomic restore',
    (tester) async {
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
      final repo = WorkspaceRepository(
        db,
        deviceId: 'restore-test',
        actorId: 'tester',
      );
      final time = DateTime.utc(2026, 11, 10);
      final snapshot = CinepackSnapshot([
        ProductionRecord(
          id: 'org',
          kind: EntityKind.organization,
          organizationId: 'org',
          title: 'Crew',
          revision: 1,
          createdAt: time,
          updatedAt: time,
          createdBy: 'u',
          updatedBy: 'u',
        ),
        ProductionRecord(
          id: 'project',
          kind: EntityKind.project,
          organizationId: 'org',
          projectId: 'project',
          parentId: 'org',
          title: 'Recovered shoot',
          revision: 1,
          createdAt: time,
          updatedAt: time,
          createdBy: 'u',
          updatedBy: 'u',
        ),
      ], exportedAt: time);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => BackupRestoreScreen(
                      repository: repo,
                      chooseFile: () async => XFile.fromData(
                        snapshot.encode(),
                        name: 'recovery.cinepack',
                      ),
                    ),
                  ),
                ),
                child: const Text('Open restore'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open restore'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose .cinepack file'));
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        if (find.text('Restore locally').evaluate().isNotEmpty) break;
      }
      expect(find.text('Recovered shoot'), findsOneWidget);
      expect(await tester.runAsync(() => repo.pendingCount()), 0);
      await tester.tap(find.text('Restore locally'));
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        if (find.text('Open restore').evaluate().isNotEmpty) break;
      }
      expect(
        (await tester.runAsync<ProductionRecord?>(
          () => repo.get('project'),
        ))!.title,
        'Recovered shoot',
      );
      expect(await tester.runAsync(() => repo.pendingCount()), 2);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(repo.db.close);
    },
  );
}

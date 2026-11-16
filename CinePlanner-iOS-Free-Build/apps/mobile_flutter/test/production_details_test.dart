import 'package:flutter_test/flutter_test.dart';
import 'package:cineplanner/domain/production.dart';
import 'package:cineplanner/domain/production_details.dart';

void main() {
  test('explicit scene numbers sort before descriptive titles', () {
    final time = DateTime.utc(2026);
    ProductionRecord scene(String id, String title, String number) =>
        ProductionRecord(
          id: id,
          kind: EntityKind.scene,
          organizationId: 'org',
          projectId: 'project',
          parentId: 'day',
          title: title,
          revision: 1,
          createdAt: time,
          updatedAt: time,
          createdBy: 'u',
          updatedBy: 'u',
          data: {
            'details': {'number': number},
          },
        );
    final records = [scene('ten', 'Alley', '10'), scene('two', 'Window', '2')];
    expect(
      filterProductionRecords(records, sort: RecordSort.label).map((r) => r.id),
      ['two', 'ten'],
    );
  });
  test(
    'production call times resolve in the named timezone without relying on device timezone',
    () {
      expect(
        resolveProductionTime('2026-11-10', '09:30', 'Asia/Kolkata'),
        DateTime.utc(2026, 11, 10, 4),
      );
      expect(
        normalizeProductionDetails(EntityKind.shootDay, {
          'date': '2026-11-10',
          'call_time': '09:30',
          'timezone': 'Asia/Kolkata',
        })['call_at_utc'],
        '2026-11-10T04:00:00.000Z',
      );
    },
  );
  test('DST gaps and folds need an explicit valid resolution', () {
    expect(
      () => resolveProductionTime('2026-03-08', '02:30', 'America/New_York'),
      throwsFormatException,
    );
    expect(
      () => resolveProductionTime('2026-11-01', '01:30', 'America/New_York'),
      throwsFormatException,
    );
    expect(
      resolveProductionTime(
        '2026-11-01',
        '01:30',
        'America/New_York',
        offset: '-04:00',
      ),
      DateTime.utc(2026, 11, 1, 5, 30),
    );
    expect(
      resolveProductionTime(
        '2026-11-01',
        '01:30',
        'America/New_York',
        offset: '-05:00',
      ),
      DateTime.utc(2026, 11, 1, 6, 30),
    );
    expect(
      () => resolveProductionTime(
        '2026-11-01',
        '01:30',
        'America/New_York',
        offset: '+05:30',
      ),
      throwsFormatException,
    );
  });
  test(
    'invalid dates, field types, choices and incomplete call times are rejected',
    () {
      for (final data in <Map<String, Object?>>[
        {'date': '2026-02-29'},
        {'date': '2026-13-01'},
        {'call_time': '24:00'},
        {'call_time': '09:00'},
        {'timezone': 'Unknown/Place'},
        {'utc_offset': 'five'},
        {'wrong': 'field'},
      ]) {
        expect(
          () => normalizeProductionDetails(EntityKind.shootDay, data),
          throwsFormatException,
        );
      }
      expect(
        () => normalizeProductionDetails(EntityKind.project, {
          'default_fps': '24',
        }),
        throwsFormatException,
      );
      expect(
        () =>
            normalizeProductionDetails(EntityKind.project, {'default_fps': 0}),
        throwsFormatException,
      );
      expect(
        () => normalizeProductionDetails(EntityKind.project, {
          'privacy': 'public',
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'take logging creates one UTC timestamp, then keeps it on normalization',
    () {
      final time = DateTime.utc(2026, 11, 10, 12);
      final data = normalizeProductionDetails(EntityKind.take, {
        'status': 'recorded',
      }, now: time);
      expect(data['recorded_at_utc'], time.toIso8601String());
      expect(
        normalizeProductionDetails(
          EntityKind.take,
          data,
          now: time.add(const Duration(days: 1)),
        )['recorded_at_utc'],
        time.toIso8601String(),
      );
    },
  );
  test(
    'search/archive/natural-number sorting operate without changing records',
    () {
      final time = DateTime.utc(2026);
      ProductionRecord project(String id, String title, bool archived) =>
          ProductionRecord(
            id: id,
            kind: EntityKind.project,
            organizationId: 'org',
            projectId: id,
            parentId: 'org',
            title: title,
            revision: 1,
            createdAt: time,
            updatedAt: time,
            createdBy: 'u',
            updatedBy: 'u',
            data: {
              'details': {'archived': archived, 'client': 'Northlight'},
            },
          );
      final records = [
        project('ten', 'Project 10', false),
        project('two', 'Project 2', false),
        project('old', 'Project 1', true),
      ];
      expect(
        filterProductionRecords(
          records,
          sort: RecordSort.label,
        ).map((r) => r.id),
        ['two', 'ten'],
      );
      expect(
        filterProductionRecords(
          records,
          query: 'northlight',
          includeArchived: true,
        ).length,
        3,
      );
      expect(filterProductionRecords(records, query: 'unmatched'), isEmpty);
      expect(records.first.id, 'ten');
      final older = ProductionRecord.fromJson({
        ...records[0].toJson(),
        'created_at': DateTime.utc(2020).toIso8601String(),
      });
      final newer = ProductionRecord.fromJson({
        ...records[1].toJson(),
        'created_at': DateTime.utc(2025).toIso8601String(),
      });
      expect(filterProductionRecords([newer, older]).map((r) => r.id), [
        'ten',
        'two',
      ]);
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:cineplanner/domain/camera_settings.dart';
import 'package:cineplanner/domain/production.dart';

void main() {
  test('nested camera data cannot mutate records without a revision', () {
    final time = DateTime.utc(2026);
    final record = ProductionRecord(
      id: 'o',
      kind: EntityKind.organization,
      organizationId: 'o',
      title: 'Org',
      revision: 1,
      createdAt: time,
      updatedAt: time,
      createdBy: 'u',
      updatedBy: 'u',
      data: {
        'nested': {'iso': 800},
        'list': [1, 2],
      },
    );
    expect(
      () => (record.data['nested'] as Map)['iso'] = 1600,
      throwsUnsupportedError,
    );
    expect(() => (record.data['list'] as List).add(3), throwsUnsupportedError);
  });
  test(
    'overrides are sparse, explicit clears and revert preserve baseline',
    () {
      final baseline = {'iso': 800, 'focal_mm': 35, 'notes': 'daylight'};
      final patch = changedSettings(baseline, {'iso': 1000, 'focal_mm': 35});
      expect(patch, {'iso': 1000, 'notes': null});
      expect(effectiveSettings(baseline, patch), {
        'iso': 1000,
        'focal_mm': 35,
        'notes': null,
      });
      expect(changedSettings(baseline, baseline), isEmpty);
      expect(baseline['iso'], 800);
    },
  );
  test('reject invalid numeric ranges, types and unknown fields', () {
    for (final settings in <Map<String, Object?>>[
      {'iso': -1},
      {'fps': 0},
      {'shutter_angle': 361},
      {'focal_mm': double.nan},
      {'model': 12},
      {'unknown': 'x'},
      {'iso': '800'},
    ]) {
      expect(() => validateSettings(settings), throwsFormatException);
    }
  });
}

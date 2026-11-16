import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'production.dart';

enum DetailType { text, number, choice, flag, date, time, zone, utc }

class DetailField {
  final String key, label;
  final DetailType type;
  final List<String> options;
  final int maxLength;
  const DetailField(
    this.key,
    this.label, {
    this.type = DetailType.text,
    this.options = const [],
    this.maxLength = 200,
  });
}

const _notes = DetailField('notes', 'Notes', maxLength: 8000);
const _zone = DetailField(
  'timezone',
  'Production timezone (IANA)',
  type: DetailType.zone,
);
List<DetailField> detailsFields(EntityKind kind) => switch (kind) {
  EntityKind.organization => [
    const DetailField('contact', 'Production contact'),
    _notes,
  ],
  EntityKind.project => [
    const DetailField('production_type', 'Production type'),
    const DetailField('client', 'Client'),
    const DetailField('camera_format', 'Default camera format'),
    const DetailField(
      'default_fps',
      'Default frame rate (fps)',
      type: DetailType.number,
    ),
    _zone,
    const DetailField('locations', 'Locations', maxLength: 2000),
    const DetailField(
      'privacy',
      'Privacy classification',
      type: DetailType.choice,
      options: ['standard', 'confidential', 'restricted'],
    ),
    const DetailField('archived', 'Archived', type: DetailType.flag),
    _notes,
  ],
  EntityKind.shootDay => [
    const DetailField('date', 'Shoot date (YYYY-MM-DD)', type: DetailType.date),
    const DetailField('call_time', 'Call time (HH:mm)', type: DetailType.time),
    _zone,
    const DetailField('utc_offset', 'UTC offset if needed (±HH:mm)'),
    const DetailField('location', 'Location'),
    const DetailField('call_at_utc', 'Call time UTC', type: DetailType.utc),
    _notes,
  ],
  EntityKind.scene => [
    const DetailField('number', 'Scene number'),
    const DetailField(
      'int_ext',
      'Interior / exterior',
      type: DetailType.choice,
      options: ['INT', 'EXT', 'INT/EXT', 'OTHER'],
    ),
    const DetailField('setting', 'Setting / location'),
    const DetailField(
      'time_of_day',
      'Story time',
      type: DetailType.choice,
      options: ['DAY', 'NIGHT', 'DAWN', 'DUSK', 'OTHER'],
    ),
    const DetailField('description', 'Scene description', maxLength: 4000),
    _notes,
  ],
  EntityKind.shot => [
    const DetailField('number', 'Shot number'),
    const DetailField('description', 'Shot description', maxLength: 4000),
    const DetailField('framing', 'Framing / shot size'),
    const DetailField('movement', 'Camera movement'),
    _notes,
  ],
  EntityKind.take => [
    const DetailField('slate', 'Slate / take label'),
    const DetailField(
      'status',
      'Take status',
      type: DetailType.choice,
      options: ['planned', 'recorded', 'circled', 'rejected'],
    ),
    const DetailField(
      'duration_seconds',
      'Duration (seconds)',
      type: DetailType.number,
    ),
    const DetailField('sound_roll', 'Sound roll'),
    const DetailField('clip', 'Clip / file reference'),
    const DetailField('locked', 'Lock camera overrides', type: DetailType.flag),
    const DetailField('recorded_at_utc', 'Recorded UTC', type: DetailType.utc),
    _notes,
  ],
};

bool _zonesReady = false;
tz.Location productionZone(String name) {
  if (!_zonesReady) {
    tzdata.initializeTimeZones();
    _zonesReady = true;
  }
  try {
    return tz.getLocation(name);
  } catch (_) {
    throw const FormatException(
      'Enter a known IANA timezone, such as Asia/Kolkata or UTC.',
    );
  }
}

DateTime productionDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const FormatException('Use YYYY-MM-DD.');
  }
  final parts = value.split('-').map(int.parse).toList();
  final date = DateTime.utc(parts[0], parts[1], parts[2]);
  if (date.year < 1 ||
      date.year != parts[0] ||
      date.month != parts[1] ||
      date.day != parts[2]) {
    throw const FormatException('Enter a valid calendar date.');
  }
  return date;
}

DateTime resolveProductionTime(
  String date,
  String clock,
  String zone, {
  String? offset,
}) {
  final day = productionDate(date), location = productionZone(zone);
  if (!RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(clock)) {
    throw const FormatException('Use a valid 24-hour HH:mm time.');
  }
  final hm = clock.split(':').map(int.parse).toList();
  final wall = DateTime.utc(day.year, day.month, day.day, hm[0], hm[1]);
  int? wantedOffset;
  if (offset != null && offset.isNotEmpty) {
    if (!RegExp(r'^[+-](?:0\d|1[0-4]):[0-5]\d$').hasMatch(offset)) {
      throw const FormatException('Use a UTC offset such as +05:30 or -04:00.');
    }
    final parts = offset.substring(1).split(':').map(int.parse).toList();
    wantedOffset =
        (offset[0] == '-' ? -1 : 1) * (parts[0] * 60 + parts[1]) * 60000;
  }
  final candidates = <int>{};
  for (final delta
      in location.zones.map((z) => z.offset.inMilliseconds).toSet()) {
    if (wantedOffset != null && delta != wantedOffset) continue;
    final candidate = DateTime.fromMillisecondsSinceEpoch(
      wall.millisecondsSinceEpoch - delta,
      isUtc: true,
    );
    final local = tz.TZDateTime.from(candidate, location);
    if (local.year == day.year &&
        local.month == day.month &&
        local.day == day.day &&
        local.hour == hm[0] &&
        local.minute == hm[1] &&
        local.second == 0 &&
        local.millisecond == 0) {
      candidates.add(candidate.millisecondsSinceEpoch);
    }
  }
  if (candidates.isEmpty) {
    throw const FormatException(
      'This local time/offset does not exist in the selected timezone.',
    );
  }
  if (candidates.length > 1) {
    throw const FormatException(
      'This local time occurs twice. Enter the intended UTC offset.',
    );
  }
  return DateTime.fromMillisecondsSinceEpoch(candidates.single, isUtc: true);
}

Map<String, Object?> normalizeProductionDetails(
  EntityKind kind,
  Object? source, {
  DateTime? now,
}) {
  final raw = Map<String, Object?>.from(source as Map? ?? {}),
      result = <String, Object?>{};
  final fields = {for (final field in detailsFields(kind)) field.key: field};
  for (final entry in raw.entries) {
    final field = fields[entry.key];
    if (field == null) {
      throw FormatException('Unknown production detail: ${entry.key}');
    }
    final value = entry.value;
    if (value == null || value == '') continue;
    if (field.type == DetailType.flag) {
      if (value is! bool) throw FormatException('Invalid ${field.label}');
    } else if (field.type == DetailType.number) {
      if (value is! num ||
          !value.isFinite ||
          value < 0 ||
          (field.key == 'default_fps' && value <= 0)) {
        throw FormatException('Invalid ${field.label}');
      }
    } else {
      if (value is! String || value.length > field.maxLength) {
        throw FormatException('Invalid ${field.label}');
      }
      if (field.type == DetailType.choice && !field.options.contains(value)) {
        throw FormatException('Invalid ${field.label}');
      }
      if (field.type == DetailType.zone) productionZone(value);
      if (field.key == 'utc_offset' &&
          !RegExp(r'^[+-](?:0\d|1[0-4]):[0-5]\d$').hasMatch(value)) {
        throw const FormatException('Use a UTC offset such as +05:30.');
      }
      if (field.type == DetailType.date) productionDate(value);
      if (field.type == DetailType.time &&
          !RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(value)) {
        throw const FormatException('Use a valid 24-hour HH:mm time.');
      }
      if (field.type == DetailType.utc &&
          (!value.endsWith('Z') || DateTime.tryParse(value) == null)) {
        throw const FormatException(
          'Timestamps must be valid UTC values ending in Z.',
        );
      }
    }
    result[entry.key] = value;
  }
  if (kind == EntityKind.shootDay) {
    result.remove('call_at_utc');
    if (result.containsKey('call_time')) {
      if (!result.containsKey('date') || !result.containsKey('timezone')) {
        throw const FormatException(
          'A call time requires a shoot date and production timezone.',
        );
      }
      result['call_at_utc'] = resolveProductionTime(
        result['date'] as String,
        result['call_time'] as String,
        result['timezone'] as String,
        offset: result['utc_offset'] as String?,
      ).toIso8601String();
    }
  }
  if (kind == EntityKind.take &&
      {'recorded', 'circled', 'rejected'}.contains(result['status']) &&
      !result.containsKey('recorded_at_utc')) {
    result['recorded_at_utc'] = (now ?? DateTime.now())
        .toUtc()
        .toIso8601String();
  }
  return Map.unmodifiable(result);
}

Map<String, Object?> detailsFromForm(
  EntityKind kind,
  Map<String, Object?> values,
) {
  final result = Map<String, Object?>.from(values);
  for (final field in detailsFields(kind)) {
    final value = result[field.key];
    if (field.type == DetailType.number && value is String) {
      if (value.trim().isEmpty) {
        result.remove(field.key);
      } else {
        final number = num.tryParse(value.trim());
        if (number == null) {
          throw FormatException('Enter a number for ${field.label}.');
        }
        result[field.key] = number;
      }
    }
  }
  return normalizeProductionDetails(kind, result);
}

enum RecordSort { created, label, updated }

int compareProductionLabels(String a, String b) {
  final token = RegExp(r'\d+|\D+');
  final left = token
          .allMatches(a.toLowerCase())
          .map((m) => m.group(0)!)
          .toList(),
      right = token
          .allMatches(b.toLowerCase())
          .map((m) => m.group(0)!)
          .toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = left[i], y = right[i];
    var result = 0;
    if (RegExp(r'^\d+$').hasMatch(x) && RegExp(r'^\d+$').hasMatch(y)) {
      final nx = x.replaceFirst(RegExp(r'^0+'), ''),
          ny = y.replaceFirst(RegExp(r'^0+'), '');
      result = nx.length.compareTo(ny.length);
      if (result == 0) result = nx.compareTo(ny);
    } else {
      result = x.compareTo(y);
    }
    if (result != 0) return result;
  }
  return left.length.compareTo(right.length);
}

List<ProductionRecord> filterProductionRecords(
  Iterable<ProductionRecord> records, {
  String query = '',
  bool includeArchived = false,
  RecordSort sort = RecordSort.created,
}) {
  final search = query.trim().toLowerCase();
  final result = records.where((r) {
    final details = r.data['details'] as Map? ?? {};
    if (!includeArchived &&
        r.kind == EntityKind.project &&
        details['archived'] == true) {
      return false;
    }
    return search.isEmpty ||
        '${r.title} ${details.values.whereType<String>().join(' ')}'
            .toLowerCase()
            .contains(search);
  }).toList();
  result.sort((a, b) {
    final ad = a.data['details'] as Map? ?? {},
        bd = b.data['details'] as Map? ?? {};
    final order = sort == RecordSort.label
        ? compareProductionLabels(
            (ad['number'] ?? ad['slate'] ?? a.title) as String,
            (bd['number'] ?? bd['slate'] ?? b.title) as String,
          )
        : sort == RecordSort.updated
        ? b.updatedAt.compareTo(a.updatedAt)
        : a.createdAt.compareTo(b.createdAt);
    return order == 0 ? a.id.compareTo(b.id) : order;
  });
  return result;
}

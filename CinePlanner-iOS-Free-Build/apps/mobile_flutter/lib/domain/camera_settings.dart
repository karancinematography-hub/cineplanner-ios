/// Numeric fields have explicit canonical units; other fields are text.
class CameraField {
  final String key, label;
  final bool numeric;
  final double? min, max;
  const CameraField(
    this.key,
    this.label, {
    this.numeric = false,
    this.min,
    this.max,
  });
}

const cameraFields = [
  CameraField('manufacturer', 'Manufacturer'),
  CameraField('model', 'Camera model'),
  CameraField('sensor_mode', 'Sensor / recording mode'),
  CameraField('lens', 'Lens model'),
  CameraField('focal_mm', 'Focal length (mm)', numeric: true, min: 0.1),
  CameraField('t_stop', 'T-stop / aperture', numeric: true, min: 0.1),
  CameraField('fps', 'Frame rate (fps)', numeric: true, min: 0.01),
  CameraField(
    'shutter_angle',
    'Shutter angle (degrees)',
    numeric: true,
    min: 0.01,
    max: 360,
  ),
  CameraField(
    'shutter_seconds',
    'Shutter time (seconds)',
    numeric: true,
    min: 0.000001,
  ),
  CameraField('iso', 'ISO / EI', numeric: true, min: 1),
  CameraField(
    'kelvin',
    'White balance (K)',
    numeric: true,
    min: 1000,
    max: 50000,
  ),
  CameraField('tint', 'Tint', numeric: true),
  CameraField('filters', 'ND / other filters'),
  CameraField('focus_m', 'Focus distance (m)', numeric: true, min: 0),
  CameraField('height_m', 'Camera height (m)', numeric: true, min: 0),
  CameraField(
    'tilt_degrees',
    'Tilt (degrees)',
    numeric: true,
    min: -180,
    max: 180,
  ),
  CameraField('stabilization', 'Stabilization'),
  CameraField('format', 'Recording format'),
  CameraField('resolution', 'Resolution'),
  CameraField('media_card', 'Media card'),
  CameraField('profile_lut', 'Color profile / LUT reference'),
  CameraField('notes', 'Notes'),
];

Map<String, Object?> validateSettings(Map<String, Object?> values) {
  final result = <String, Object?>{};
  for (final entry in values.entries) {
    final matches = cameraFields.where((f) => f.key == entry.key);
    if (matches.isEmpty) {
      throw FormatException('Unknown camera field: ${entry.key}');
    }
    final field = matches.single;
    final value = entry.value;
    if (value == null) {
      result[entry.key] = null;
      continue;
    }
    if (field.numeric) {
      if (value is! num ||
          !value.isFinite ||
          (field.min != null && value < field.min!) ||
          (field.max != null && value > field.max!)) {
        throw FormatException('Invalid ${field.label}');
      }
    } else if (value is! String || value.length > 8000) {
      throw FormatException('Invalid ${field.label}');
    }
    result[entry.key] = value;
  }
  return Map.unmodifiable(result);
}

Map<String, Map<String, Object?>> readCameras(Object? source) {
  if (source == null) return {};
  final result = <String, Map<String, Object?>>{};
  for (final entry in (source as Map).entries) {
    final id = entry.key as String;
    if (id.trim().isEmpty || id.length > 80) {
      throw const FormatException('Invalid camera identifier');
    }
    result[id] = validateSettings(
      Map<String, Object?>.from(entry.value as Map),
    );
  }
  return Map.unmodifiable(result);
}

Map<String, Object?> effectiveSettings(
  Map<String, Object?> baseline,
  Map<String, Object?> overrides,
) => validateSettings({...baseline, ...overrides});

/// Sparse overrides; a null explicitly clears an inherited value.
Map<String, Object?> changedSettings(
  Map<String, Object?> baseline,
  Map<String, Object?> edited,
) {
  validateSettings(edited);
  return {
    for (final key in {...baseline.keys, ...edited.keys})
      if (baseline[key] != edited[key]) key: edited[key],
  };
}

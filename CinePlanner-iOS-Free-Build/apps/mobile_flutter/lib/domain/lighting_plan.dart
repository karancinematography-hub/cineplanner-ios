import 'dart:convert';
import 'dart:math';

enum SymbolKind {
  camera,
  ledPanel,
  fresnel,
  actor,
  table,
  arrow,
  text,
  softbox,
  flag,
  reflector,
  chair,
  wall,
  window,
  door,
  hmi,
  tungsten,
  diffusionFrame,
  stand,
  boom,
  powerControl,
  custom,
  line,
  polyline,
  rectangle,
  ellipse,
  lightCone,
  dimension,
}

/// All geometry uses metres; viewport zoom never changes this representation.
class PlanObject {
  final String id;
  final SymbolKind symbol;
  final double x, y, width, height, heading;
  final String label;
  final bool locked;
  final String model, modifier, notes;
  final double? kelvin, powerPercent, heightMetres;
  const PlanObject({
    required this.id,
    required this.symbol,
    required this.x,
    required this.y,
    this.width = 1,
    this.height = 1,
    this.heading = 0,
    this.label = '',
    this.locked = false,
    this.model = '',
    this.modifier = '',
    this.notes = '',
    this.kelvin,
    this.powerPercent,
    this.heightMetres,
  });
  PlanObject transformed({
    double? x,
    double? y,
    double? width,
    double? height,
    double? heading,
  }) {
    if (locked) throw StateError('Unlock object before transforming');
    final result = PlanObject(
      id: id,
      symbol: symbol,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      heading: heading ?? this.heading,
      label: label,
      locked: locked,
      model: model,
      modifier: modifier,
      notes: notes,
      kelvin: kelvin,
      powerPercent: powerPercent,
      heightMetres: heightMetres,
    );
    result.validate();
    return result;
  }

  String get displayLabel => symbol == SymbolKind.dimension
      ? '$label ${sqrt(width * width + height * height).toStringAsFixed(2)} m'
      : label;

  void validate() {
    if (label.length > 200 ||
        model.length > 200 ||
        modifier.length > 200 ||
        notes.length > 8000) {
      throw ArgumentError('Object text exceeds supported limits');
    }
    if ((kelvin != null &&
            (!kelvin!.isFinite || kelvin! < 1000 || kelvin! > 50000)) ||
        (powerPercent != null &&
            (!powerPercent!.isFinite ||
                powerPercent! < 0 ||
                powerPercent! > 100)) ||
        (heightMetres != null &&
            (!heightMetres!.isFinite || heightMetres! < 0))) {
      throw ArgumentError('Invalid fixture settings');
    }
    if (id.isEmpty ||
        ![x, y, width, height, heading].every((v) => v.isFinite) ||
        width <= 0 ||
        height <= 0) {
      throw ArgumentError('Invalid world geometry');
    }
    if ([x, y, width, height].any((v) => v.abs() > 1000000)) {
      throw ArgumentError(
        'World geometry exceeds the supported 1000 km workspace',
      );
    }
  }

  bool contains(Point<double> point, {double tolerance = 0.15}) {
    final angle = -(heading % 360) * pi / 180;
    final dx = point.x - (x + width / 2), dy = point.y - (y + height / 2);
    final localX = dx * cos(angle) - dy * sin(angle),
        localY = dx * sin(angle) + dy * cos(angle);
    return localX.abs() <= width / 2 + tolerance &&
        localY.abs() <= height / 2 + tolerance;
  }

  Point<double> get resizeHandle {
    final angle = (heading % 360) * pi / 180;
    return Point(
      x + width / 2 + width / 2 * cos(angle) - height / 2 * sin(angle),
      y + height / 2 + width / 2 * sin(angle) + height / 2 * cos(angle),
    );
  }

  PlanObject resizedTo(Point<double> pointer, {double? snap}) {
    final angle = (heading % 360) * pi / 180, c = cos(angle), s = sin(angle);
    final anchor = Point(
      x + width / 2 - width / 2 * c + height / 2 * s,
      y + height / 2 - width / 2 * s - height / 2 * c,
    );
    final dx = pointer.x - anchor.x, dy = pointer.y - anchor.y;
    var w = dx * c + dy * s, h = -dx * s + dy * c;
    if (snap != null) {
      w = (w / snap).round() * snap;
      h = (h / snap).round() * snap;
    }
    w = max(0.1, w);
    h = max(0.1, h);
    final cx = anchor.x + w / 2 * c - h / 2 * s,
        cy = anchor.y + w / 2 * s + h / 2 * c;
    return transformed(x: cx - w / 2, y: cy - h / 2, width: w, height: h);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'symbol': symbol.name,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'heading': heading,
    'label': label,
    'locked': locked,
    'model': model,
    'modifier': modifier,
    'notes': notes,
    'kelvin': kelvin,
    'power_percent': powerPercent,
    'height_m': heightMetres,
  };
  factory PlanObject.fromJson(Map<String, dynamic> j) {
    final value = PlanObject(
      id: j['id'] as String,
      symbol: SymbolKind.values.byName(j['symbol'] as String),
      x: (j['x'] as num).toDouble(),
      y: (j['y'] as num).toDouble(),
      width: (j['width'] as num).toDouble(),
      height: (j['height'] as num).toDouble(),
      heading: (j['heading'] as num).toDouble(),
      label: j['label'] as String,
      locked: j['locked'] as bool,
      model: j['model'] as String? ?? '',
      modifier: j['modifier'] as String? ?? '',
      notes: j['notes'] as String? ?? '',
      kelvin: (j['kelvin'] as num?)?.toDouble(),
      powerPercent: (j['power_percent'] as num?)?.toDouble(),
      heightMetres: (j['height_m'] as num?)?.toDouble(),
    );
    value.validate();
    return value;
  }
}

class DrawingStroke {
  final String id;
  final List<Point<double>> points;
  final double width;
  final int color;
  final String kind;
  DrawingStroke({
    required this.id,
    required Iterable<Point<double>> points,
    this.width = 0.04,
    this.color = 0xffffca70,
    this.kind = 'freehand',
  }) : points = List.unmodifiable(points) {
    if (id.isEmpty ||
        !{'freehand', 'polyline'}.contains(kind) ||
        this.points.length < 2 ||
        !width.isFinite ||
        width <= 0 ||
        this.points.any(
          (p) =>
              !p.x.isFinite ||
              !p.y.isFinite ||
              p.x.abs() > 1000000 ||
              p.y.abs() > 1000000,
        )) {
      throw ArgumentError('Invalid drawing stroke');
    }
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'points': points.map((p) => [p.x, p.y]).toList(),
    'width_m': width,
    'color': color,
    'kind': kind,
  };
  factory DrawingStroke.fromJson(Map<String, dynamic> j) => DrawingStroke(
    id: j['id'] as String,
    points: (j['points'] as List).map(
      (p) => Point((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ),
    width: (j['width_m'] as num).toDouble(),
    color: j['color'] as int,
    kind: j['kind'] as String? ?? 'freehand',
  );
}

class LightingPlan {
  final List<PlanObject> objects;
  final List<DrawingStroke> strokes;
  LightingPlan(
    Iterable<PlanObject> objects, {
    Iterable<DrawingStroke> strokes = const [],
  }) : objects = List.unmodifiable(objects),
       strokes = List.unmodifiable(strokes) {
    final ids = <String>{};
    for (final object in this.objects) {
      object.validate();
      if (!ids.add(object.id)) {
        throw ArgumentError('Duplicate canvas object ID');
      }
    }
    for (final stroke in this.strokes) {
      if (!ids.add(stroke.id)) {
        throw ArgumentError('Duplicate stroke/object ID');
      }
    }
  }
  LightingPlan withObjects(Iterable<PlanObject> objects) =>
      LightingPlan(objects, strokes: strokes);
  LightingPlan freshCopy(
    String Function() newId, {
    double dx = 0,
    double dy = 0,
  }) => LightingPlan(
    objects.map(
      (o) => PlanObject.fromJson({
        ...o.toJson(),
        'id': newId(),
        'x': o.x + dx,
        'y': o.y + dy,
      }),
    ),
    strokes: strokes.map(
      (s) => DrawingStroke(
        id: newId(),
        points: s.points.map((p) => Point(p.x + dx, p.y + dy)),
        width: s.width,
        color: s.color,
        kind: s.kind,
      ),
    ),
  );
  LightingPlan append(LightingPlan other) => LightingPlan(
    [...objects, ...other.objects],
    strokes: [...strokes, ...other.strokes],
  );
  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'units': 'metres',
    'objects': objects.map((o) => o.toJson()).toList(),
    'strokes': strokes.map((s) => s.toJson()).toList(),
  };
  factory LightingPlan.fromJson(Map<String, dynamic> j) {
    if (j['schema_version'] != 1 || j['units'] != 'metres') {
      throw const FormatException('Unsupported plan schema or units');
    }
    return LightingPlan(
      (j['objects'] as List).map(
        (o) => PlanObject.fromJson(Map<String, dynamic>.from(o as Map)),
      ),
      strokes: ((j['strokes'] as List?) ?? []).map(
        (s) => DrawingStroke.fromJson(Map<String, dynamic>.from(s as Map)),
      ),
    );
  }
  String encode() => jsonEncode(toJson());
}

class PlanBounds {
  final double left, top, right, bottom;
  const PlanBounds(this.left, this.top, this.right, this.bottom);
  double get width => right - left;
  double get height => bottom - top;
}

/// Conservative rotated-object and label bounds, shared by raster/vector export.
PlanBounds planBounds(LightingPlan plan) {
  var left = 0.0, top = 0.0, right = 10.0, bottom = 8.0;
  for (final object in plan.objects) {
    final radius =
        sqrt(object.width * object.width + object.height * object.height) / 2;
    final cx = object.x + object.width / 2, cy = object.y + object.height / 2;
    final margin = max(1.0, min(4.0, object.label.length * 0.06));
    left = min(left, cx - radius - margin);
    right = max(right, cx + radius + margin);
    top = min(top, cy - radius - margin);
    bottom = max(bottom, cy + radius + margin);
  }
  for (final stroke in plan.strokes) {
    for (final point in stroke.points) {
      left = min(left, point.x - 1);
      right = max(right, point.x + 1);
      top = min(top, point.y - 1);
      bottom = max(bottom, point.y + 1);
    }
  }
  return PlanBounds(left, top, right, bottom);
}

class PlanHistory {
  final List<LightingPlan> _undo = [], _redo = [];
  LightingPlan current;
  PlanHistory(this.current);
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  void commit(LightingPlan plan) {
    _undo.add(current);
    current = plan;
    _redo.clear();
  }

  void undo() {
    if (canUndo) {
      _redo.add(current);
      current = _undo.removeLast();
    }
  }

  void redo() {
    if (canRedo) {
      _undo.add(current);
      current = _redo.removeLast();
    }
  }
}

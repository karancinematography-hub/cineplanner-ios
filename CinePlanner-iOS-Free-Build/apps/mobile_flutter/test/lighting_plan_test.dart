import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:cineplanner/domain/lighting_plan.dart';

void main() {
  test(
    'fresh plan copies preserve settings, translate geometry and isolate all IDs',
    () {
      var sequence = 0;
      final plan = LightingPlan(
        [
          const PlanObject(
            id: 'old',
            symbol: SymbolKind.ledPanel,
            x: 2,
            y: 3,
            model: 'Panel',
            powerPercent: 40,
            locked: true,
          ),
        ],
        strokes: [
          DrawingStroke(
            id: 'stroke',
            kind: 'polyline',
            points: [const Point(1.0, 1.0), const Point(2.0, 2.0)],
          ),
        ],
      );
      final first = plan.freshCopy(() => 'new-${sequence++}', dx: 1, dy: -1);
      final second = plan.freshCopy(() => 'new-${sequence++}');
      expect(first.objects.single.x, 3);
      expect(first.objects.single.y, 2);
      expect(first.objects.single.locked, isTrue);
      expect(first.objects.single.powerPercent, 40);
      expect(first.strokes.single.points.first, const Point(2.0, 0.0));
      expect(first.strokes.single.kind, 'polyline');
      final combined = plan.append(first).append(second);
      expect(combined.objects.map((o) => o.id).toSet().length, 3);
      expect(combined.strokes.map((s) => s.id).toSet().length, 3);
      expect(plan.objects.single.x, 2);
    },
  );
  test(
    'rotated resizing preserves its opposite world corner and rejects locked edits',
    () {
      const object = PlanObject(
        id: 'resize',
        symbol: SymbolKind.table,
        x: 2,
        y: 3,
        width: 2,
        height: 1,
        heading: 90,
      );
      final resized = object.resizedTo(const Point(1.0, 6.5));
      expect(resized.width, closeTo(4, 0.0001));
      expect(resized.height, closeTo(2.5, 0.0001));
      expect(resized.resizeHandle.x, closeTo(1, 0.0001));
      expect(resized.resizeHandle.y, closeTo(6.5, 0.0001));
      expect(
        () => const PlanObject(
          id: 'locked',
          symbol: SymbolKind.wall,
          x: 0,
          y: 0,
          locked: true,
        ).resizedTo(const Point(4.0, 4.0)),
        throwsStateError,
      );
    },
  );
  test(
    'rotated hit testing uses the object frame and bounds cover exports',
    () {
      const wall = PlanObject(
        id: 'w',
        symbol: SymbolKind.wall,
        x: 0,
        y: 0,
        width: 4,
        height: 0.2,
        heading: 90,
      );
      expect(wall.contains(const Point(2.0, 1.9)), isTrue);
      expect(wall.contains(const Point(0.2, 0.1)), isFalse);
      final bounds = planBounds(LightingPlan([wall]));
      expect(bounds.left, lessThan(0));
      expect(bounds.bottom, greaterThan(2));
    },
  );
  test('polyline point order and kind survive persistence', () {
    final plan = LightingPlan(
      [],
      strokes: [
        DrawingStroke(
          id: 'p',
          kind: 'polyline',
          points: [
            const Point(0.0, 1.0),
            const Point(2.0, 3.0),
            const Point(4.0, 1.0),
          ],
        ),
      ],
    );
    final restored = LightingPlan.fromJson(jsonDecode(plan.encode()));
    expect(restored.strokes.single.kind, 'polyline');
    expect(restored.strokes.single.points[1], const Point(2.0, 3.0));
  });
  test('fixture metadata survives transformations and serialization', () {
    final fixture = const PlanObject(
      id: 'light',
      symbol: SymbolKind.ledPanel,
      x: 0,
      y: 0,
      model: 'Panel 600',
      kelvin: 5600,
      powerPercent: 45,
      heightMetres: 2.5,
      modifier: 'Grid',
      notes: 'Key light',
    ).transformed(x: 2);
    final restored = LightingPlan.fromJson(
      jsonDecode(LightingPlan([fixture]).encode()),
    ).objects.single;
    expect(restored.model, 'Panel 600');
    expect(restored.kelvin, 5600);
    expect(restored.powerPercent, 45);
    expect(restored.modifier, 'Grid');
    expect(restored.heightMetres, 2.5);
    expect(
      () => LightingPlan([
        const PlanObject(
          id: 'bad',
          symbol: SymbolKind.ledPanel,
          x: 0,
          y: 0,
          powerPercent: 101,
        ),
      ]),
      throwsArgumentError,
    );
  });
  test('freehand survives round trip, object transforms and undo', () {
    final stroke = DrawingStroke(
      id: 'stroke',
      points: [const Point(1.0, 2.0), const Point(3.0, 4.0)],
    );
    final plan = LightingPlan([], strokes: [stroke]);
    final restored = LightingPlan.fromJson(jsonDecode(plan.encode()));
    expect(restored.strokes.single.points.last, const Point(3.0, 4.0));
    expect(restored.withObjects([]).strokes.single.id, 'stroke');
    final history = PlanHistory(LightingPlan([]));
    history.commit(plan);
    history.undo();
    expect(history.current.strokes, isEmpty);
    history.redo();
    expect(history.current.strokes.length, 1);
  });
  const camera = PlanObject(
    id: 'cam',
    symbol: SymbolKind.camera,
    x: 1.25,
    y: 3.5,
  );
  test('geometry round trip and history preserve world coordinates', () {
    final original = LightingPlan([camera]);
    final history = PlanHistory(original);
    history.commit(LightingPlan([camera.transformed(x: 8.125, heading: 90)]));
    final restored = LightingPlan.fromJson(
      jsonDecode(history.current.encode()),
    );
    expect(restored.objects.single.x, 8.125);
    history.undo();
    expect(history.current.objects.single.x, 1.25);
    history.redo();
    expect(history.current.objects.single.heading, 90);
    history.undo();
    history.commit(LightingPlan([]));
    expect(history.canRedo, isFalse);
  });
  test('reject duplicates, nonfinite geometry and locked moves', () {
    expect(() => LightingPlan([camera, camera]), throwsArgumentError);
    expect(() => camera.transformed(x: double.nan), throwsArgumentError);
    expect(
      () => const PlanObject(
        id: 'l',
        symbol: SymbolKind.fresnel,
        x: 0,
        y: 0,
        locked: true,
      ).transformed(x: 2),
      throwsStateError,
    );
  });
}

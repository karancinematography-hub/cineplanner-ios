import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:cineplanner/domain/lighting_plan.dart';
import 'package:cineplanner/features/plan_svg.dart';

void main() {
  test(
    'SVG escapes labels, includes freehand and covers negative coordinates',
    () {
      final svg = exportPlanSvg(
        LightingPlan(
          [
            const PlanObject(
              id: 'c',
              symbol: SymbolKind.camera,
              x: -4,
              y: -2,
              heading: 45,
              label: '<script> & "camera"',
            ),
          ],
          strokes: [
            DrawingStroke(
              id: 's',
              points: [const Point(-8.0, -6.0), const Point(2.0, 1.0)],
            ),
          ],
        ),
      );
      expect(svg, contains('&lt;script&gt; &amp; &quot;camera&quot;'));
      expect(svg, isNot(contains('<script>')));
      expect(svg, contains('viewBox="-9.0 -7.0'));
      expect(svg, contains('<polyline'));
      expect(svg, contains('rotate(45.0)'));
    },
  );
}

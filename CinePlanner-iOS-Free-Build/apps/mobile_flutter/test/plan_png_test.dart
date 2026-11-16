import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:cineplanner/domain/lighting_plan.dart';
import 'package:cineplanner/features/plan_png.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'PNG export includes negative and distant world geometry within bounded pixels',
    () async {
      final plan = LightingPlan(
        [
          const PlanObject(
            id: 'negative',
            symbol: SymbolKind.camera,
            x: -5,
            y: -3,
            label: 'A Cam',
            heading: 45,
          ),
          const PlanObject(
            id: 'far',
            symbol: SymbolKind.lightCone,
            x: 35,
            y: 25,
            label: 'Key light',
          ),
        ],
        strokes: [
          DrawingStroke(
            id: 'path',
            points: [const Point(-6.0, -4.0), const Point(30.0, 20.0)],
          ),
        ],
      );
      final bytes = await exportPlanPng(plan);
      final decoded = img.decodePng(bytes)!;
      expect(decoded.width, lessThanOrEqualTo(2048));
      expect(decoded.height, lessThanOrEqualTo(2048));
      var nonBackground = 0;
      for (final pixel in decoded) {
        if (pixel.r != 20 || pixel.g != 23 || pixel.b != 25) nonBackground++;
      }
      expect(nonBackground, greaterThan(100));
      final file = File('build/verification/lighting-plan.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    },
  );
}

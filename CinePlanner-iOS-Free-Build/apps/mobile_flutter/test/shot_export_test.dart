import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:flutter_test/flutter_test.dart';
import 'package:cineplanner/domain/production.dart';
import 'package:cineplanner/domain/lighting_plan.dart';
import 'package:cineplanner/domain/frame_grab.dart';
import 'package:cineplanner/features/shot_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('offline PDFs render the saved shot and active take reports', () async {
    final shot = ProductionRecord(
      id: 'shot-test',
      kind: EntityKind.shot,
      organizationId: 'org-test',
      projectId: 'project-test',
      parentId: 'scene-12',
      title: '12B - Kitchen dawn',
      revision: 3,
      createdAt: DateTime.utc(2026, 11, 10),
      updatedAt: DateTime.utc(2026, 11, 10),
      createdBy: 'tester',
      updatedBy: 'tester',
      data: {
        'details': {
          'number': '12B',
          'framing': 'Medium close-up',
          'movement': 'Slow push-in',
          'notes': 'Hold the lighting continuity for the reverse angle.',
        },
        'frame_grabs': {
          '1': {'asset_id': 'grab-one', 'notes': 'Reference: soft daylight'},
          '2': {'asset_id': 'grab-two', 'notes': 'Alternate: warm interior'},
        },
        'cameras': {
          'A Cam': {
            'manufacturer': 'ARRI',
            'model': 'ALEXA Mini LF',
            'focal_mm': 35,
            't_stop': 2.8,
            'fps': 24,
            'iso': 800,
            'kelvin': 5600,
          },
        },
        'lighting_plan': LightingPlan([
          const PlanObject(
            id: 'cam',
            symbol: SymbolKind.camera,
            x: 3,
            y: 6,
            label: 'A Cam',
          ),
          const PlanObject(
            id: 'actor',
            symbol: SymbolKind.actor,
            x: 3,
            y: 3,
            label: 'Actor',
          ),
          const PlanObject(
            id: 'key',
            symbol: SymbolKind.ledPanel,
            x: 1,
            y: 2,
            label: 'Key',
            kelvin: 5600,
            powerPercent: 45,
            modifier: 'Softbox',
            notes: 'Soft daylight through window',
          ),
          const PlanObject(
            id: 'bounce',
            symbol: SymbolKind.reflector,
            x: 6,
            y: 3,
            label: 'Bounce',
          ),
        ]).toJson(),
      },
    );
    final grabs = <int, FrameGrab>{};
    for (final slot in [1, 2]) {
      final image = img.Image(width: 320, height: 180);
      img.fill(
        image,
        color: slot == 1
            ? img.ColorRgb8(65, 105, 150)
            : img.ColorRgb8(170, 110, 55),
      );
      img.fillRect(
        image,
        x1: 25,
        y1: 20,
        x2: 95,
        y2: 120,
        color: img.ColorRgb8(220, 230, 240),
      );
      img.fillRect(
        image,
        x1: 175,
        y1: 55,
        x2: 215,
        y2: 155,
        color: img.ColorRgb8(30, 40, 50),
      );
      final prepared = prepareFrame(Uint8List.fromList(img.encodePng(image)));
      grabs[slot] = FrameGrab(
        assetId: 'grab-$slot',
        shotId: shot.id,
        checksum: prepared.checksum,
        mime: prepared.mime,
        createdBy: 'test-operator',
        width: 320,
        height: 180,
        createdAt: DateTime.utc(2026, 11, 10),
        preview: prepared.preview,
      );
    }
    final bytes = await exportShotPdf(shot, grabs: grabs);
    expect(ascii.decode(bytes.take(4).toList()), '%PDF');
    expect(bytes.length, greaterThan(10000));
    final output = File('build/verification/shot-report.pdf');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes);

    final take = ProductionRecord.fromJson({
      ...shot.toJson(),
      'kind': 'take',
      'id': 'take-test',
      'parent_id': shot.id,
      'title': '03',
      'data': {
        'lighting_plan': shot.data['lighting_plan'],
        'frame_grabs': {'2': (shot.data['frame_grabs'] as Map)['2']},
        'details': {'notes': 'Keep this take-specific note.'},
      },
    });
    final takeBytes = await exportShotPdf(
      take,
      grabs: {2: grabs[2]},
      takeLabels: (scene: 'Scene alias', shot: '12B', take: '03'),
    );
    expect(ascii.decode(takeBytes.take(4).toList()), '%PDF');
    await File(
      'build/verification/light-plan-take.pdf',
    ).writeAsBytes(takeBytes);
    expect(
      RegExp(r'/Subtype\s*/Image\b').allMatches(latin1.decode(takeBytes)),
      hasLength(1),
    );
  });
}

import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../domain/lighting_plan.dart';
import 'plan_editor.dart';

/// Render the complete plan, including negative/off-viewport geometry. The
/// longest side is bounded to 2048 pixels independently of editor zoom.
Future<Uint8List> exportPlanPng(LightingPlan plan) async {
  final bounds = planBounds(plan);
  final scale = math.min(120.0, 2048 / math.max(bounds.width, bounds.height));
  final width = math.max(1, (bounds.width * scale).ceil()),
      height = math.max(1, (bounds.height * scale).ceil());
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xff141719), BlendMode.src);
  canvas.scale(scale / 60);
  canvas.translate(-bounds.left * 60, -bounds.top * 60);
  LightingPainter(
    plan,
    null,
    showGrid: false,
  ).paint(canvas, Size(bounds.width * 60, bounds.height * 60));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

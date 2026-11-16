import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../domain/camera_settings.dart';
import '../domain/lighting_plan.dart';
import '../domain/production.dart';
import '../data/workspace_repository.dart';
import '../domain/frame_grab.dart';
import '../domain/production_details.dart';
import 'plan_svg.dart';
import 'local_share.dart';

Future<Uint8List> exportShotPdf(
  ProductionRecord shot, {
  Map<int, FrameGrab?> grabs = const {},
  ({String scene, String shot, String take})? takeLabels,
}) async {
  final regular = pw.Font.ttf(
    await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
  );
  final bold = pw.Font.ttf(
    await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'),
  );
  final document = pw.Document(
    title: takeLabels == null
        ? '${shot.title} - shot report'
        : 'Light Plan - Take ${takeLabels.take}',
    author: 'CinePlanner',
    theme: pw.ThemeData.withFont(base: regular, bold: bold),
  );
  final plan = shot.data['lighting_plan'] == null
      ? LightingPlan([])
      : LightingPlan.fromJson(
          Map<String, dynamic>.from(shot.data['lighting_plan'] as Map),
        );
  final cameras = readCameras(shot.data['cameras']);
  final details = normalizeProductionDetails(
    shot.kind,
    shot.data['details'],
    now: shot.updatedAt,
  );
  pw.Widget section(String title) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 18, bottom: 8),
    child: pw.Text(
      title,
      style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
    ),
  );
  document.addPage(
    pw.MultiPage(
      maxPages: 500,
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      footer: (context) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'Local draft - revision ${shot.revision}',
            style: const pw.TextStyle(fontSize: 8),
          ),
          pw.Text(
            '${context.pageNumber} / ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8),
          ),
        ],
      ),
      build: (context) => [
        pw.Text(
          takeLabels == null ? shot.title : 'Light Plan',
          style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 8),
        pw.Text(
          takeLabels == null
              ? 'Shot ID: ${shot.id}\nScene ID: ${shot.parentId}\nProject ID: ${shot.projectId}'
              : 'Scene ${takeLabels.scene}   Shot ${takeLabels.shot}   Take ${takeLabels.take}',
          style: const pw.TextStyle(fontSize: 9),
        ),
        pw.SizedBox(height: 6),
        pw.Text(
          'Revision ${shot.revision} | Updated ${shot.updatedAt.toUtc().toIso8601String()} | Not submitted for approval',
          style: const pw.TextStyle(fontSize: 9),
        ),
        if (details.isNotEmpty) ...[
          section(takeLabels == null ? 'Shot details' : 'Take details'),
          for (final field in detailsFields(shot.kind))
            if (details[field.key] != null) ...[
              pw.Text(
                '${field.label}: ${details[field.key]}',
                style: const pw.TextStyle(fontSize: 9),
              ),
              pw.SizedBox(height: 6),
            ],
        ],
        section('Overhead lighting plan'),
        pw.Container(
          height: 290,
          child: pw.SvgImage(
            svg: exportPlanSvg(plan),
            fit: pw.BoxFit.contain,
            customFontLookup: (_, _, _) => regular,
          ),
        ),
        pw.Text(
          'World coordinates: metres. Symbols describe a plan; no photometric simulation. Not a printed scale drawing.',
          style: const pw.TextStyle(fontSize: 8),
        ),
        section('Camera settings'),
        if (cameras.isEmpty) pw.Text('No camera settings recorded.'),
        for (final entry in cameras.entries) ...[
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 8),
            child: pw.Text(
              entry.key,
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.TableHelper.fromTextArray(
            headers: ['Field', 'Shot default'],
            data: [
              for (final field in cameraFields)
                if (entry.value[field.key] != null)
                  [field.label, entry.value[field.key].toString()],
            ],
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerStyle: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
            ),
            cellAlignment: pw.Alignment.centerLeft,
          ),
        ],
        pw.NewPage(freeSpace: 120),
        section('Lighting fixtures and objects'),
        if (plan.objects.isEmpty) pw.Text('No objects recorded.'),
        for (final object in plan.objects)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 8),
            child: pw.Text(
              '${object.label} (${object.symbol.name})\nPosition ${object.x}, ${object.y} m | Heading ${object.heading} deg'
              '${object.model.isEmpty ? '' : ' | ${object.model}'}${object.kelvin == null ? '' : ' | ${object.kelvin} K'}'
              '${object.powerPercent == null ? '' : ' | ${object.powerPercent}%'}${object.heightMetres == null ? '' : ' | Height ${object.heightMetres} m'}'
              '${object.modifier.isEmpty ? '' : '\nModifier: ${object.modifier}'}${object.notes.isEmpty ? '' : '\n${object.notes}'}',
              style: const pw.TextStyle(fontSize: 9),
            ),
          ),
        pw.NewPage(freeSpace: 230),
        section('Frame grabs - compressed previews'),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            for (final slot in [1, 2])
              pw.Expanded(
                child: pw.Padding(
                  padding: const pw.EdgeInsets.all(6),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'GRAB $slot',
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                      ),
                      pw.SizedBox(height: 8),
                      if (grabs[slot] != null) ...[
                        pw.Container(
                          height: 130,
                          child: pw.Image(
                            pw.MemoryImage(grabs[slot]!.preview),
                            fit: pw.BoxFit.contain,
                          ),
                        ),
                        pw.Text(
                          '${grabs[slot]!.width} x ${grabs[slot]!.height} | ${grabs[slot]!.createdAt.toUtc().toIso8601String()}',
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                        pw.Text(
                          'By ${grabs[slot]!.createdBy} | Local only',
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                      ] else
                        pw.Text(
                          (shot.data['frame_grabs'] as Map?)?['$slot'] == null
                              ? 'No frame grab attached.'
                              : 'Media unavailable offline; not included.',
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                      pw.Text(
                        ((shot.data['frame_grabs'] as Map?)?['$slot']
                                    as Map?)?['notes']
                                as String? ??
                            '',
                        style: const pw.TextStyle(fontSize: 8),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );
  return document.save();
}

/// Explicit user export creates an unencrypted file for platform sharing.
/// Other cache data stays encrypted; stale export copies are cleaned on export.
Future<void> shareShotExport(
  ProductionRecord shot, {
  required bool pdf,
  WorkspaceRepository? repository,
}) async {
  final grabs = <int, FrameGrab?>{};
  if (pdf && repository != null) {
    for (final slot in [1, 2]) {
      final ref = (shot.data['frame_grabs'] as Map?)?['$slot'] as Map?;
      if (ref != null) {
        grabs[slot] = await repository.framePreview(
          shot.id,
          ref['asset_id'] as String,
        );
      }
    }
  }
  final plan = shot.data['lighting_plan'] == null
      ? LightingPlan([])
      : LightingPlan.fromJson(
          Map<String, dynamic>.from(shot.data['lighting_plan'] as Map),
        );
  final bytes = pdf
      ? await exportShotPdf(shot, grabs: grabs)
      : utf8.encode(exportPlanSvg(plan));
  await shareExportBytes(
    bytes,
    extension: pdf ? 'pdf' : 'svg',
    mime: pdf ? 'application/pdf' : 'image/svg+xml',
    subject: '${shot.title} - ${pdf ? 'shot report' : 'lighting plan'}',
  );
}

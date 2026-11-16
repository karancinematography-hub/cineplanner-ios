import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../data/workspace_repository.dart';
import '../domain/frame_grab.dart';
import '../domain/production.dart';

Future<ProductionRecord> finishCapture(
  WorkspaceRepository repository,
  XFile file, {
  bool acceptCurrentRevision = false,
}) async {
  final pending = await repository.pendingCapture();
  if (pending == null) throw StateError('No camera destination recorded');
  await repository.stageCapturePath(file.path);
  if (await file.length() > 25 * 1024 * 1024) {
    throw const FormatException('Image exceeds 25 MB.');
  }
  final frame = await compute(prepareFrame, await file.readAsBytes());
  final takeId = pending['destination_take_id'] as String?;
  final target = acceptCurrentRevision
      ? await repository.get(takeId ?? pending['shot_id'] as String)
      : null;
  final saved = await repository.attachFrame(
    shotId: pending['shot_id'] as String,
    slot: pending['slot'] as int,
    assetId: pending['asset_id'] as String,
    frame: frame,
    destinationTakeId: takeId,
    expectedRevision: acceptCurrentRevision
        ? target!.revision
        : pending['base_revision'] as int,
  );
  // Only clean a camera-owned temporary file after durable commit. Never delete
  // a gallery original or a path outside the app's private cache.
  try {
    final cache = p.normalize((await getTemporaryDirectory()).absolute.path);
    final source = p.normalize(File(file.path).absolute.path);
    if (p.isWithin(cache, source)) {
      await File(source).delete();
    }
  } catch (_) {
    /* Cleanup failure must not misreport an acknowledged save. */
  }
  return saved;
}

Future<String?> recoverPendingCapture(
  WorkspaceRepository repository, {
  bool acceptCurrentRevision = false,
}) async {
  try {
    final lost = Platform.isAndroid
        ? await ImagePicker().retrieveLostData()
        : null;
    final pending = await repository.pendingCapture();
    if (pending == null) {
      return lost == null || lost.isEmpty
          ? null
          : 'A recovered camera image has no saved shot destination. Its temporary file was preserved.';
    }
    final files = lost?.files;
    final path = pending['source_path'] as String?;
    if (files != null && files.isNotEmpty) {
      await finishCapture(
        repository,
        files.first,
        acceptCurrentRevision: acceptCurrentRevision,
      );
      return 'Recovered frame grab saved locally.';
    }
    if (path != null && await File(path).exists()) {
      await finishCapture(
        repository,
        XFile(path),
        acceptCurrentRevision: acceptCurrentRevision,
      );
      return 'Recovered frame grab saved locally.';
    }
    return pending['destination_take_id'] == null
        ? 'A camera capture needs attention. Open its shot’s Frame grabs to recover or dismiss it.'
        : 'A camera capture needs attention. Open its take in Light Plan to recover or dismiss it.';
  } catch (_) {
    return 'A camera image could not be recovered automatically. Its pending destination and available files were preserved.';
  }
}

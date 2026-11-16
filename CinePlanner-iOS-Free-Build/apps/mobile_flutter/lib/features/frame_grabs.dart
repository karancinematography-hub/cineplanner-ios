import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../ui/cine_theme.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../data/workspace_repository.dart';
import '../domain/frame_grab.dart';
import '../domain/production.dart';
import 'capture_recovery.dart';
import 'local_share.dart';

class FrameGrabsScreen extends StatefulWidget {
  final WorkspaceRepository repository;
  final ProductionRecord shot;
  final Future<fs.XFile?> Function()? chooseFile;
  const FrameGrabsScreen({
    super.key,
    required this.repository,
    required this.shot,
    this.chooseFile,
  });
  @override
  State<FrameGrabsScreen> createState() => _FrameGrabsScreenState();
}

class _FrameGrabsScreenState extends State<FrameGrabsScreen> {
  late ProductionRecord shot;
  final grabs = <int, FrameGrab?>{};
  bool busy = true;
  String? error;
  Map<String, Object?>? pending;
  Map<String, dynamic> get slots =>
      Map<String, dynamic>.from(shot.data['frame_grabs'] as Map? ?? {});
  @override
  void initState() {
    super.initState();
    shot = widget.shot;
    reload();
  }

  Future<void> reload() async {
    try {
      shot = (await widget.repository.get(shot.id))!;
      for (final slot in [1, 2]) {
        final ref = slots['$slot'] as Map?;
        grabs[slot] = ref == null
            ? null
            : await widget.repository.framePreview(
                shot.id,
                ref['asset_id'] as String,
              );
      }
      pending = await widget.repository.pendingCapture();
    } catch (_) {
      error = 'Could not read frame data. Existing files have been preserved.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> import(int slot) async {
    setState(() => busy = true);
    try {
      final file =
          await (widget.chooseFile?.call() ??
              fs.openFile(
                acceptedTypeGroups: [
                  const fs.XTypeGroup(
                    label: 'Frame grab',
                    extensions: ['jpg', 'jpeg', 'png'],
                    uniformTypeIdentifiers: ['public.jpeg', 'public.png'],
                  ),
                ],
              ));
      if (file == null) return;
      if (await file.length() > 25 * 1024 * 1024) {
        throw const FormatException('Use a JPEG or PNG smaller than 25 MB.');
      }
      final frame = await compute(prepareFrame, await file.readAsBytes());
      shot = await widget.repository.attachFrame(
        shotId: shot.id,
        slot: slot,
        assetId: const Uuid().v4(),
        frame: frame,
        expectedRevision: shot.revision,
      );
      error = null;
      await reload();
    } catch (failure) {
      error = failure is FormatException
          ? failure.message
          : 'Could not save the frame grab. The source image and previous grab are unchanged.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> capture(int slot) async {
    setState(() => busy = true);
    try {
      await widget.repository.startCapture(
        shot.id,
        slot,
        const Uuid().v4(),
        shot.revision,
      );
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        requestFullMetadata: false,
      );
      if (file == null) {
        await widget.repository.clearCapture();
        return;
      }
      await finishCapture(widget.repository, file);
      error = null;
      await reload();
    } catch (_) {
      error =
          'Capture was not saved. Any pending image is preserved for recovery.';
      await reload();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> swap() async {
    setState(() => busy = true);
    try {
      final values = slots;
      final changed = {'1': values['2'], '2': values['1']}
        ..removeWhere((key, value) => value == null);
      final updated = shot.edit(
        actor: widget.repository.actorId,
        at: DateTime.now(),
        data: {...shot.data, 'frame_grabs': changed},
      );
      await widget.repository.save(updated, baseRevision: shot.revision);
      error = null;
      await reload();
    } catch (_) {
      error = 'Could not swap. Reopen to check the current shot revision.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> details(int slot) async {
    final ref = Map<String, dynamic>.from(slots['$slot'] as Map);
    final notes = TextEditingController(text: ref['notes'] as String? ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('GRAB $slot notes'),
        content: TextField(controller: notes, maxLength: 4000, maxLines: 4),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, notes.text),
            child: const Text('Save locally'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    setState(() => busy = true);
    try {
      final values = slots;
      values['$slot'] = {...ref, 'notes': result};
      await widget.repository.save(
        shot.edit(
          actor: widget.repository.actorId,
          at: DateTime.now(),
          data: {...shot.data, 'frame_grabs': values},
        ),
        baseRevision: shot.revision,
      );
      await reload();
    } catch (_) {
      error = 'Notes could not be saved. Reopen and retry.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> original(int slot) async {
    setState(() => busy = true);
    try {
      final grab = grabs[slot]!;
      final bytes = await widget.repository.originalFrame(
        shot.id,
        grab.assetId,
      );
      if (bytes == null) throw StateError('Original unavailable');
      await shareExportBytes(
        bytes,
        extension: grab.mime == 'image/png' ? 'png' : 'jpg',
        mime: grab.mime,
        subject: '${shot.title} - GRAB $slot original',
      );
    } catch (_) {
      error =
          'Original is unavailable or failed its checksum. No local data was deleted.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> recovery(bool dismiss) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          dismiss
              ? 'Dismiss pending capture?'
              : 'Recover into GRAB ${pending?['slot']}?',
        ),
        content: Text(
          dismiss
              ? 'The recovery destination will be cleared. Existing grabs and the available source file will not be deleted.'
              : 'This will use the current shot revision and replace that comparison slot. The previous original remains stored locally.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(dismiss ? 'Dismiss' : 'Recover'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => busy = true);
    try {
      if (dismiss) {
        await widget.repository.clearCapture();
        error = null;
      } else {
        error = await recoverPendingCapture(
          widget.repository,
          acceptCurrentRevision: true,
        );
      }
      await reload();
    } catch (_) {
      error =
          'Recovery destination could not be updated. Existing media was preserved.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text('${shot.title} · Frame grabs'),
        actions: [
          IconButton(
            tooltip: 'Swap grabs',
            onPressed: busy || slots.isEmpty ? null : swap,
            icon: const Icon(Icons.swap_horiz),
          ),
        ],
      ),
      body: CinePage(
        child: ListView(
          padding: const EdgeInsets.all(CineTheme.gutter),
          children: [
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (pending?['shot_id'] == shot.id &&
                pending?['destination_take_id'] == null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      const Text(
                        'A pending camera capture needs recovery. Existing grabs remain saved.',
                      ),
                      TextButton(
                        onPressed: busy ? null : () => recovery(false),
                        child: const Text('Recover pending capture'),
                      ),
                      TextButton(
                        onPressed: busy ? null : () => recovery(true),
                        child: const Text('Dismiss pending capture'),
                      ),
                    ],
                  ),
                ),
              ),
            const Text(
              'Compressed previews below. Original bytes remain on this device. Local only.',
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final children = [
                  for (final slot in [1, 2])
                    SizedBox(
                      width: constraints.maxWidth >= CineTheme.compactWidth
                          ? (constraints.maxWidth - CineTheme.gutter) / 2
                          : constraints.maxWidth,
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'GRAB $slot',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              AspectRatio(
                                aspectRatio: 16 / 9,
                                child: grabs[slot] == null
                                    ? Center(
                                        child: Text(
                                          slots['$slot'] == null
                                              ? 'No frame grab'
                                              : 'Media unavailable in this workspace',
                                        ),
                                      )
                                    : InteractiveViewer(
                                        minScale: 1,
                                        maxScale: 5,
                                        child: Image.memory(
                                          grabs[slot]!.preview,
                                          fit: BoxFit.contain,
                                          gaplessPlayback: true,
                                        ),
                                      ),
                              ),
                              if (grabs[slot] != null) ...[
                                Text(
                                  '${grabs[slot]!.width} × ${grabs[slot]!.height} • Local only',
                                ),
                                Text(
                                  'By ${grabs[slot]!.createdBy}\n${grabs[slot]!.createdAt.toLocal()}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                Text(
                                  (slots['$slot'] as Map?)?['notes']
                                          as String? ??
                                      '',
                                ),
                                TextButton(
                                  onPressed: busy ? null : () => details(slot),
                                  child: const Text('Edit notes'),
                                ),
                                TextButton(
                                  onPressed: busy ? null : () => original(slot),
                                  child: const Text('Export original'),
                                ),
                              ],
                              Wrap(
                                spacing: 8,
                                children: [
                                  OutlinedButton(
                                    onPressed: busy ? null : () => import(slot),
                                    child: Text('Import GRAB $slot'),
                                  ),
                                  OutlinedButton(
                                    onPressed: busy || pending != null
                                        ? null
                                        : () => capture(slot),
                                    child: Text('Capture GRAB $slot'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ];
                return Wrap(spacing: 16, runSpacing: 16, children: children);
              },
            ),
          ],
        ),
      ),
    ),
  );
}

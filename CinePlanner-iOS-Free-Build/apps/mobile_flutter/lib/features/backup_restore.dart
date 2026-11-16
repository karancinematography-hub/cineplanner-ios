import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../ui/cine_theme.dart';
import '../data/workspace_repository.dart';
import '../domain/cinepack.dart';
import '../domain/production.dart';

class BackupRestoreScreen extends StatefulWidget {
  final WorkspaceRepository repository;
  final Future<XFile?> Function()? chooseFile;
  const BackupRestoreScreen({
    super.key,
    required this.repository,
    this.chooseFile,
  });
  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  CinepackSnapshot? snapshot;
  RestorePreview? preview;
  String? error, filename;
  bool busy = false;
  final alternatives = <String, String>{};
  Future<void> pick() async {
    setState(() => busy = true);
    try {
      final file =
          await (widget.chooseFile?.call() ??
              openFile(
                acceptedTypeGroups: [
                  const XTypeGroup(
                    label: 'CinePlanner backup',
                    extensions: ['cinepack', 'zip'],
                    uniformTypeIdentifiers: ['public.data'],
                  ),
                ],
              ));
      if (file == null) return;
      if (await file.length() > 64 * 1024 * 1024) {
        throw const FormatException(
          'Backup exceeds the 64 MB metadata import limit.',
        );
      }
      final decoded = await compute(
        CinepackSnapshot.decode,
        await file.readAsBytes(),
      );
      final result = await widget.repository.previewRestore(decoded);
      final labels = <String, String>{};
      for (final id in result.conflictingIds) {
        final local = await widget.repository.get(id);
        final incoming = decoded.records.singleWhere((r) => r.id == id);
        labels[id] =
            'Local: ${local!.title} (r${local.revision})\nArchive: ${incoming.title} (r${incoming.revision})';
      }
      if (mounted) {
        setState(() {
          snapshot = decoded;
          preview = result;
          filename = file.name;
          error = null;
          alternatives
            ..clear()
            ..addAll(labels);
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          snapshot = null;
          preview = null;
          error = failure is FormatException
              ? failure.message
              : 'Backup could not be validated. No records were changed.';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> restore() async {
    if (snapshot == null || !(preview?.canRestore ?? false)) return;
    setState(() => busy = true);
    try {
      final result = await widget.repository.restoreSnapshot(snapshot!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Restored ${result.newRecords} records locally.'),
          ),
        );
        setState(() => busy = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, true);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Restore could not commit. Existing data is preserved. Revalidate the archive to check for new conflicts.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Restore project backup')),
      body: CinePage(
        maxWidth: 760,
        child: ListView(
          padding: const EdgeInsets.all(CineTheme.wideGutter),
          children: [
            Text(
              'Validate before restoring',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text(
              'This version restores metadata snapshots only. Media originals, previews, approvals and full operation history are not included.',
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: busy ? null : pick,
                icon: const Icon(Icons.folder_open),
                label: Text(busy ? 'Working…' : 'Choose .cinepack file'),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (snapshot != null && preview != null) ...[
              const SizedBox(height: 20),
              Text(
                filename ?? 'Selected backup',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                snapshot!.records
                    .singleWhere((r) => r.kind == EntityKind.project)
                    .title,
              ),
              Text('Exported ${snapshot!.exportedAt.toLocal()}'),
              Text(
                '${preview!.newRecords} new • ${preview!.identicalRecords} identical • ${preview!.conflictingIds.length} conflicts',
              ),
              const SizedBox(height: 12),
              if (!preview!.canRestore) ...[
                const Text(
                  'Conflicting IDs must be resolved before import. Local records and the original archive remain unchanged.',
                ),
                for (final entry in alternatives.entries)
                  ListTile(title: Text(entry.key), subtitle: Text(entry.value)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed:
                    busy || !preview!.canRestore || preview!.newRecords == 0
                    ? null
                    : restore,
                child: const Text('Restore locally'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

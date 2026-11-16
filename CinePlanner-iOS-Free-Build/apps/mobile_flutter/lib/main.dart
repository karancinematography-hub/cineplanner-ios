import 'package:flutter/material.dart';
import 'ui/cine_theme.dart';
import 'package:uuid/uuid.dart';
import 'data/encrypted_workspace.dart';
import 'data/workspace_repository.dart';
import 'domain/production.dart';
import 'features/plan_editor.dart';
import 'features/light_plan_screen.dart';
import 'features/camera_editor.dart';
import 'features/shot_export.dart';
import 'features/local_share.dart';
import 'features/backup_restore.dart';
import 'features/frame_grabs.dart';
import 'features/capture_recovery.dart';
import 'features/plan_png.dart';
import 'features/production_details_editor.dart';
import 'domain/lighting_plan.dart';
import 'domain/production_details.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final repository = await openEncryptedWorkspace();
    final notice = await recoverPendingCapture(repository);
    runApp(CinePlanner(repository: repository, startupNotice: notice));
  } catch (_) {
    runApp(
      MaterialApp(
        theme: CineTheme.data,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'The encrypted workspace could not be opened. Existing files have been preserved. Check device storage and key access before restoring a backup.',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CinePlanner extends StatelessWidget {
  final WorkspaceRepository repository;
  final String? startupNotice;
  const CinePlanner({super.key, required this.repository, this.startupNotice});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CinePlanner',
    debugShowCheckedModeBanner: false,
    theme: CineTheme.data,
    home: HierarchyScreen(repository: repository, startupNotice: startupNotice),
  );
}

class HierarchyScreen extends StatefulWidget {
  final WorkspaceRepository repository;
  final ProductionRecord? parent;
  final String? startupNotice;
  const HierarchyScreen({
    super.key,
    required this.repository,
    this.parent,
    this.startupNotice,
  });
  @override
  State<HierarchyScreen> createState() => _HierarchyScreenState();
}

class _HierarchyScreenState extends State<HierarchyScreen> {
  late Future<List<ProductionRecord>> records;
  int pending = 0;
  String query = '';
  bool includeArchived = false;
  RecordSort sort = RecordSort.created;
  EntityKind get kind =>
      EntityKind.values[(widget.parent?.kind.index ?? -1) + 1];
  @override
  void initState() {
    super.initState();
    reload();
    if (widget.startupNotice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(widget.startupNotice!)));
        }
      });
    }
  }

  void reload() {
    records = widget.repository.children(widget.parent?.id);
    widget.repository.pendingCount().then((count) {
      if (mounted) setState(() => pending = count);
    });
  }

  Future<void> edit([ProductionRecord? current]) async {
    final controller = TextEditingController(text: current?.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${current == null ? 'Create' : 'Rename'} ${kind.label}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save locally'),
          ),
        ],
      ),
    );
    // Dialog route owns the text field until its exit animation completes.
    if (title == null || title.trim().isEmpty) return;
    final now = DateTime.now().toUtc();
    final id = const Uuid().v4();
    final parent = widget.parent;
    final record =
        current?.edit(
          title: title.trim(),
          actor: widget.repository.actorId,
          at: now,
        ) ??
        ProductionRecord(
          id: id,
          kind: kind,
          organizationId: parent?.organizationId ?? id,
          projectId: kind == EntityKind.project ? id : parent?.projectId,
          parentId: parent?.id,
          title: title.trim(),
          revision: 1,
          createdAt: now,
          updatedAt: now,
          createdBy: widget.repository.actorId,
          updatedBy: widget.repository.actorId,
        );
    await save(record, current?.revision ?? 0);
  }

  Future<void> save(ProductionRecord record, int base) async {
    try {
      await widget.repository.save(record, baseRevision: base);
      if (mounted) {
        setState(reload);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Saved locally')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save: $error')));
      }
    }
  }

  Future<void> openLightPlan(ProductionRecord entry) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            LightPlanScreen(repository: widget.repository, entry: entry),
      ),
    );
    if (mounted) setState(reload);
  }

  Future<void> browseChildren(ProductionRecord entry) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            HierarchyScreen(repository: widget.repository, parent: entry),
      ),
    );
    if (mounted) setState(reload);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.parent?.title ?? 'CinePlanner',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actionsPadding: const EdgeInsets.only(right: 12),
      actions: [
        if (kind.index <= EntityKind.shootDay.index)
          if (MediaQuery.sizeOf(context).width >= CineTheme.compactWidth)
            FilledButton.icon(
              onPressed: () => edit(),
              icon: const Icon(Icons.add),
              label: Text('Add ${kind.label}'),
            )
          else
            IconButton(
              tooltip: 'Add ${kind.label}',
              icon: const Icon(Icons.add),
              onPressed: () => edit(),
            ),
        if (widget.parent != null &&
            widget.parent!.kind.index >= EntityKind.shootDay.index)
          TextButton(
            onPressed: () => openLightPlan(widget.parent!),
            child: const Text('Light Plan'),
          ),
        if (widget.parent == null)
          IconButton(
            tooltip: 'Restore project backup',
            icon: const Icon(Icons.restore),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute<bool>(
                  builder: (_) =>
                      BackupRestoreScreen(repository: widget.repository),
                ),
              );
              if (mounted) {
                setState(reload);
              }
            },
          ),
      ],
    ),
    body: CinePage(
      child: LayoutBuilder(
        builder: (context, bounds) {
          final gutter = bounds.maxWidth >= CineTheme.tabletWidth
              ? CineTheme.wideGutter
              : CineTheme.gutter;
          return Column(
            children: [
              browserToolbar(gutter, showStatus: bounds.maxHeight >= 250),
              Expanded(child: recordList(gutter)),
            ],
          );
        },
      ),
    ),
  );

  Widget browserToolbar(double gutter, {required bool showStatus}) => Padding(
    padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showStatus) ...[
          Text(
            '${kind.label.toUpperCase()} RECORDS  ·  LOCAL WORKSPACE  ·  $pending local operations',
            style: Theme.of(context).textTheme.labelMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                  labelText: 'Search names and production details',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => query = value),
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<RecordSort>(
              tooltip: 'Sort items',
              icon: const Icon(Icons.sort),
              onSelected: (value) => setState(() => sort = value),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: RecordSort.created,
                  child: Text('Created order'),
                ),
                PopupMenuItem(
                  value: RecordSort.label,
                  child: Text('Name / number'),
                ),
                PopupMenuItem(
                  value: RecordSort.updated,
                  child: Text('Recently updated'),
                ),
              ],
            ),
            if (kind == EntityKind.project)
              IconButton(
                tooltip: includeArchived
                    ? 'Hide archived projects'
                    : 'Show archived projects',
                isSelected: includeArchived,
                onPressed: () =>
                    setState(() => includeArchived = !includeArchived),
                icon: const Icon(Icons.archive_outlined),
              ),
          ],
        ),
      ],
    ),
  );

  Widget recordList(double gutter) => FutureBuilder<List<ProductionRecord>>(
    future: records,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const Center(
          child: Text('Unable to read workspace. Data has been preserved.'),
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final items = filterProductionRecords(
        snapshot.data!,
        query: query,
        includeArchived: includeArchived,
        sort: sort,
      );
      if (items.isEmpty && snapshot.data!.isNotEmpty) {
        return const Center(
          child: Text('No matching items. Check search and archive filters.'),
        );
      }
      if (items.isEmpty) {
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 16, 28, 64),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.movie_creation_outlined, size: 64),
                const SizedBox(height: 20),
                Text(
                  'Plan the next frame',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  kind.index > EntityKind.shootDay.index
                      ? 'Open Light Plan and use Add to create a ${kind.label}.'
                      : 'Create a ${kind.label} to begin.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Changes stay on this device.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      }
      return ListView.separated(
        padding: EdgeInsets.fromLTRB(gutter, 0, gutter, gutter),
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return Card(
            child: ListTile(
              leading: Icon(
                item.kind == EntityKind.project
                    ? Icons.folder_outlined
                    : Icons.movie_outlined,
              ),
              contentPadding: EdgeInsets.symmetric(horizontal: gutter),
              title: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${item.kind.label} • revision ${item.revision} • Local only${(item.data['details'] as Map?)?['archived'] == true ? ' • Archived' : ''}',
              ),
              onTap:
                  item.kind == EntityKind.take ||
                      item.kind == EntityKind.shootDay
                  ? () => openLightPlan(item)
                  : () => browseChildren(item),
              trailing: PopupMenuButton<String>(
                onSelected: (action) async {
                  if (action == 'backup') {
                    try {
                      final snapshot = await widget.repository.projectSnapshot(
                        item.id,
                      );
                      await shareExportBytes(
                        snapshot.encode(),
                        extension: 'cinepack',
                        mime: 'application/zip',
                        subject:
                            '${item.title} - metadata-only project backup (no media)',
                      );
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Backup could not be shared. Your local project is unchanged.',
                            ),
                          ),
                        );
                      }
                    }
                  } else if (action == 'browse-scenes') {
                    await browseChildren(item);
                  } else if (action == 'light-plan') {
                    await openLightPlan(item);
                  } else if (action == 'png') {
                    try {
                      final plan = item.data['lighting_plan'] == null
                          ? LightingPlan([])
                          : LightingPlan.fromJson(
                              Map<String, dynamic>.from(
                                item.data['lighting_plan'] as Map,
                              ),
                            );
                      await shareExportBytes(
                        await exportPlanPng(plan),
                        extension: 'png',
                        mime: 'image/png',
                        subject: '${item.title} - lighting plan',
                      );
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Lighting PNG could not be exported. Your plan is unchanged.',
                            ),
                          ),
                        );
                      }
                    }
                  } else if (action == 'pdf' || action == 'svg') {
                    try {
                      await shareShotExport(
                        item,
                        pdf: action == 'pdf',
                        repository: widget.repository,
                      );
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Export could not be shared. Your project remains saved locally.',
                            ),
                          ),
                        );
                      }
                    }
                  } else if (action == 'frames') {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => FrameGrabsScreen(
                          repository: widget.repository,
                          shot: item,
                        ),
                      ),
                    );
                    if (mounted) {
                      setState(reload);
                    }
                  } else if (action == 'camera') {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => CameraEditor(
                          repository: widget.repository,
                          record: item,
                        ),
                      ),
                    );
                    if (mounted) {
                      setState(reload);
                    }
                  } else if (action == 'plan') {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => PlanEditor(
                          repository: widget.repository,
                          shot: item,
                        ),
                      ),
                    );
                    if (mounted) {
                      setState(reload);
                    }
                  } else if (action == 'details') {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ProductionDetailsEditor(
                          repository: widget.repository,
                          record: item,
                        ),
                      ),
                    );
                    if (mounted) {
                      setState(reload);
                    }
                  } else if (action == 'rename') {
                    edit(item);
                  } else {
                    save(
                      item.edit(
                        actor: widget.repository.actorId,
                        at: DateTime.now(),
                        delete: true,
                      ),
                      item.revision,
                    );
                  }
                },
                itemBuilder: (_) => [
                  if (item.kind == EntityKind.shootDay)
                    const PopupMenuItem(
                      value: 'browse-scenes',
                      child: Text('Browse scenes'),
                    ),
                  if (item.kind.index >= EntityKind.shootDay.index)
                    const PopupMenuItem(
                      value: 'light-plan',
                      child: Text('Open Light Plan'),
                    ),
                  const PopupMenuItem(
                    value: 'details',
                    child: Text('Production details'),
                  ),
                  if (item.kind == EntityKind.project)
                    const PopupMenuItem(
                      value: 'backup',
                      child: Text('Export backup (metadata only)'),
                    ),
                  if (item.kind == EntityKind.shot) ...[
                    const PopupMenuItem(
                      value: 'png',
                      child: Text('Export lighting PNG'),
                    ),
                    const PopupMenuItem(
                      value: 'frames',
                      child: Text('Frame grabs / compare'),
                    ),
                    const PopupMenuItem(
                      value: 'pdf',
                      child: Text('Export shot PDF'),
                    ),
                    const PopupMenuItem(
                      value: 'svg',
                      child: Text('Export lighting SVG'),
                    ),
                  ],
                  if (item.kind == EntityKind.shot ||
                      item.kind == EntityKind.take)
                    const PopupMenuItem(
                      value: 'camera',
                      child: Text('Camera settings'),
                    ),
                  if (item.kind == EntityKind.shot)
                    const PopupMenuItem(
                      value: 'plan',
                      child: Text('Lighting plan'),
                    ),
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete empty item'),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

import 'package:flutter/material.dart';
import '../ui/cine_theme.dart';
import '../data/workspace_repository.dart';
import '../domain/camera_settings.dart';
import '../domain/production.dart';
import '../domain/production_details.dart';

class CameraEditor extends StatefulWidget {
  final WorkspaceRepository repository;
  final ProductionRecord record;
  const CameraEditor({
    super.key,
    required this.repository,
    required this.record,
  });
  @override
  State<CameraEditor> createState() => _CameraEditorState();
}

class _CameraEditorState extends State<CameraEditor> {
  late ProductionRecord record;
  late Map<String, Map<String, Object?>> baseline, values;
  final controllers = <String, TextEditingController>{};
  final form = GlobalKey<FormState>();
  String camera = 'A Cam';
  bool saving = false, dirty = false;
  String? error;
  bool get take => record.kind == EntityKind.take;
  bool get locked =>
      take &&
      normalizeProductionDetails(
            record.kind,
            record.data['details'],
            now: record.updatedAt,
          )['locked'] ==
          true;
  @override
  void initState() {
    super.initState();
    record = widget.record;
    baseline = readCameras(
      take ? record.data['camera_baseline'] : record.data['cameras'],
    );
    final overrides = readCameras(record.data['camera_overrides']);
    values = {
      for (final entry in baseline.entries)
        entry.key: take
            ? effectiveSettings(entry.value, overrides[entry.key] ?? {})
            : Map.of(entry.value),
    };
    if (values.isEmpty && !take) values['A Cam'] = {};
    if (values.isNotEmpty) camera = values.keys.first;
    for (final field in cameraFields) {
      controllers[field.key] = TextEditingController();
    }
    loadFields();
  }

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void loadFields() {
    for (final field in cameraFields) {
      controllers[field.key]!.text =
          values[camera]?[field.key]?.toString() ?? '';
    }
  }

  bool captureFields() {
    if (!form.currentState!.validate()) return false;
    values[camera] = {
      for (final field in cameraFields)
        if (controllers[field.key]!.text.trim().isNotEmpty)
          field.key: field.numeric
              ? num.parse(controllers[field.key]!.text.trim())
              : controllers[field.key]!.text.trim(),
    };
    return true;
  }

  Future<void> addCamera() async {
    if (!captureFields()) return;
    final controller = TextEditingController();
    final id = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add camera unit'),
        content: TextField(
          controller: controller,
          maxLength: 80,
          decoration: const InputDecoration(hintText: 'B Cam'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (id == null || id.isEmpty || !mounted) return;
    if (values.containsKey(id)) {
      setState(() => error = 'This camera already exists.');
      return;
    }
    setState(() {
      values[id] = {};
      camera = id;
      dirty = true;
      loadFields();
    });
  }

  Future<void> save() async {
    if (!captureFields()) return;
    setState(() => saving = true);
    try {
      final updated = record.edit(
        actor: widget.repository.actorId,
        at: DateTime.now(),
        data: {
          ...record.data,
          if (take)
            'camera_overrides': {
              for (final entry in values.entries)
                entry.key: changedSettings(
                  baseline[entry.key] ?? {},
                  entry.value,
                ),
            }
          else
            'cameras': values,
        },
      );
      await widget.repository.save(updated, baseRevision: record.revision);
      if (mounted) {
        setState(() {
          record = updated;
          dirty = false;
          error = null;
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Saved locally')));
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not save. Your entries remain here. Reopen after resolving a stale revision.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving && !dirty,
    onPopInvokedWithResult: (didPop, result) async {
      if (didPop || saving || !dirty) return;
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard unsaved settings?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep editing'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard == true && mounted) {
        setState(() => dirty = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text('${record.title} · Camera'),
        actions: [
          TextButton(
            onPressed: saving || values.isEmpty || locked ? null : save,
            child: Text(saving ? 'Saving…' : 'Save locally'),
          ),
        ],
      ),
      body: CinePage(
        child: values.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'This take has no camera baseline. Configure cameras on the shot before creating the next take.',
                  ),
                ),
              )
            : Form(
                key: form,
                child: ListView(
                  padding: const EdgeInsets.all(CineTheme.gutter),
                  children: [
                    if (locked)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'This take is locked. Unlock it in Production details to edit camera overrides.',
                        ),
                      ),
                    if (take)
                      Text(
                        'Historical shot baseline · revision ${record.data['baseline_shot_revision']}',
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: camera,
                            items: values.keys
                                .map(
                                  (id) => DropdownMenuItem(
                                    value: id,
                                    child: Text(id),
                                  ),
                                )
                                .toList(),
                            onChanged: saving
                                ? null
                                : (id) {
                                    if (id != null && captureFields()) {
                                      setState(() {
                                        camera = id;
                                        loadFields();
                                      });
                                    }
                                  },
                          ),
                        ),
                        if (!take)
                          IconButton(
                            tooltip: 'Add camera',
                            onPressed: saving ? null : addCamera,
                            icon: const Icon(Icons.add),
                          ),
                      ],
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    CineFields(
                      fields: [
                        for (final field in cameraFields)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: TextFormField(
                              key: ValueKey('$camera:${field.key}'),
                              controller: controllers[field.key],
                              enabled: !saving && !locked,
                              keyboardType: field.numeric
                                  ? const TextInputType.numberWithOptions(
                                      decimal: true,
                                      signed: true,
                                    )
                                  : TextInputType.text,
                              onChanged: (_) {
                                setState(() => dirty = true);
                              },
                              validator: (text) {
                                if (text == null || text.trim().isEmpty) {
                                  return null;
                                }
                                try {
                                  validateSettings({
                                    field.key: field.numeric
                                        ? num.parse(text.trim())
                                        : text.trim(),
                                  });
                                  return null;
                                } catch (_) {
                                  return 'Enter a valid ${field.label.toLowerCase()}';
                                }
                              },
                              decoration: InputDecoration(
                                labelText: field.label,
                                helperText: take
                                    ? (controllers[field.key]!.text ==
                                              (baseline[camera]?[field.key]
                                                      ?.toString() ??
                                                  '')
                                          ? 'Inherited from historical baseline'
                                          : 'Take override')
                                    : null,
                                suffixIcon: take
                                    ? IconButton(
                                        tooltip:
                                            'Revert to historical shot default',
                                        onPressed: saving || locked
                                            ? null
                                            : () {
                                                setState(() {
                                                  controllers[field.key]!.text =
                                                      baseline[camera]?[field
                                                              .key]
                                                          ?.toString() ??
                                                      '';
                                                  dirty = true;
                                                });
                                              },
                                        icon: const Icon(Icons.restore),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    ),
  );
}

import 'package:flutter/material.dart';
import '../ui/cine_theme.dart';
import '../data/workspace_repository.dart';
import '../domain/production.dart';
import '../domain/production_details.dart';

class ProductionDetailsEditor extends StatefulWidget {
  final WorkspaceRepository repository;
  final ProductionRecord record;
  const ProductionDetailsEditor({
    super.key,
    required this.repository,
    required this.record,
  });
  @override
  State<ProductionDetailsEditor> createState() =>
      _ProductionDetailsEditorState();
}

class _ProductionDetailsEditorState extends State<ProductionDetailsEditor> {
  late ProductionRecord record;
  final values = <String, Object?>{};
  final form = GlobalKey<FormState>();
  bool loading = true, saving = false, dirty = false, ready = false;
  String? error;
  @override
  void initState() {
    super.initState();
    record = widget.record;
    load();
  }

  Future<void> load() async {
    try {
      final latest = await widget.repository.get(record.id);
      if (latest == null || latest.deletedAt != null) {
        throw StateError('Record unavailable');
      }
      record = latest;
      values.addAll(
        normalizeProductionDetails(
          record.kind,
          record.data['details'],
          now: record.updatedAt,
        ),
      );
      if (record.kind == EntityKind.project) {
        values.putIfAbsent('timezone', () => 'UTC');
      }
      if (record.kind == EntityKind.shootDay &&
          !values.containsKey('timezone')) {
        final project = await widget.repository.get(record.projectId!);
        values['timezone'] =
            (project?.data['details'] as Map?)?['timezone'] ?? 'UTC';
      }
      ready = true;
    } catch (_) {
      error =
          'Production details could not be opened. Existing data is unchanged.';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> save() async {
    if (!ready) return;
    if (!form.currentState!.validate()) return;
    setState(() => saving = true);
    try {
      final details = detailsFromForm(record.kind, values);
      final updated = record.edit(
        actor: widget.repository.actorId,
        at: DateTime.now(),
        data: {...record.data, 'details': details},
      );
      await widget.repository.save(updated, baseRevision: record.revision);
      final saved = (await widget.repository.get(record.id))!;
      if (mounted) {
        setState(() {
          record = saved;
          values
            ..clear()
            ..addAll(saved.data['details'] as Map<String, Object?>);
          dirty = false;
          error = null;
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Production details saved locally')),
        );
      }
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = failure is FormatException
              ? failure.message
              : 'Could not save. Your entries remain here; reopen if another edit changed the revision.',
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
          title: const Text('Discard unsaved details?'),
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
        title: Text('${record.title} · Production details'),
        actions: [
          TextButton(
            onPressed: loading || saving || !ready ? null : save,
            child: Text(saving ? 'Saving…' : 'Save locally'),
          ),
        ],
      ),
      body: CinePage(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : !ready
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(error ?? 'Production details are unavailable.'),
                ),
              )
            : Form(
                key: form,
                child: ListView(
                  padding: const EdgeInsets.all(CineTheme.gutter),
                  children: [
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    CineFields(
                      fields: [
                        for (final field in detailsFields(record.kind))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: field.type == DetailType.flag
                                ? SwitchListTile(
                                    title: Text(field.label),
                                    value: values[field.key] as bool? ?? false,
                                    onChanged: saving
                                        ? null
                                        : (value) => setState(() {
                                            values[field.key] = value;
                                            dirty = true;
                                          }),
                                  )
                                : field.type == DetailType.choice
                                ? DropdownButtonFormField<String>(
                                    key: ValueKey(field.key),
                                    initialValue: values[field.key] as String?,
                                    decoration: InputDecoration(
                                      labelText: field.label,
                                    ),
                                    items: [
                                      const DropdownMenuItem(
                                        value: '',
                                        child: Text('Not set'),
                                      ),
                                      for (final option in field.options)
                                        DropdownMenuItem(
                                          value: option,
                                          child: Text(option),
                                        ),
                                    ],
                                    onChanged: saving
                                        ? null
                                        : (value) => setState(() {
                                            values[field.key] = value;
                                            dirty = true;
                                          }),
                                  )
                                : TextFormField(
                                    key: ValueKey(
                                      '${record.revision}:${field.key}',
                                    ),
                                    initialValue:
                                        values[field.key]?.toString() ?? '',
                                    readOnly: field.type == DetailType.utc,
                                    enabled: !saving,
                                    maxLines: field.maxLength > 200 ? 3 : 1,
                                    keyboardType:
                                        field.type == DetailType.number
                                        ? const TextInputType.numberWithOptions(
                                            decimal: true,
                                          )
                                        : TextInputType.text,
                                    decoration: InputDecoration(
                                      labelText: field.label,
                                      helperText: field.type == DetailType.utc
                                          ? 'Calculated when saved; stored in UTC.'
                                          : field.key == 'timezone'
                                          ? 'Examples: Asia/Kolkata, Europe/London, UTC'
                                          : null,
                                    ),
                                    onChanged: (value) {
                                      values[field.key] = value;
                                      if (!dirty) setState(() => dirty = true);
                                    },
                                    validator: (value) =>
                                        value != null &&
                                            value.length > field.maxLength
                                        ? 'Use at most ${field.maxLength} characters'
                                        : null,
                                  ),
                          ),
                      ],
                    ),
                    if (record.kind == EntityKind.project)
                      const Text(
                        'Defaults apply to newly created shots. Existing shots and historical takes retain their settings. Archiving is an organization aid, not an access revocation.',
                      ),
                    if (record.kind == EntityKind.shootDay)
                      const Text(
                        'Call time is a local wall-clock value in the production timezone. For a repeated daylight-saving time, specify the intended UTC offset.',
                      ),
                  ],
                ),
              ),
      ),
    ),
  );
}

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import '../data/workspace_repository.dart';
import '../domain/light_plan.dart';
import '../domain/production.dart';
import '../ui/cine_theme.dart';
import 'light_plan_labels.dart';

const lightLevels = [EntityKind.scene, EntityKind.shot, EntityKind.take];
const lightLevelNames = ['Scene', 'Shot', 'Take'];

String lightLevelName(EntityKind kind) =>
    lightLevelNames[lightLevels.indexOf(kind)];

Future<List<ProductionRecord>> lightChildren(
  WorkspaceRepository repository,
  String parentId,
) async => (await repository.children(parentId))..sort(compareLightRecords);

class LightGoToDialog extends StatefulWidget {
  final WorkspaceRepository repository;
  final String dayId;
  final ValueChanged<ProductionRecord> onNumberChanged;

  const LightGoToDialog({
    super.key,
    required this.repository,
    required this.dayId,
    required this.onNumberChanged,
  });

  @override
  State<LightGoToDialog> createState() => _LightGoToDialogState();
}

class _LightGoToDialogState extends State<LightGoToDialog> {
  final path = <ProductionRecord>[];
  int level = 0;
  late Future<List<ProductionRecord>> choices = load();
  ProductionRecord? get target =>
      path.isEmpty ? null : path[math.min(level, path.length - 1)];

  Future<List<ProductionRecord>> load() => lightChildren(
    widget.repository,
    level == 0 ? widget.dayId : path[level - 1].id,
  );

  void select(ProductionRecord record) => setState(() {
    path
      ..removeRange(level, path.length)
      ..add(record);
    if (level < lightLevels.length - 1) {
      level++;
      choices = load();
    }
  });

  Future<void> editNumber(ProductionRecord record) async {
    final name = lightLevelName(record.kind);
    final existing = lightRecordNumber(record);
    ProductionRecord? updated;
    final result = await showLightNumbers(
      context,
      title: existing == null ? 'Set $name number' : 'Edit $name number',
      fields: {'$name number': existing ?? ''},
      action: 'Save number',
      save: (values) async {
        updated = await widget.repository.setLightNumber(record, values.single);
        widget.onNumberChanged(updated!);
      },
    );
    if (result == null || !mounted) return;
    final index = path.indexWhere((item) => item.id == record.id);
    setState(() {
      if (index != -1) path[index] = updated!;
      choices = load();
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Go to'),
    content: SizedBox(
      width: 520,
      height: math.min(
        385,
        math.max(116, MediaQuery.sizeOf(context).height - 200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < lightLevels.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        i < path.length && lightRecordNumber(path[i]) != null
                            ? '${lightLevelNames[i]} ${lightRecordNumber(path[i])}'
                            : lightLevelNames[i],
                      ),
                      selected: level == i,
                      onSelected: i > path.length
                          ? null
                          : (_) => setState(() {
                              level = i;
                              choices = load();
                            }),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: FutureBuilder(
              future: choices,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final records = snapshot.data;
                if (records == null) {
                  return const Center(child: Text('Could not load records.'));
                }
                if (records.isEmpty) {
                  return Center(
                    child: Text('No ${lightLevels[level].label}s here yet.'),
                  );
                }
                return ListView.builder(
                  itemCount: records.length,
                  itemBuilder: (context, index) {
                    final record = records[index];
                    final number = lightRecordNumber(record);
                    return ListTile(
                      key: ValueKey('light-go-to-${record.id}'),
                      selected:
                          level < path.length && path[level].id == record.id,
                      title: Text(
                        number ?? record.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        number == null
                            ? 'Number unassigned'
                            : record.title == number
                            ? lightLevelName(record.kind)
                            : record.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => select(record),
                      trailing: IconButton(
                        tooltip: number == null ? 'Set number' : 'Edit number',
                        icon: Icon(
                          number == null ? Icons.tag : Icons.edit_outlined,
                        ),
                        onPressed: () => editNumber(record),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: target == null ? null : () => Navigator.pop(context, target),
        child: Text(target == null ? 'Open' : 'Open ${target!.kind.label}'),
      ),
    ],
  );
}

class LightNumberScroller extends StatelessWidget {
  final EntityKind kind;
  final List<ProductionRecord> choices;
  final ProductionRecord? selected;
  final int generation;
  final bool enabled;
  final VoidCallback onJump;
  final ValueChanged<ProductionRecord> onSelect;

  const LightNumberScroller({
    super.key,
    required this.kind,
    required this.choices,
    required this.selected,
    required this.generation,
    required this.enabled,
    required this.onJump,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final name = lightLevelName(kind);
    final textScaler = MediaQuery.textScalerOf(context);
    return Column(
      children: [
        Text(
          name.toUpperCase(),
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(letterSpacing: 1),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        SizedBox(
          height: math.max(32, textScaler.scale(24)),
          child: LayoutBuilder(
            builder: (context, bounds) {
              final fraction = (48 / bounds.maxWidth).clamp(.4, 1.0);
              return _NumberPages(
                key: ValueKey((
                  kind,
                  selected?.id,
                  generation,
                  fraction,
                  choices
                      .map(
                        (record) => '${record.id}:${lightRecordNumber(record)}',
                      )
                      .join('|'),
                )),
                name: name,
                choices: choices,
                selected: selected,
                fraction: fraction,
                enabled: enabled,
                onJump: onJump,
                onSelect: onSelect,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _NumberPages extends StatefulWidget {
  final String name;
  final List<ProductionRecord> choices;
  final ProductionRecord? selected;
  final double fraction;
  final bool enabled;
  final VoidCallback onJump;
  final ValueChanged<ProductionRecord> onSelect;

  const _NumberPages({
    super.key,
    required this.name,
    required this.choices,
    required this.selected,
    required this.fraction,
    required this.enabled,
    required this.onJump,
    required this.onSelect,
  });

  @override
  State<_NumberPages> createState() => _NumberPagesState();
}

class _NumberPagesState extends State<_NumberPages> {
  late final selectedIndex = widget.choices.indexWhere(
    (record) => record.id == widget.selected?.id,
  );
  late final pages = <ProductionRecord?>[
    if (selectedIndex < 0) null,
    ...widget.choices,
  ];
  late final controller = PageController(
    initialPage: math.max(0, selectedIndex),
    keepPage: false,
    viewportFraction: widget.fraction,
  );
  bool userScrolled = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  bool onScroll(ScrollNotification notification) {
    if ((notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle)) {
      userScrolled = true;
    }
    if (notification is ScrollEndNotification && userScrolled) {
      userScrolled = false;
      final index = controller.page?.round();
      final record = index == null
          ? null
          : pages[index.clamp(0, pages.length - 1)];
      if (record != null && record.id != widget.selected?.id) {
        Future<void>.microtask(() {
          if (mounted && widget.enabled) widget.onSelect(record);
        });
      }
    }
    return false;
  }

  Widget numberButton(ProductionRecord? record) {
    final active = record == null || record.id == widget.selected?.id;
    final number = lightRecordNumber(record);
    final theme = Theme.of(context);
    return Tooltip(
      message: active
          ? 'Go to ${widget.name} number'
          : 'Open ${widget.name} $number',
      child: TextButton(
        onPressed: !widget.enabled
            ? null
            : active
            ? widget.onJump
            : () => widget.onSelect(record),
        style: TextButton.styleFrom(
          minimumSize: Size.zero,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: active
              ? CineTheme.ink
              : theme.colorScheme.onSurfaceVariant,
        ),
        child: Text(
          number ?? '\u00a0',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: active
              ? theme.textTheme.titleMedium
              : theme.textTheme.bodySmall,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (pages.length == 1) return Center(child: numberButton(pages.single));
    return NotificationListener<ScrollNotification>(
      onNotification: onScroll,
      child: PageView.builder(
        key: ValueKey('light-numbers-${widget.name}'),
        controller: controller,
        physics: widget.enabled ? null : const NeverScrollableScrollPhysics(),
        itemCount: pages.length,
        itemBuilder: (_, index) => numberButton(pages[index]),
      ),
    );
  }
}

class LightTakeSlider extends StatefulWidget {
  final List<ProductionRecord> choices;
  final ProductionRecord? selected;
  final bool enabled;
  final Future<void> Function(ProductionRecord) onSelect;

  const LightTakeSlider({
    super.key,
    required this.choices,
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });

  @override
  State<LightTakeSlider> createState() => _LightTakeSliderState();
}

class _LightTakeSliderState extends State<LightTakeSlider> {
  double? preview;

  @override
  Widget build(BuildContext context) {
    final count = widget.choices.length;
    final index = widget.choices.indexWhere(
      (record) => record.id == widget.selected?.id,
    );
    final last = math.max(1, count - 1);
    final value = (preview ?? math.max(0, index).toDouble()).clamp(
      0.0,
      last.toDouble(),
    );
    String? numberAt(double stop) =>
        count == 0 ? null : lightRecordNumber(widget.choices[stop.round()]);
    final number = preview == null
        ? lightRecordNumber(widget.selected)
        : numberAt(value);
    return SizedBox(
      height: CineTheme.touch,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 88),
              child: Text(
                number == null ? 'Take' : 'Take $number',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            Expanded(
              child: Semantics(
                label: 'Take slider',
                child: Slider(
                  key: const ValueKey('light-take-slider'),
                  value: value,
                  max: last.toDouble(),
                  divisions: count > 1 ? count - 1 : null,
                  label: numberAt(value),
                  semanticFormatterCallback: (value) =>
                      numberAt(value) ?? 'No numbered takes',
                  onChanged: widget.enabled && count > 1
                      ? (value) => setState(() => preview = value)
                      : null,
                  onChangeEnd: (value) async {
                    await widget.onSelect(widget.choices[value.round()]);
                    if (mounted) setState(() => preview = null);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

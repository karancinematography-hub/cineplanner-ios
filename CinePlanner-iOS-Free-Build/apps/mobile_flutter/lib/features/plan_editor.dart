import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:uuid/uuid.dart';
import '../data/workspace_repository.dart';
import '../ui/cine_theme.dart';
import '../domain/lighting_plan.dart';
import '../domain/production.dart';
import '../domain/lighting_preset.dart';

class PlanEditor extends StatefulWidget {
  final WorkspaceRepository repository;
  final ProductionRecord shot;
  final Future<bool> Function(LightingPlan)? onCanvasChanged;
  const PlanEditor({
    super.key,
    required this.repository,
    required this.shot,
    this.onCanvasChanged,
  });
  @override
  State<PlanEditor> createState() => _PlanEditorState();
}

class _PlanEditorState extends State<PlanEditor> {
  late ProductionRecord shot;
  late PlanHistory history;
  String? selected;
  bool saving = false;
  bool drawing = false;
  bool polyline = false;
  bool panning = false, snapping = false;
  LightingPlan? gesturePlan;
  math.Point<double>? gestureStart;
  PlanObject? dragged;
  bool resizing = false;
  final viewport = TransformationController();
  Size? canvasSize;
  @override
  void dispose() {
    viewport.dispose();
    super.dispose();
  }

  final List<math.Point<double>> pendingStroke = [];
  String status = 'Saved locally';
  static const pixelsPerMetre = 60.0;
  bool get embedded => widget.onCanvasChanged != null;
  String? hit(math.Point<double> point) {
    for (final object in history.current.objects.reversed) {
      if (object.contains(point)) return object.id;
    }
    return null;
  }

  void startDrag(DragStartDetails event) {
    final point = math.Point(
      event.localPosition.dx / pixelsPerMetre,
      event.localPosition.dy / pixelsPerMetre,
    );
    final current = history.current.objects
        .where((o) => o.id == selected)
        .firstOrNull;
    final onHandle =
        current != null &&
        !current.locked &&
        current.resizeHandle.distanceTo(point) <= 0.25;
    final id = onHandle ? current.id : hit(point);
    setState(() {
      selected = id;
      resizing = onHandle;
      gestureStart = point;
      dragged = id == null
          ? null
          : history.current.objects.singleWhere((o) => o.id == id);
      if (dragged?.locked == true) dragged = null;
    });
  }

  void updateDrag(DragUpdateDetails event) {
    if (dragged == null || gestureStart == null) return;
    if (resizing) {
      final resized = dragged!.resizedTo(
        math.Point(
          event.localPosition.dx / pixelsPerMetre,
          event.localPosition.dy / pixelsPerMetre,
        ),
        snap: snapping ? 0.25 : null,
      );
      setState(
        () => gesturePlan = history.current.withObjects(
          history.current.objects.map((o) => o.id == resized.id ? resized : o),
        ),
      );
      return;
    }
    var x =
        dragged!.x + event.localPosition.dx / pixelsPerMetre - gestureStart!.x;
    var y =
        dragged!.y + event.localPosition.dy / pixelsPerMetre - gestureStart!.y;
    if (snapping) {
      x = (x / 0.25).round() * 0.25;
      y = (y / 0.25).round() * 0.25;
    }
    final moved = dragged!.transformed(x: x, y: y);
    setState(
      () => gesturePlan = history.current.withObjects(
        history.current.objects.map((o) => o.id == moved.id ? moved : o),
      ),
    );
  }

  void endDrag(DragEndDetails event) {
    final plan = gesturePlan;
    setState(() {
      gesturePlan = null;
      gestureStart = null;
      dragged = null;
    });
    if (plan != null) commit(plan);
  }

  @override
  void initState() {
    super.initState();
    shot = widget.shot;
    final json = shot.data['lighting_plan'];
    history = PlanHistory(
      json == null
          ? LightingPlan([])
          : LightingPlan.fromJson(Map<String, dynamic>.from(json as Map)),
    );
  }

  Future<void> persist(LightingPlan plan) async {
    if (saving) return;
    setState(() {
      saving = true;
      status = 'Saving…';
    });
    try {
      final updated = shot.edit(
        data: {...shot.data, 'lighting_plan': plan.toJson()},
        actor: widget.repository.actorId,
        at: DateTime.now(),
      );
      await widget.repository.save(updated, baseRevision: shot.revision);
      if (mounted) {
        setState(() {
          shot = updated;
          status = 'Saved locally';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          status = 'Save failed. Keep this screen open and retry.';
        });
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> commit(LightingPlan plan) async {
    if (embedded) {
      if (saving) return;
      setState(() => saving = true);
      try {
        if (await widget.onCanvasChanged!(plan) && mounted) {
          setState(() => history = PlanHistory(plan));
        }
      } finally {
        if (mounted) setState(() => saving = false);
      }
      return;
    }
    setState(() => history.commit(plan));
    await persist(plan);
  }

  void add(SymbolKind symbol) {
    if (symbol == SymbolKind.polyline) {
      setState(() {
        polyline = true;
        drawing = false;
        panning = false;
        selected = null;
        pendingStroke.clear();
      });
      return;
    }
    final size = canvasSize;
    final position = size == null
        ? const Offset(2 * pixelsPerMetre, 2 * pixelsPerMetre)
        : viewport.toScene(Offset(size.width * 0.4, size.height * 0.32));
    final object = PlanObject(
      id: const Uuid().v4(),
      symbol: symbol,
      x: position.dx / pixelsPerMetre,
      y: position.dy / pixelsPerMetre,
      label: symbol.name,
    );
    selected = object.id;
    commit(history.current.withObjects([...history.current.objects, object]));
  }

  void sizeCanvas(Size size) {
    final previous = canvasSize;
    if (size == previous || size.isEmpty) return;
    final double scale;
    final Offset center;
    if (previous == null) {
      final bounds = planBounds(history.current);
      scale = math
          .min(
            size.width / (bounds.width * pixelsPerMetre),
            size.height / (bounds.height * pixelsPerMetre),
          )
          .clamp(0.05, 1.0);
      center =
          Offset(
            bounds.left + bounds.width / 2,
            bounds.top + bounds.height / 2,
          ) *
          pixelsPerMetre;
    } else {
      double fit(Size viewportSize) =>
          math.min(viewportSize.width / 10, viewportSize.height / 8);
      center = viewport.toScene(previous.center(Offset.zero));
      scale = (viewport.value.getMaxScaleOnAxis() * fit(size) / fit(previous))
          .clamp(0.05, 4.0);
    }
    canvasSize = size;
    final origin = size.center(Offset.zero) - center * scale;
    viewport.value = Matrix4.diagonal3Values(scale, scale, scale)
      ..setTranslationRaw(origin.dx, origin.dy, 0);
  }

  void finishPolyline() {
    if (pendingStroke.length < 2) return;
    final stroke = DrawingStroke(
      id: const Uuid().v4(),
      points: pendingStroke,
      kind: 'polyline',
    );
    setState(() {
      polyline = false;
      pendingStroke.clear();
    });
    commit(
      LightingPlan(
        history.current.objects,
        strokes: [...history.current.strokes, stroke],
      ),
    );
  }

  Future<void> savePreset() async {
    var name = '${shot.title} setup';
    if (name.length > 80) name = name.substring(0, 80);
    var selectedOnly = false;
    final form = GlobalKey<FormState>();
    final choice = await showDialog<({String name, bool selectedOnly})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Save lighting preset'),
          content: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: name,
                  maxLength: 80,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Preset name'),
                  onChanged: (value) => name = value,
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Enter a name' : null,
                ),
                if (selected != null)
                  CheckboxListTile(
                    title: const Text('Selected object only'),
                    value: selectedOnly,
                    onChanged: (value) =>
                        setDialogState(() => selectedOnly = value ?? false),
                  ),
                const Text(
                  'Saves lighting objects and drawings in this project. Camera settings and frame grabs are unchanged.',
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
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(context, (
                    name: name.trim(),
                    selectedOnly: selectedOnly,
                  ));
                }
              },
              child: const Text('Save preset'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => saving = true);
    try {
      final plan = choice.selectedOnly
          ? LightingPlan(history.current.objects.where((o) => o.id == selected))
          : history.current;
      await widget.repository.saveLightingPreset(
        projectId: shot.projectId!,
        name: choice.name,
        plan: plan,
        sourceShotId: shot.id,
        sourceRevision: shot.revision,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lighting preset saved locally')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Preset could not be saved. Reopen the shot to check its revision.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> applyPreset() async {
    setState(() => saving = true);
    try {
      final presets = await widget.repository.lightingPresets(shot.projectId!);
      if (!mounted) return;
      if (presets.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No lighting presets saved in this project.'),
          ),
        );
        return;
      }
      var replace = false;
      final choice = await showDialog<({LightingPreset preset, bool replace})>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Apply lighting preset'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: const Text('Replace current plan'),
                    subtitle: const Text(
                      'Otherwise append with a 1 m offset. Undo remains available.',
                    ),
                    value: replace,
                    onChanged: (value) => setDialogState(() => replace = value),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final preset in presets)
                            ListTile(
                              title: Text(preset.name),
                              subtitle: Text(
                                '${preset.plan.objects.length} objects • ${preset.plan.strokes.length} drawings • source r${preset.sourceRevision}',
                              ),
                              onTap: () => Navigator.pop(context, (
                                preset: preset,
                                replace: replace,
                              )),
                            ),
                        ],
                      ),
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
            ],
          ),
        ),
      );
      if (choice == null || !mounted) return;
      final cloned = choice.preset.plan.freshCopy(
        () => const Uuid().v4(),
        dx: choice.replace ? 0 : 1,
        dy: choice.replace ? 0 : 1,
      );
      setState(() => saving = false);
      selected = null;
      await commit(choice.replace ? cloned : history.current.append(cloned));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Preset could not be applied. Your existing plan was preserved.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void transform({double dx = 0, double dy = 0, double rotation = 0}) {
    if (history.current.objects.any((o) => o.id == selected && o.locked)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unlock the object in Properties before moving it.'),
        ),
      );
      return;
    }
    commit(
      history.current.withObjects(
        history.current.objects.map(
          (o) => o.id == selected
              ? o.transformed(
                  x: o.x + dx,
                  y: o.y + dy,
                  heading: o.heading + rotation,
                )
              : o,
        ),
      ),
    );
  }

  Future<void> properties() async {
    final matches = history.current.objects.where((o) => o.id == selected);
    if (matches.isEmpty) return;
    final object = matches.single;
    final fields = <String, String>{
      'Label': object.label,
      'Model': object.model,
      'Modifier': object.modifier,
      'Kelvin': object.kelvin?.toString() ?? '',
      'Power (%)': object.powerPercent?.toString() ?? '',
      'Height (m)': object.heightMetres?.toString() ?? '',
      'Width (m)': object.width.toString(),
      'Depth (m)': object.height.toString(),
      'Notes': object.notes,
    };
    final controllers = fields.map(
      (key, value) => MapEntry(key, TextEditingController(text: value)),
    );
    final form = GlobalKey<FormState>();
    var locked = object.locked;
    final updated = await showDialog<PlanObject>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Object properties'),
          content: SizedBox(
            width: 400,
            child: Form(
              key: form,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final key in fields.keys)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: TextFormField(
                          controller: controllers[key],
                          decoration: InputDecoration(labelText: key),
                          validator: (value) {
                            if ((value?.length ?? 0) >
                                (key == 'Notes' ? 8000 : 200)) {
                              return 'Shorten this field';
                            }
                            if ([
                              'Kelvin',
                              'Power (%)',
                              'Height (m)',
                              'Width (m)',
                              'Depth (m)',
                            ].contains(key)) {
                              if ((value ?? '').isEmpty) {
                                return ['Width (m)', 'Depth (m)'].contains(key)
                                    ? 'Required'
                                    : null;
                              }
                              final number = double.tryParse(value!);
                              if (number == null ||
                                  !number.isFinite ||
                                  (key == 'Kelvin' &&
                                      (number < 1000 || number > 50000)) ||
                                  (key == 'Power (%)' &&
                                      (number < 0 || number > 100)) ||
                                  (key == 'Height (m)' && number < 0) ||
                                  (['Width (m)', 'Depth (m)'].contains(key) &&
                                      (number <= 0 || number > 1000000))) {
                                return 'Enter a valid $key';
                              }
                            }
                            return null;
                          },
                        ),
                      ),
                    SwitchListTile(
                      title: const Text('Lock object'),
                      value: locked,
                      onChanged: (value) =>
                          setDialogState(() => locked = value),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (!form.currentState!.validate()) return;
                Navigator.pop(
                  context,
                  PlanObject(
                    id: object.id,
                    symbol: object.symbol,
                    x: object.x,
                    y: object.y,
                    heading: object.heading,
                    label: controllers['Label']!.text,
                    model: controllers['Model']!.text,
                    modifier: controllers['Modifier']!.text,
                    notes: controllers['Notes']!.text,
                    kelvin: double.tryParse(controllers['Kelvin']!.text),
                    powerPercent: double.tryParse(
                      controllers['Power (%)']!.text,
                    ),
                    heightMetres: double.tryParse(
                      controllers['Height (m)']!.text,
                    ),
                    width: double.parse(controllers['Width (m)']!.text),
                    height: double.parse(controllers['Depth (m)']!.text),
                    locked: locked,
                  ),
                );
              },
              child: const Text('Save locally'),
            ),
          ],
        ),
      ),
    );
    if (updated != null && mounted) {
      await commit(
        history.current.withObjects(
          history.current.objects.map((o) => o.id == updated.id ? updated : o),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => embedded
      ? canvasBody()
      : PopScope(
          canPop: !saving && !status.startsWith('Save failed'),
          child: Scaffold(
            appBar: AppBar(
              title: Text('${shot.title} · Lighting plan'),
              actions: [
                IconButton(
                  tooltip: 'Save lighting preset',
                  onPressed: saving || status.startsWith('Save failed')
                      ? null
                      : savePreset,
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
                IconButton(
                  tooltip: 'Apply lighting preset',
                  onPressed: saving || status.startsWith('Save failed')
                      ? null
                      : applyPreset,
                  icon: const Icon(Icons.collections_bookmark_outlined),
                ),
                IconButton(
                  tooltip: 'Undo',
                  onPressed: !saving && history.canUndo
                      ? () {
                          setState(() {
                            history.undo();
                            selected = null;
                          });
                          persist(history.current);
                        }
                      : null,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  tooltip: 'Redo',
                  onPressed: !saving && history.canRedo
                      ? () {
                          setState(() {
                            history.redo();
                            selected = null;
                          });
                          persist(history.current);
                        }
                      : null,
                  icon: const Icon(Icons.redo),
                ),
                if (status.startsWith('Save failed'))
                  TextButton(
                    onPressed: saving ? null : () => persist(history.current),
                    child: const Text('Retry save'),
                  ),
              ],
            ),
            body: CinePage(maxWidth: 1600, child: canvasBody()),
          ),
        );

  Widget canvasBody() => Column(
    children: [
      if (embedded)
        SizedBox(
          key: const ValueKey('light-canvas-toolbar'),
          height: CineTheme.touch,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              PopupMenuButton<SymbolKind>(
                tooltip: 'Canvas symbols',
                iconSize: CineTheme.mediumGlyph,
                icon: const Icon(Icons.category_outlined),
                enabled: !saving,
                onSelected: add,
                itemBuilder: (_) => [
                  for (final symbol in SymbolKind.values)
                    PopupMenuItem(value: symbol, child: Text(symbol.name)),
                ],
              ),
              IconButton(
                tooltip: 'Freehand pen',
                iconSize: CineTheme.mediumGlyph,
                isSelected: drawing,
                icon: const Icon(Icons.draw_outlined),
                onPressed: saving
                    ? null
                    : () => setState(() {
                        drawing = !drawing;
                        panning = polyline = false;
                        pendingStroke.clear();
                        selected = null;
                      }),
              ),
              IconButton(
                tooltip: 'Pan / zoom',
                iconSize: CineTheme.mediumGlyph,
                isSelected: panning,
                icon: const Icon(Icons.pan_tool_outlined),
                onPressed: saving
                    ? null
                    : () => setState(() {
                        panning = !panning;
                        drawing = polyline = false;
                        pendingStroke.clear();
                      }),
              ),
              IconButton(
                tooltip: 'Snap 25 cm',
                iconSize: CineTheme.mediumGlyph,
                isSelected: snapping,
                icon: const Icon(Icons.grid_on),
                onPressed: saving
                    ? null
                    : () => setState(() => snapping = !snapping),
              ),
            ],
          ),
        ),
      if (embedded) const Divider(height: 1),
      if (!embedded)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            '${polyline
                ? 'Polyline draft • tap points, then Finish'
                : gesturePlan != null
                ? 'Editing • release to save'
                : status} • metres • ${panning ? 'pinch to zoom / pan' : 'drag an object to move'}',
          ),
        ),
      if (polyline)
        Wrap(
          spacing: 8,
          children: [
            const Text('Polyline: tap points, then finish'),
            TextButton(
              onPressed: pendingStroke.length < 2 ? null : finishPolyline,
              child: const Text('Finish polyline'),
            ),
            TextButton(
              onPressed: () => setState(() {
                polyline = false;
                pendingStroke.clear();
              }),
              child: const Text('Cancel polyline'),
            ),
          ],
        ),
      if (!embedded)
        Wrap(
          spacing: 8,
          alignment: WrapAlignment.center,
          children: [
            FilterChip(
              label: const Text('Polyline'),
              selected: polyline,
              onSelected: saving
                  ? null
                  : (value) {
                      if (value) {
                        add(SymbolKind.polyline);
                      } else {
                        setState(() {
                          polyline = false;
                          pendingStroke.clear();
                        });
                      }
                    },
            ),
            FilterChip(
              label: const Text('Pan / zoom'),
              selected: panning,
              onSelected: saving
                  ? null
                  : (value) => setState(() {
                      panning = value;
                      drawing = false;
                      polyline = false;
                      pendingStroke.clear();
                    }),
            ),
            FilterChip(
              label: const Text('Snap 25 cm'),
              selected: snapping,
              onSelected: saving
                  ? null
                  : (value) => setState(() => snapping = value),
            ),
            FilterChip(
              label: const Text('Freehand pen'),
              selected: drawing,
              onSelected: saving
                  ? null
                  : (value) => setState(() {
                      drawing = value;
                      panning = false;
                      polyline = false;
                      pendingStroke.clear();
                      selected = null;
                    }),
            ),
          ],
        ),
      if (!embedded)
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: SymbolKind.values
                .where((kind) => kind != SymbolKind.polyline)
                .map(
                  (kind) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ActionChip(
                      label: Text(kind.name),
                      onPressed: saving ? null : () => add(kind),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      Expanded(
        child: LayoutBuilder(
          builder: (context, bounds) {
            if (embedded) sizeCanvas(bounds.biggest);
            return CustomPaint(
              painter: _CanvasGrid(viewport),
              child: InteractiveViewer(
                transformationController: viewport,
                panEnabled: panning,
                scaleEnabled: panning,
                constrained: false,
                boundaryMargin: embedded
                    ? const EdgeInsets.all(double.infinity)
                    : EdgeInsets.zero,
                minScale: embedded ? 0.05 : 0.25,
                maxScale: 4,
                child: GestureDetector(
                  dragStartBehavior: DragStartBehavior.down,
                  onPanStart: drawing && !saving
                      ? (event) {
                          setState(() {
                            pendingStroke.clear();
                            pendingStroke.add(
                              math.Point(
                                event.localPosition.dx / pixelsPerMetre,
                                event.localPosition.dy / pixelsPerMetre,
                              ),
                            );
                          });
                        }
                      : !panning && !saving && !polyline
                      ? startDrag
                      : null,
                  onPanUpdate: drawing && !saving
                      ? (event) {
                          setState(
                            () => pendingStroke.add(
                              math.Point(
                                event.localPosition.dx / pixelsPerMetre,
                                event.localPosition.dy / pixelsPerMetre,
                              ),
                            ),
                          );
                        }
                      : !panning && !saving && !polyline
                      ? updateDrag
                      : null,
                  onPanCancel: panning || saving || polyline
                      ? null
                      : () => setState(() {
                          pendingStroke.clear();
                          gesturePlan = null;
                          gestureStart = null;
                          dragged = null;
                        }),
                  onPanEnd: drawing && !saving
                      ? (_) {
                          if (pendingStroke.length >= 2) {
                            final stroke = DrawingStroke(
                              id: const Uuid().v4(),
                              points: pendingStroke,
                            );
                            pendingStroke.clear();
                            commit(
                              LightingPlan(
                                history.current.objects,
                                strokes: [...history.current.strokes, stroke],
                              ),
                            );
                          } else {
                            setState(pendingStroke.clear);
                          }
                        }
                      : !panning && !saving && !polyline
                      ? endDrag
                      : null,
                  onTapUp: (event) {
                    final point = math.Point(
                      event.localPosition.dx / pixelsPerMetre,
                      event.localPosition.dy / pixelsPerMetre,
                    );
                    if (polyline) {
                      setState(() => pendingStroke.add(point));
                      return;
                    }
                    setState(() => selected = hit(point));
                  },
                  child: CustomPaint(
                    size: const Size(1800, 1200),
                    painter: LightingPainter(
                      gesturePlan ?? history.current,
                      selected,
                      preview: List.of(pendingStroke),
                      lightSurface: true,
                      showGrid: false,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
      if (selected != null)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Properties',
                onPressed: saving ? null : properties,
                icon: const Icon(Icons.tune),
              ),
              IconButton(
                tooltip: 'Move left 25 cm',
                onPressed: saving ? null : () => transform(dx: -0.25),
                icon: const Icon(Icons.arrow_back),
              ),
              IconButton(
                tooltip: 'Move up 25 cm',
                onPressed: saving ? null : () => transform(dy: -0.25),
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                tooltip: 'Move down 25 cm',
                onPressed: saving ? null : () => transform(dy: 0.25),
                icon: const Icon(Icons.arrow_downward),
              ),
              IconButton(
                tooltip: 'Move right 25 cm',
                onPressed: saving ? null : () => transform(dx: 0.25),
                icon: const Icon(Icons.arrow_forward),
              ),
              IconButton(
                tooltip: 'Rotate 15 degrees',
                onPressed: saving ? null : () => transform(rotation: 15),
                icon: const Icon(Icons.rotate_right),
              ),
              IconButton(
                tooltip: 'Delete selected object',
                onPressed: saving
                    ? null
                    : () {
                        final id = selected;
                        if (history.current.objects.any(
                          (o) => o.id == id && o.locked,
                        )) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Unlock the object before deleting it.',
                              ),
                            ),
                          );
                          return;
                        }
                        selected = null;
                        commit(
                          history.current.withObjects(
                            history.current.objects.where((o) => o.id != id),
                          ),
                        );
                      },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
    ],
  );
}

class _CanvasGrid extends CustomPainter {
  final TransformationController viewport;

  _CanvasGrid(this.viewport) : super(repaint: viewport);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = CineTheme.chalk);
    final transform = viewport.value;
    final translation = transform.getTranslation();
    var step = _PlanEditorState.pixelsPerMetre * transform.getMaxScaleOnAxis();
    while (step < 18) {
      step *= 2;
    }
    final line = Paint()
      ..color = CineTheme.stone.withValues(alpha: 0.65)
      ..strokeWidth = 1;
    for (var x = translation.x % step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (var y = translation.y % step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(_CanvasGrid oldDelegate) =>
      oldDelegate.viewport != viewport;
}

class LightingPainter extends CustomPainter {
  final LightingPlan plan;
  final String? selected;
  final List<math.Point<double>> preview;
  final bool showGrid;
  final bool lightSurface;
  LightingPainter(
    this.plan,
    this.selected, {
    this.preview = const [],
    this.showGrid = true,
    this.lightSurface = false,
  });
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = lightSurface
          ? CineTheme.stone.withValues(alpha: 0.65)
          : const Color(0xff303638)
      ..strokeWidth = 1;
    if (showGrid) {
      for (double x = 0; x < size.width; x += 60) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      }
      for (double y = 0; y < size.height; y += 60) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
      }
    }
    void drawStroke(List<math.Point<double>> points, int color, double width) {
      if (points.length < 2) return;
      final path = Path()..moveTo(points.first.x * 60, points.first.y * 60);
      for (final point in points.skip(1)) {
        path.lineTo(point.x * 60, point.y * 60);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Color(color)
          ..strokeWidth = width * 60
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke,
      );
    }

    for (final stroke in plan.strokes) {
      drawStroke(stroke.points, stroke.color, stroke.width);
    }
    drawStroke(
      preview,
      lightSurface ? CineTheme.charcoal.toARGB32() : 0xffffca70,
      0.04,
    );
    for (final o in plan.objects) {
      canvas.save();
      canvas.translate((o.x + o.width / 2) * 60, (o.y + o.height / 2) * 60);
      canvas.rotate((o.heading % 360) * math.pi / 180);
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: o.width * 60,
        height: o.height * 60,
      );
      final paint = Paint()
        ..color = lightSurface
            ? (o.id == selected ? CineTheme.olive : CineTheme.ink)
            : o.id == selected
            ? Colors.amber
            : Colors.tealAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      switch (o.symbol) {
        case SymbolKind.actor:
        case SymbolKind.ellipse:
          canvas.drawOval(rect, paint);
        case SymbolKind.arrow:
          canvas.drawLine(rect.centerLeft, rect.centerRight, paint);
          canvas.drawLine(
            rect.centerRight,
            rect.topRight - const Offset(16, 0),
            paint,
          );
          canvas.drawLine(
            rect.centerRight,
            rect.bottomRight - const Offset(16, 0),
            paint,
          );
        case SymbolKind.camera:
          canvas.drawRect(rect.deflate(10), paint);
          canvas.drawPath(
            Path()
              ..moveTo(rect.right - 10, -12)
              ..lineTo(rect.right + 8, -24)
              ..lineTo(rect.right + 8, 24)
              ..lineTo(rect.right - 10, 12),
            paint,
          );
        case SymbolKind.fresnel:
          canvas.drawOval(rect, paint);
          canvas.drawLine(rect.topCenter, rect.bottomCenter, paint);
        case SymbolKind.text:
          break;
        case SymbolKind.line:
        case SymbolKind.polyline:
        case SymbolKind.dimension:
          canvas.drawLine(rect.topLeft, rect.bottomRight, paint);
        case SymbolKind.lightCone:
          final cone = Path()
            ..moveTo(rect.left, 0)
            ..lineTo(rect.right, rect.top)
            ..lineTo(rect.right, rect.bottom)
            ..close();
          canvas.drawPath(
            cone,
            Paint()
              ..color = (lightSurface ? CineTheme.olive : Colors.amber)
                  .withValues(alpha: 0.25),
          );
          canvas.drawPath(cone, paint);
        case SymbolKind.wall:
          canvas.drawRect(
            rect,
            Paint()
              ..color = (lightSurface ? CineTheme.stone : Colors.blueGrey)
                  .withValues(alpha: 0.5),
          );
          canvas.drawRect(rect, paint);
        case SymbolKind.window:
        case SymbolKind.door:
          canvas.drawRect(rect, paint);
          canvas.drawLine(rect.centerLeft, rect.centerRight, paint);
        case SymbolKind.stand:
        case SymbolKind.boom:
          canvas.drawLine(rect.topCenter, rect.bottomCenter, paint);
          canvas.drawLine(rect.centerLeft, rect.centerRight, paint);
          if (o.symbol == SymbolKind.boom) {
            canvas.drawLine(rect.topLeft, rect.topRight, paint);
          }
        case SymbolKind.chair:
          canvas.drawRect(rect.deflate(8), paint);
          canvas.drawLine(rect.topLeft, rect.topRight, paint);
        case SymbolKind.diffusionFrame:
          canvas.drawRect(rect, paint);
          canvas.drawLine(rect.topLeft, rect.bottomRight, paint);
          canvas.drawLine(rect.topRight, rect.bottomLeft, paint);
        default:
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(4)),
            paint,
          );
      }
      if (o.id == selected && !o.locked) {
        canvas.drawRect(
          Rect.fromCenter(center: rect.bottomRight, width: 12, height: 12),
          Paint()..color = lightSurface ? CineTheme.olive : Colors.amber,
        );
      }
      final text = TextPainter(
        text: TextSpan(
          text: o.displayLabel,
          style: TextStyle(
            color: lightSurface ? CineTheme.ink : Colors.white,
            fontFamily: lightSurface ? CineTheme.fontFamily : null,
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 160);
      text.paint(canvas, Offset(-text.width / 2, rect.bottom + 6));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant LightingPainter oldDelegate) =>
      oldDelegate.plan != plan ||
      oldDelegate.selected != selected ||
      oldDelegate.preview != preview ||
      oldDelegate.showGrid != showGrid ||
      oldDelegate.lightSurface != lightSurface;
}

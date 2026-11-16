import 'dart:math' as math;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../data/workspace_repository.dart';
import '../domain/frame_grab.dart';
import '../domain/light_plan.dart';
import '../domain/lighting_plan.dart';
import '../domain/production.dart';
import 'capture_recovery.dart';
import 'light_plan_labels.dart';
import 'light_plan_navigation.dart';
import '../ui/cine_theme.dart';
import 'local_share.dart';
import 'plan_editor.dart';
import 'shot_export.dart';

typedef _Selection = ({
  ProductionRecord day,
  ProductionRecord? scene,
  ProductionRecord? shot,
  ProductionRecord? take,
});

typedef _NumberChoices = ({
  List<ProductionRecord> scenes,
  List<ProductionRecord> shots,
  List<ProductionRecord> takes,
});

typedef _TakeMedia = ({
  Map<int, FrameGrab?> previews,
  Map<String, Object?>? pending,
});

typedef _HistoryEntry = Future<void> Function(bool redo);

class LightPlanScreen extends StatefulWidget {
  final WorkspaceRepository repository;
  final ProductionRecord entry;

  const LightPlanScreen({
    super.key,
    required this.repository,
    required this.entry,
  });

  @override
  State<LightPlanScreen> createState() => _LightPlanScreenState();
}

class _LightPlanScreenState extends State<LightPlanScreen> {
  WorkspaceRepository get repository => widget.repository;
  final revisions = <String, ProductionRecord>{};
  final history = <_HistoryEntry>[];
  final redoHistory = <_HistoryEntry>[];
  final previews = <int, FrameGrab?>{};
  _Selection? selection;
  Map<String, Object?>? pending;
  bool busy = false;
  int canvasGeneration = 0;
  int? openGrab;
  _NumberChoices numbers = (scenes: [], shots: [], takes: []);
  int navigationGeneration = 0;

  ProductionRecord? get take {
    final current = selection?.take;
    return current == null ? null : revisions[current.id] ?? current;
  }

  Map get slots => take?.data['frame_grabs'] as Map? ?? const {};
  bool get pendingForTake =>
      take != null && pending?['destination_take_id'] == take!.id;

  @override
  void initState() {
    super.initState();
    run(() => switchTo(widget.entry.id, explicit: false), refresh: false);
  }

  Future<void> switchTo(String id, {bool explicit = true}) async {
    var record = await repository.get(id);
    ProductionRecord? day, scene, shot, active;
    while (record != null && record.deletedAt == null) {
      switch (record.kind) {
        case EntityKind.take:
          active = record;
        case EntityKind.shot:
          shot = record;
        case EntityKind.scene:
          scene = record;
        case EntityKind.shootDay:
          day = record;
        default:
          break;
      }
      if (day != null || record.parentId == null) break;
      record = await repository.get(record.parentId!);
    }
    if (day == null || (explicit && day.id != selection?.day.id)) {
      throw StateError('This record is unavailable in the current shoot day.');
    }
    if (shot == null) {
      final branch = await firstAvailableBranch(day, scene);
      scene = branch.scene;
      shot = branch.shot;
      active = branch.take;
    } else {
      active ??= (await lightChildren(repository, shot.id)).firstOrNull;
    }
    if (explicit &&
        scene?.id == selection?.scene?.id &&
        shot?.id == selection?.shot?.id &&
        active?.id == take?.id) {
      await refreshMedia();
      await refreshNumbers();
      return;
    }

    if (active != null) active = await repository.openLightTake(active.id);
    final destination = (day: day, scene: scene, shot: shot, take: active);
    final choices = await readNumbers(destination);
    final media = await readMedia(active);
    selection = destination;
    numbers = choices;
    if (explicit) {
      history.clear();
      redoHistory.clear();
      revisions.clear();
      openGrab = null;
    }
    if (active != null) revisions[active.id] = active;
    applyMedia(media);
  }

  Future<
    ({ProductionRecord? scene, ProductionRecord? shot, ProductionRecord? take})
  >
  firstAvailableBranch(ProductionRecord day, ProductionRecord? scene) async {
    final scenes = scene == null
        ? await lightChildren(repository, day.id)
        : [scene];
    var fallback = (scene: scenes.firstOrNull, shot: null as ProductionRecord?);
    for (final candidate in scenes) {
      final shots = await lightChildren(repository, candidate.id);
      if (fallback.shot == null && shots.isNotEmpty) {
        fallback = (scene: candidate, shot: shots.first);
      }
      for (final shot in shots) {
        final take = (await lightChildren(repository, shot.id)).firstOrNull;
        if (take != null) return (scene: candidate, shot: shot, take: take);
      }
    }
    return (scene: fallback.scene, shot: fallback.shot, take: null);
  }

  Future<_NumberChoices> readNumbers(_Selection? path) async {
    Future<List<ProductionRecord>> numberedChildren(
      ProductionRecord? parent,
    ) async => parent == null
        ? []
        : (await lightChildren(
            repository,
            parent.id,
          )).where((record) => lightRecordNumber(record) != null).toList();

    final levels = await Future.wait([
      numberedChildren(path?.day),
      numberedChildren(path?.scene),
      numberedChildren(path?.shot),
    ]);
    return (scenes: levels[0], shots: levels[1], takes: levels[2]);
  }

  Future<void> refreshNumbers() async {
    try {
      numbers = await readNumbers(selection);
    } catch (_) {
      numbers = (scenes: [], shots: [], takes: []);
    }
  }

  Future<void> selectNumber(ProductionRecord record) async {
    if (busy) return;
    final loaded = await run(() => switchTo(record.id), refresh: false);
    if (!loaded && mounted) setState(() => navigationGeneration++);
  }

  Future<bool> run(
    Future<void> Function() operation, {
    bool refresh = true,
    bool refreshChoices = false,
  }) async {
    if (busy) return false;
    setState(() => busy = true);
    try {
      await operation();
      return true;
    } catch (error) {
      notice(switch (error) {
        StateError() => error.message,
        FormatException() => error.message,
        _ =>
          'Light Plan could not finish that action. Check the workspace and retry.',
      });
      return false;
    } finally {
      try {
        if (refreshChoices) await refreshNumbers();
        if (refresh) await refreshMedia();
      } finally {
        if (mounted) setState(() => busy = false);
      }
    }
  }

  void notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<_TakeMedia> readMedia(ProductionRecord? active) async {
    final pending = await repository.pendingCapture();
    final previews = <int, FrameGrab?>{};
    if (active != null) {
      final slots = active.data['frame_grabs'] as Map? ?? const {};
      for (final slot in [1, 2]) {
        final ref = slots['$slot'] as Map?;
        if (ref != null) {
          try {
            previews[slot] = await repository.framePreview(
              active.parentId!,
              ref['asset_id'] as String,
            );
          } catch (_) {
            previews[slot] = null;
          }
        }
      }
    }
    return (previews: previews, pending: pending);
  }

  void applyMedia(_TakeMedia media) {
    previews
      ..clear()
      ..addAll(media.previews);
    pending = media.pending;
  }

  Future<void> refreshMedia() async {
    try {
      applyMedia(await readMedia(take));
    } catch (_) {
      previews.clear();
    }
  }

  Future<void> goTo() async {
    var numbered = false;
    final target = await showDialog<ProductionRecord>(
      context: context,
      builder: (_) => LightGoToDialog(
        repository: repository,
        dayId: selection!.day.id,
        onNumberChanged: (updated) {
          if (!mounted) return;
          numbered = true;
          setState(() {
            final current = selection!;
            if (current.take?.id == updated.id) revisions[updated.id] = updated;
            selection = (
              day: current.day,
              scene: current.scene?.id == updated.id ? updated : current.scene,
              shot: current.shot?.id == updated.id ? updated : current.shot,
              take: current.take?.id == updated.id ? updated : current.take,
            );
            if (current.take?.id == updated.id ||
                current.shot?.id == updated.id ||
                current.scene?.id == updated.id) {
              history.clear();
              redoHistory.clear();
            }
          });
        },
      ),
    );
    if (!mounted) return;
    if (target != null) {
      await run(() => switchTo(target.id), refresh: false);
    } else if (numbered) {
      await run(() async {}, refreshChoices: true);
    }
  }

  ProductionRecord? jumpParent(EntityKind kind) => switch (kind) {
    EntityKind.scene => selection?.day,
    EntityKind.shot => selection?.scene,
    EntityKind.take => selection?.shot,
    _ => null,
  };

  Future<void> jump(EntityKind kind) async {
    final parent = jumpParent(kind);
    if (parent == null) return;
    final name = lightLevelName(kind);
    final entered = await showLightNumbers(
      context,
      title: 'Go to $name',
      fields: {'$name number': ''},
      action: 'Go',
    );
    if (!mounted || entered == null) return;
    await run(() async {
      final number = parseLightNumber(entered.single);
      final matches = (await lightChildren(repository, parent.id))
          .where(
            (record) => parseLightNumber(lightRecordNumber(record)) == number,
          )
          .toList();
      if (matches.isEmpty) {
        notice('No $name ${entered.single} in this ${parent.kind.label}.');
        return;
      }
      if (!mounted) return;
      final target = matches.length == 1
          ? matches.single
          : await showDialog<ProductionRecord>(
              context: context,
              builder: (context) => SimpleDialog(
                title: Text('Choose $name ${entered.single}'),
                children: [
                  for (final match in matches)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, match),
                      child: ListTile(
                        title: Text(match.title),
                        subtitle: Text(
                          '${match.createdAt.toLocal()} · ${match.id}',
                        ),
                      ),
                    ),
                ],
              ),
            );
      if (target != null && mounted) await switchTo(target.id);
    }, refresh: false);
  }

  void recordHistory(_HistoryEntry entry) {
    history.add(entry);
    redoHistory.clear();
  }

  Future<void> stepHistory(bool redo) => run(() async {
    final from = redo ? redoHistory : history;
    final to = redo ? history : redoHistory;
    final entry = from.last;
    await entry(redo);
    to.add(from.removeLast());
    canvasGeneration++;
  }, refreshChoices: true);

  Future<ProductionRecord> saveData(
    ProductionRecord base,
    Map<String, Object?> data,
  ) async {
    final updated = base.edit(
      data: data,
      actor: repository.actorId,
      at: DateTime.now(),
    );
    await repository.save(updated, baseRevision: base.revision);
    return revisions[updated.id] = updated;
  }

  void recordEdit(ProductionRecord before, ProductionRecord after) {
    revisions[after.id] = after;
    recordHistory((redo) async {
      final current = revisions[before.id]!;
      await saveData(current, (redo ? after : before).data);
    });
  }

  Future<bool> saveCanvas(LightingPlan canvas, {bool reset = false}) =>
      run(() async {
        final before = take!;
        final after = await saveData(before, {
          ...before.data,
          'lighting_plan': canvas.toJson(),
        });
        recordEdit(before, after);
        if (reset) canvasGeneration++;
      });

  Future<void> add() async {
    final previous = selection!;
    final source = take;
    LightPlanCreation? selected;
    final kind = await showDialog<LightPlanCreation>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          scrollable: true,
          title: const Text('Add new'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final choice in LightPlanCreation.values)
                CheckboxListTile(
                  title: Text('New ${lightLevelNames[choice.index]}'),
                  value: selected == choice,
                  onChanged: switch (choice) {
                    LightPlanCreation.shot when previous.scene == null => null,
                    LightPlanCreation.take when previous.shot == null => null,
                    _ => (checked) => update(
                      () => selected = checked == true ? choice : null,
                    ),
                  },
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selected == null
                  ? null
                  : () => Navigator.pop(context, selected),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    var copy = false;
    var numbers = <String>[];
    if (kind != LightPlanCreation.take) {
      final newScene = kind == LightPlanCreation.scene;
      if (!newScene && lightRecordNumber(previous.scene) == null) {
        notice('Set the current scene number in Go to before adding a shot.');
        return;
      }
      final answer = await confirm(
        'Do you want to copy prev data?',
        yes: 'Yes',
        no: 'No',
      );
      if (answer == null || !mounted) return;
      copy = answer;
      final draft = await showLightNumbers(
        context,
        title: newScene
            ? 'Number the new scene'
            : 'New shot · Scene ${lightRecordNumber(previous.scene)}',
        fields: {
          if (newScene) 'Scene number': '',
          'Shot number': '',
          'Take number': '',
        },
        action: 'Save',
      );
      if (draft == null || !mounted) return;
      numbers = draft;
    }
    await run(() async {
      final branch = await repository.createLightRecord(
        kind: kind,
        shootDayId: previous.day.id,
        sceneId: previous.scene?.id,
        shotId: previous.shot?.id,
        source: source,
        copyCanvas: copy,
        numbers: numbers,
      );
      final next = (
        day: previous.day,
        scene: kind == LightPlanCreation.scene ? branch.first : previous.scene,
        shot: kind == LightPlanCreation.take
            ? previous.shot
            : branch[branch.length - 2],
        take: branch.last,
      );
      for (final record in branch) {
        revisions[record.id] = record;
      }
      selection = next;
      openGrab = null;
      recordHistory((redo) async {
        final changed = await repository.setLightCreationVisible(
          branch.map((item) => revisions[item.id]!).toList(),
          visible: redo,
        );
        for (final record in changed) {
          revisions[record.id] = record;
        }
        selection = redo ? next : previous;
        openGrab = null;
      });
    }, refreshChoices: true);
  }

  Future<bool?> confirm(
    String title, {
    required String yes,
    String no = 'Cancel',
    String? message,
  }) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(no),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(yes),
        ),
      ],
    ),
  );

  Future<void> reset() async {
    if (await confirm(
              'Reset Take?',
              yes: 'Reset',
              message:
                  'Clear the light and camera canvas for this take. You can undo this.',
            ) ==
            true &&
        mounted) {
      await saveCanvas(LightingPlan([]), reset: true);
    }
  }

  Future<void> grab(
    int slot, {
    required bool camera,
    bool retake = false,
  }) async {
    if (retake &&
        await confirm(
              'Retake Grab $slot?',
              yes: 'Open camera',
              message:
                  'A new capture will replace this preview. The previous image is retained.',
            ) !=
            true) {
      return;
    }
    if (!mounted) return;
    await run(() async {
      final before = take!;
      final id = const Uuid().v4();
      final shotId = before.parentId!;
      if (camera) {
        await repository.startCapture(
          shotId,
          slot,
          id,
          before.revision,
          destinationTakeId: before.id,
        );
        final file = await ImagePicker().pickImage(
          source: ImageSource.camera,
          requestFullMetadata: false,
        );
        if (file == null) {
          await repository.clearCapture();
          return;
        }
        recordEdit(before, await finishCapture(repository, file));
      } else {
        final file = await openFile(
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'Frame grab',
              extensions: ['jpg', 'jpeg', 'png'],
              uniformTypeIdentifiers: ['public.jpeg', 'public.png'],
            ),
          ],
        );
        if (file == null) return;
        if (await file.length() > 25 * 1024 * 1024) {
          throw const FormatException('Use a JPEG or PNG smaller than 25 MB.');
        }
        final frame = await compute(prepareFrame, await file.readAsBytes());
        final saved = await repository.attachFrame(
          shotId: shotId,
          slot: slot,
          assetId: id,
          frame: frame,
          expectedRevision: before.revision,
          destinationTakeId: before.id,
        );
        recordEdit(before, saved);
      }
    });
  }

  Future<void> recoverCapture() async {
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Pending Grab ${pending?['slot']}'),
        content: const Text(
          'Recover the image into this take or clear the pending destination.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Dismiss capture'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Recover'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    await run(() async {
      if (!choice) {
        await repository.clearCapture();
        return;
      }
      final before = take!;
      final current = await repository.get(before.id);
      if (current?.revision != before.revision) {
        throw StateError(
          'The take changed. Reopen Light Plan to recover this capture.',
        );
      }
      final message = await recoverPendingCapture(
        repository,
        acceptCurrentRevision: true,
      );
      final saved = await repository.get(before.id);
      if (saved != null && saved.revision != before.revision) {
        recordEdit(before, saved);
      }
      if (message != null) notice(message);
    });
  }

  Future<void> printTake() => run(() async {
    final current = take!;
    final label = lightRecordNumber(current) ?? '';
    final bytes = await exportShotPdf(
      current,
      grabs: previews,
      takeLabels: (
        scene: lightRecordNumber(selection?.scene) ?? '',
        shot: lightRecordNumber(selection?.shot) ?? '',
        take: label,
      ),
    );
    await shareExportBytes(
      bytes,
      extension: 'pdf',
      mime: 'application/pdf',
      subject: 'Light Plan • Take $label',
    );
  });

  Widget headerValue(EntityKind kind, ProductionRecord? record) {
    final choices = switch (kind) {
      EntityKind.scene => numbers.scenes,
      EntityKind.shot => numbers.shots,
      _ => numbers.takes,
    };
    return Expanded(
      child: LightNumberScroller(
        kind: kind,
        choices: choices,
        selected: record,
        generation: navigationGeneration,
        enabled: !busy && jumpParent(kind) != null,
        onJump: () => jump(kind),
        onSelect: selectNumber,
      ),
    );
  }

  Widget action(
    String name,
    IconData glyph,
    VoidCallback? callback, {
    bool small = false,
  }) => IconButton(
    constraints: const BoxConstraints.tightFor(
      width: CineTheme.touch,
      height: CineTheme.touch,
    ),
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.standard,
    tooltip: name,
    iconSize: small ? 18 : CineTheme.mediumGlyph,
    style: IconButton.styleFrom(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
    onPressed: busy ? null : callback,
    icon: Icon(glyph),
  );

  Widget header({required bool stacked}) {
    final identifiers = Row(
      children: [
        if (defaultTargetPlatform == TargetPlatform.iOS &&
            Navigator.of(context).canPop())
          action(
            'Back',
            Icons.arrow_back_ios_new,
            () => Navigator.maybePop(context),
          ),
        headerValue(EntityKind.scene, selection?.scene),
        headerValue(EntityKind.shot, selection?.shot),
        headerValue(EntityKind.take, take),
      ],
    );
    final openGoTo = selection == null ? null : goTo;
    final goToButton = MediaQuery.sizeOf(context).width < 350
        ? action('Go to', Icons.manage_search, openGoTo)
        : TextButton(
            onPressed: busy ? null : openGoTo,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, CineTheme.touch),
            ),
            child: const Text('Go to'),
          );
    final actions = Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        goToButton,
        action(
          'Print Data',
          Icons.print_outlined,
          take == null ? null : printTake,
        ),
        action(
          'Reset Take',
          Icons.restart_alt,
          take == null || pendingForTake ? null : reset,
        ),
        action(
          'Undo',
          Icons.undo,
          history.isEmpty || pendingForTake ? null : () => stepHistory(false),
        ),
        action(
          'Redo',
          Icons.redo,
          redoHistory.isEmpty || pendingForTake
              ? null
              : () => stepHistory(true),
        ),
        addButton(),
      ],
    );
    return Container(
      key: const ValueKey('light-plan-header'),
      decoration: CineTheme.panel(),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: stacked
          ? Column(
              children: [
                identifiers,
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            )
          : Row(
              children: [
                Expanded(child: identifiers),
                const SizedBox(height: 30, child: VerticalDivider(width: 12)),
                actions,
              ],
            ),
    );
  }

  Widget grabPanel(int slot, {required bool spacious}) {
    final preview = previews[slot];
    final hasImage = slots['$slot'] != null;
    final canCapture = take != null && pending == null;
    final recovering = pendingForTake && pending?['slot'] == slot;
    final expanded = openGrab == slot;
    final toggle = expanded
        ? 'Hide Grab $slot controls'
        : 'Show Grab $slot controls';
    final image = preview != null
        ? Image.memory(
            preview.preview,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          )
        : Center(
            child: hasImage
                ? const Text('Media unavailable', textAlign: TextAlign.center)
                : const Icon(Icons.image_outlined, color: CineTheme.olive),
          );
    return Container(
      decoration: CineTheme.panel(CineTheme.stone),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: recovering
                ? Center(
                    child: TextButton(
                      onPressed: busy ? null : recoverCapture,
                      child: Text('Recover Grab $slot capture'),
                    ),
                  )
                : Tooltip(
                    message: toggle,
                    excludeFromSemantics: true,
                    child: Semantics(
                      button: true,
                      label: toggle,
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          onTap: () =>
                              setState(() => openGrab = expanded ? null : slot),
                          child: image,
                        ),
                      ),
                    ),
                  ),
          ),
          if (expanded && !recovering)
            ColoredBox(
              color: CineTheme.chalk,
              child: Column(
                children: [
                  const Divider(height: 1),
                  Padding(
                    padding: EdgeInsets.only(top: spacious ? 6 : 2),
                    child: Text(
                      'GRAB $slot',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      action(
                        'Upload Grab $slot',
                        Icons.file_upload_outlined,
                        take == null || pendingForTake
                            ? null
                            : () => grab(slot, camera: false),
                        small: true,
                      ),
                      action(
                        'Camera Grab $slot',
                        Icons.photo_camera_outlined,
                        canCapture ? () => grab(slot, camera: true) : null,
                        small: true,
                      ),
                      action(
                        'Retake Grab $slot',
                        Icons.refresh,
                        canCapture && hasImage
                            ? () => grab(slot, camera: true, retake: true)
                            : null,
                        small: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget canvas() => Container(
    decoration: CineTheme.panel(),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: take == null
              ? Center(
                  child: Text(
                    busy
                        ? 'Opening workspace…'
                        : 'Use Add to start a light and camera plan.',
                  ),
                )
              : IgnorePointer(
                  ignoring: busy || pendingForTake,
                  child: PlanEditor(
                    key: ValueKey('${take!.id}:$canvasGeneration'),
                    repository: repository,
                    shot: take!,
                    onCanvasChanged: saveCanvas,
                  ),
                ),
        ),
        const Divider(height: 1),
        LightTakeSlider(
          key: ValueKey('slider-${take?.id}-$navigationGeneration'),
          choices: numbers.takes,
          selected: take,
          enabled: !busy,
          onSelect: selectNumber,
        ),
      ],
    ),
  );

  Widget addButton() => SizedBox.square(
    dimension: CineTheme.touch,
    child: FilledButton(
      style: FilledButton.styleFrom(padding: EdgeInsets.zero),
      onPressed: busy || selection == null || pendingForTake ? null : add,
      child: const Tooltip(
        message: 'Add',
        child: Icon(
          Icons.add,
          size: CineTheme.mediumGlyph,
          semanticLabel: 'Add',
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, bounds) {
            final stacked = bounds.maxWidth < CineTheme.compactWidth;
            final spacious =
                bounds.maxWidth >= CineTheme.tabletWidth &&
                bounds.maxHeight >= CineTheme.tabletHeight;
            final gutter = spacious ? CineTheme.wideGutter : 8.0;
            final gap = spacious ? CineTheme.gutter : 6.0;
            final largerText = MediaQuery.textScalerOf(context).scale(16) > 21;
            final headerStacked = stacked || largerText;
            final minimumHeight = headerStacked ? 420.0 : 322.0;
            final width = math.min(bounds.maxWidth - gutter * 2, 1600.0);
            return SingleChildScrollView(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(gutter),
                  child: SizedBox(
                    width: width,
                    height: stacked
                        ? null
                        : math.max(
                            minimumHeight,
                            bounds.maxHeight - gutter * 2,
                          ),
                    child: Column(
                      children: [
                        header(stacked: headerStacked),
                        SizedBox(height: gap),
                        Flexible(
                          flex: stacked ? 0 : 1,
                          fit: FlexFit.tight,
                          child: Flex(
                            direction: stacked
                                ? Axis.vertical
                                : Axis.horizontal,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Flexible(
                                flex: stacked ? 0 : 1,
                                fit: FlexFit.tight,
                                child: SizedBox(
                                  height: stacked ? 340 : null,
                                  child: canvas(),
                                ),
                              ),
                              SizedBox(
                                width: stacked ? 0 : gap,
                                height: stacked ? gap : 0,
                              ),
                              SizedBox(
                                width: stacked
                                    ? null
                                    : (width * .30).clamp(164.0, 420.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    for (final slot in [1, 2]) ...[
                                      Flexible(
                                        flex: stacked ? 0 : 1,
                                        fit: FlexFit.tight,
                                        child: SizedBox(
                                          height: stacked ? 186 : null,
                                          child: grabPanel(
                                            slot,
                                            spacious: spacious,
                                          ),
                                        ),
                                      ),
                                      if (slot == 1) SizedBox(height: gap),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

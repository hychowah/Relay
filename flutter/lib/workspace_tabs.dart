import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'split_layout.dart';
import 'tab_icon.dart';
import 'tab_memory.dart';
import 'workspace.dart';
import 'workspace_style.dart';

class WorkspaceTabs extends StatefulWidget {
  const WorkspaceTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelect,
    required this.onClose,
    this.split,
    this.draggable = false,
    this.onMove,
    this.onLeaveSplit,
    this.memory,
    this.hoverCard,
  });
  final List<WorkspaceTab> tabs;
  final WorkspaceTab? selected;
  final ValueChanged<WorkspaceTab> onSelect, onClose;

  /// The tabs in the shown split, marked on their own chips.
  final List<WorkspaceTab>? split;

  /// Desktop only: chips can be dragged along the strip to reorder the tabs
  /// and onto the page to split it.
  final bool draggable;

  /// Desktop only: a chip dropped on the strip moves its tab to [index].
  final void Function(WorkspaceTab tab, int index)? onMove;

  /// Desktop only: a tab of the shown split dragged off the strip, back and
  /// dropped there leaves the split instead of moving, and the other chips
  /// make no room for it on the way back. Dragged only along the strip, it
  /// moves and stays in the split.
  final ValueChanged<WorkspaceTab>? onLeaveSplit;

  /// Desktop only: while tab memory is shown, each page's figure.
  final MemoryReading? memory;

  /// Desktop only: the card shown while the pointer rests on an app's or a
  /// website's tab; [shown] says whether its page is on screen.
  final Widget Function(WorkspaceTab tab, bool shown)? hoverCard;

  @override
  State<WorkspaceTabs> createState() => _WorkspaceTabsState();
}

// Each chip is placed by position, so a tab that changes place slides there
// while the others make room; AnimatedList could only shrink and regrow it.
// Positions are in tab widths. Like a browser's, the tabs share the strip:
// full width while they fit, narrower as more open, and once they reach the
// narrowest the strip scrolls.
class _WorkspaceTabsState extends State<WorkspaceTabs>
    with SingleTickerProviderStateMixin {
  ColorScheme get colors => Theme.of(context).colorScheme;
  final _scroll = ScrollController();
  late final _motion = AnimationController(vsync: this, value: 1)
    ..addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      setState(() => _chips.removeWhere((chip) => chip.closing));
    });
  late final _chips = [
    for (final (index, tab) in widget.tabs.indexed)
      _Placed(tab, index.toDouble()),
  ];
  static const _widest = 196.0, _narrowest = 100.0;
  // Narrower than this, chips leave out the memory figure, and those not
  // selected their close button, so that what is left fits.
  static const _roomy = 140.0;
  // The width the open tabs share at the last layout, and the width shown
  // when the current motion started.
  double _width = _widest, _fromWidth = _widest;
  Curve _shift = Curves.easeOutCubic;
  // A tab moved to the left end travels slower than the others shift, and
  // both slower than other workspace motion, so the eye can follow the move.
  static const _travelTime = Duration(milliseconds: 600);
  static const _shiftTime = Duration(milliseconds: 350);

  final _strip = GlobalKey();
  // The chip pressed last and where on it, for the drag that may follow.
  _Placed? _pressed, _dragged;
  double _grab = 0;
  // The chip that follows the pointer while it is dragged along the strip,
  // and the place it would drop into.
  _Placed? _held;
  int _heldIndex = 0;
  // Whether the drag has left the strip; see [WorkspaceTabs.onLeaveSplit].
  bool _wentOut = false;
  // The drag's floating label hides while the chip itself follows.
  final _inStrip = ValueNotifier(false);

  double _widthAt(double t) =>
      lerpDouble(_fromWidth, _width, _shift.transform(t))!;

  @override
  void dispose() {
    _motion.dispose();
    _scroll.dispose();
    _inStrip.dispose();
    super.dispose();
  }

  /// Starts the chips towards their targets; every chip shifts on [shift].
  void _start(Duration total, Curve shift) {
    _shift = shift;
    for (final chip in _chips) {
      chip.shift = shift;
    }
    _motion.duration = total;
    _motion.forward(from: 0);
  }

  /// Moves every open chip towards its place in [order], from where it is
  /// shown now.
  void _arrange(List<WorkspaceTab> order) {
    final t = _motion.value;
    _fromWidth = _widthAt(t);
    final at = {for (final (index, tab) in order.indexed) tab.id: index};
    for (final chip in _chips) {
      chip.settle(t);
      if (!chip.closing) chip.toX = at[chip.tab.id]!.toDouble();
    }
    final duration = workspaceMotion(context);
    if (duration == Duration.zero) {
      _motion.value = 1;
    } else {
      _start(duration, Curves.easeOutCubic);
    }
  }

  List<WorkspaceTab> _orderWith(WorkspaceTab tab, int index) =>
      [...widget.tabs.where((other) => other != tab)]..insert(index, tab);

  bool _leavesSplit(WorkspaceTab tab) =>
      _wentOut && (widget.split?.contains(tab) ?? false);

  bool _hold(WorkspaceTab tab, Offset pointer) {
    final pressed = _pressed;
    if (pressed == null || pressed.tab != tab) return false;
    if (_leavesSplit(tab)) return true;
    _held = pressed..heldX = pressed.x(_motion.value);
    _heldIndex = widget.tabs.indexOf(tab);
    _inStrip.value = true;
    _follow(pointer);
    return true;
  }

  void _follow(Offset pointer) {
    final held = _held;
    final box = _strip.currentContext?.findRenderObject() as RenderBox?;
    if (held == null || box == null) return;
    final scrolled = _scroll.hasClients ? _scroll.offset : 0;
    final left = box.globalToLocal(pointer).dx + scrolled - _grab;
    final x = (left / _width).clamp(0.0, widget.tabs.length - 1.0);
    setState(() {
      held.heldX = x;
      if (x.round() == _heldIndex) return;
      _heldIndex = x.round();
      _arrange(_orderWith(held.tab, _heldIndex));
    });
  }

  /// Lets the held chip go to [index], from where it is shown.
  void _release(int index) {
    final held = _held!;
    setState(() {
      _arrange(_orderWith(held.tab, index));
      held.heldX = null;
      _held = null;
    });
    _inStrip.value = false;
  }

  void _drop(WorkspaceTab tab) {
    if (_leavesSplit(tab)) return widget.onLeaveSplit?.call(tab);
    if (_held?.tab != tab) return;
    final index = _heldIndex;
    _release(index);
    if (index != widget.tabs.indexOf(tab)) widget.onMove?.call(tab, index);
  }

  void _leave() {
    _wentOut = true;
    if (_held case final held?) _release(widget.tabs.indexOf(held.tab));
    _inStrip.value = false;
  }

  @override
  void didUpdateWidget(WorkspaceTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = [for (final tab in oldWidget.tabs) tab.id];
    final newIds = [for (final tab in widget.tabs) tab.id];
    final placed = {
      for (final chip in _chips)
        if (!chip.closing) chip.tab.id: chip,
    };
    // A drop has already sent every chip towards its new place.
    final placedByDrop =
        placed.length == newIds.length &&
        newIds.indexed.every((entry) => placed[entry.$2]?.toX == entry.$1);
    if (listEquals(oldIds, newIds) || placedByDrop) {
      // An app opened in a blank tab keeps the blank tab's id.
      for (final tab in widget.tabs) {
        placed[tab.id]!.tab = tab;
      }
    } else {
      _fromWidth = _widthAt(_motion.value);
      for (final chip in _chips) {
        chip.settle(_motion.value);
        if (!newIds.contains(chip.tab.id)) chip.closing = true;
      }
      // Tabs that open or close during a drag end it in place.
      _held?.heldX = null;
      _held = null;
      for (final (index, tab) in widget.tabs.indexed) {
        final x = index.toDouble();
        final chip = placed[tab.id];
        if (chip == null) {
          _chips.add(_Placed(tab, x, size: 0));
        } else {
          chip
            ..tab = tab
            ..toX = x;
        }
      }
      final duration = workspaceMotion(context);
      if (duration == Duration.zero) {
        _motion.value = 1;
        _chips.removeWhere((chip) => chip.closing);
      } else {
        // Besides a drop, the only reorder brings one tab to the left end
        // past others.
        final kept = [
          for (final id in oldIds)
            if (newIds.contains(id)) id,
        ];
        final mover = kept.isNotEmpty && kept.first != newIds.first
            ? placed[newIds.first]
            : null;
        mover?.lifted = true;
        final total = mover == null ? duration : _travelTime;
        final shift = Interval(
          0,
          (mover == null ? duration : _shiftTime).inMicroseconds /
              total.inMicroseconds,
          curve: Curves.easeOutCubic,
        );
        _start(total, shift);
      }
    }
    final selected = widget.selected;
    if (selected == null) return;
    final index = widget.tabs.indexOf(selected);
    final oldIndex = oldIds.indexOf(selected.id);
    // A tab opened at either end, new or moved there, is scrolled into view.
    final toEnd = index == widget.tabs.length - 1 && oldIndex == -1;
    final toStart = index == 0 && oldIndex != 0;
    if (!toEnd && !toStart) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      // Include the growing chip, whose full extent is not laid out yet.
      final target = toStart
          ? 0.0
          : widget.tabs.length * _width - position.viewportDimension;
      if (toStart ? position.pixels <= 0 : target <= position.pixels) return;
      final duration = workspaceMotion(context);
      if (duration == Duration.zero) {
        _scroll.jumpTo(target);
      } else {
        _scroll.animateTo(
          target,
          duration: duration,
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedId = widget.selected?.id;
    // Closing chips sit underneath and the selected and moving chips on top,
    // so a chip sliding past the others stays readable.
    int layer(_Placed chip) => chip.closing
        ? 0
        : chip.lifted || chip.lift(_motion.value) > 0
        ? 3
        : chip.tab.id == selectedId
        ? 2
        : 1;
    final ordered = [
      for (final level in [0, 1, 2, 3])
        ..._chips.where((c) => layer(c) == level),
    ];
    final strip = LayoutBuilder(
      key: _strip,
      builder: (context, constraints) {
        _width = widget.tabs.isEmpty
            ? _widest
            : (constraints.maxWidth / widget.tabs.length).clamp(
                _narrowest,
                _widest,
              );
        final roomy = _width >= _roomy;
        final children = {
          for (final placed in ordered)
            placed: _placedChip(placed, selectedId, roomy: roomy),
        };
        return SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          child: AnimatedBuilder(
            animation: _motion,
            builder: (context, _) {
              final t = _motion.value;
              final tabWidth = _widthAt(t);
              var width = 0.0;
              for (final chip in _chips) {
                width = math.max(width, (chip.x(t) + chip.size(t)) * tabWidth);
              }
              return SizedBox(
                width: width,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final MapEntry(key: chip, value: child)
                        in children.entries)
                      Positioned(
                        key: ValueKey(chip),
                        left: chip.x(t) * tabWidth,
                        top: 0,
                        bottom: 0,
                        // Only a growing or closing chip is clipped, so a
                        // lifted chip's scale and shadow show.
                        child: ClipRect(
                          clipBehavior: chip.size(t) < 1
                              ? Clip.hardEdge
                              : Clip.none,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            widthFactor: chip.size(t),
                            child: Opacity(
                              opacity: chip.size(t),
                              child: SizedBox(width: tabWidth, child: child),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
    if (!widget.draggable) return strip;
    return DragTarget<WorkspaceTab>(
      onWillAcceptWithDetails: (details) => _hold(details.data, details.offset),
      onMove: (details) => _follow(details.offset),
      onAcceptWithDetails: (details) => _drop(details.data),
      onLeave: (_) => _leave(),
      builder: (context, _, _) => strip,
    );
  }

  Widget _placedChip(
    _Placed placed,
    String? selectedId, {
    required bool roomy,
  }) {
    final tab = placed.tab;
    final selected = tab.id == selectedId;
    if (placed.closing) {
      return ExcludeSemantics(
        child: ExcludeFocus(
          child: IgnorePointer(
            child: _chip(placed, selected: selected, roomy: roomy),
          ),
        ),
      );
    }
    final chip = _chip(
      placed,
      selected: selected,
      roomy: roomy,
      inSplit: widget.split?.contains(tab) ?? false,
      onSelect: () => widget.onSelect(tab),
      onClose: () => widget.onClose(tab),
    );
    if (!widget.draggable) return chip;
    return _TabDraggable(
      data: tab,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: () => setState(() => _dragged = placed),
      onDragEnd: (_) => setState(() => _dragged = null),
      feedback: ValueListenableBuilder(
        valueListenable: _inStrip,
        builder: (context, inStrip, label) =>
            inStrip ? const SizedBox.shrink() : label!,
        child: Transform.translate(
          offset: const Offset(-24, -18),
          child: Material(
            elevation: 6,
            color: colors.surface,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Text(
                tab.title,
                style: TextStyle(fontSize: 12, color: colors.onSurface),
              ),
            ),
          ),
        ),
      ),
      child: Listener(
        onPointerDown: (event) {
          _pressed = placed;
          _grab = event.localPosition.dx;
          _wentOut = false;
        },
        // Over the page the chip stays faded in its place.
        child: Opacity(
          opacity: _dragged == placed && _held != placed ? .5 : 1,
          child: chip,
        ),
      ),
    );
  }

  /// While a tab travels to the left end its chip is lifted: slightly larger,
  /// with a shadow and an accent outline that fade as it lands.
  Widget _lift(_Placed placed, Widget chip) => AnimatedBuilder(
    animation: _motion,
    child: chip,
    builder: (context, chip) {
      final lift = placed.lift(_motion.value);
      final shape = BorderRadius.circular(8);
      // The same widgets with empty decorations when at rest, so the chip
      // keeps its state, such as a drag, as the lift starts and ends.
      return Transform.scale(
        scale: 1 + .05 * lift,
        child: DecoratedBox(
          decoration: lift == 0
              ? const BoxDecoration()
              : BoxDecoration(
                  color: colors.surface.withValues(alpha: lift),
                  borderRadius: shape,
                  boxShadow: [
                    BoxShadow(
                      color: colors.shadow.withValues(alpha: .25 * lift),
                      blurRadius: 10 * lift,
                      offset: Offset(0, 3 * lift),
                    ),
                    BoxShadow(
                      color: colors.primary.withValues(alpha: .3 * lift),
                      blurRadius: 8 * lift,
                    ),
                  ],
                ),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: lift == 0
                ? const BoxDecoration()
                : BoxDecoration(
                    borderRadius: shape,
                    border: Border.all(
                      color: colors.primary.withValues(alpha: lift),
                      width: 1.5,
                    ),
                  ),
            child: chip,
          ),
        ),
      );
    },
  );

  /// Wraps an app's or a website's chip in its hover card when [enabled].
  Widget _withCard(
    WorkspaceTab tab,
    Widget chip, {
    required bool shown,
    required bool enabled,
  }) {
    final card = widget.hoverCard;
    if (card == null || !enabled || tab is SplitTab || tab.appId == null) {
      return chip;
    }
    return Tooltip(
      // The chip already says its title; the card is for the pointer.
      excludeFromSemantics: true,
      richMessage: WidgetSpan(child: card(tab, shown)),
      waitDuration: const Duration(milliseconds: 500),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
        boxShadow: const [BoxShadow(blurRadius: 12, color: Color(0x33000000))],
      ),
      child: chip,
    );
  }

  Widget _chip(
    _Placed placed, {
    required bool selected,
    required bool roomy,
    bool inSplit = false,
    VoidCallback? onSelect,
    VoidCallback? onClose,
  }) {
    final tab = placed.tab;
    final closable = roomy || selected;
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(right: 5),
        child: _lift(
          placed,
          Material(
            // A split tab keeps an accent outline and tint, so it never
            // looks like an app tab.
            color: selected
                ? colors.surface
                : tab is SplitTab
                ? colors.primary.withValues(alpha: .07)
                : inSplit
                ? colors.primaryContainer
                : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: tab is SplitTab
                  ? BorderSide(
                      color: colors.primary.withValues(
                        alpha: selected ? .9 : .45,
                      ),
                      width: selected ? 1.5 : 1,
                    )
                  : BorderSide(
                      color: selected ? colors.outline : Colors.transparent,
                    ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _withCard(
                    tab,
                    shown: selected || inSplit,
                    enabled: onSelect != null,
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: onSelect,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          10,
                          9,
                          closable ? 6 : 10,
                          9,
                        ),
                        child: Row(
                          children: [
                            if (tab is SplitTab)
                              _SplitMap(tab, color: colors.primary)
                            else
                              TabIcon(tab, size: 15, selected: selected),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                tab.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: tab is SplitTab
                                      ? colors.primary
                                      : selected
                                      ? colors.onSurface
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                            if (widget.memory?.pages[tab.page] case final use?
                                when roomy)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Text(
                                  memoryText(use.bytes),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            if (inSplit)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Icon(
                                  Icons.vertical_split,
                                  size: 13,
                                  color: colors.primary,
                                  semanticLabel: 'Split view',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (closable)
                  IconButton(
                    tooltip: 'Close ${tab.title}',
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 14),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small drawing of a split tab's panes as they are arranged, with the pane
/// selected last filled in.
class _SplitMap extends StatelessWidget {
  const _SplitMap(this.split, {required this.color});
  final SplitTab split;
  final Color color;

  Widget _draw(SplitLayout layout) => switch (layout) {
    SplitPane(:final tab) => DecoratedBox(
      key: ValueKey('split-map-${tab.id}'),
      decoration: BoxDecoration(
        color: tab == split.focus ? color : null,
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(1.5),
      ),
    ),
    SplitBranch(:final axis, :final first, :final second, :final fraction) =>
      Flex(
        direction: axis,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: (fraction * 100).round().clamp(1, 99),
            child: _draw(first),
          ),
          const SizedBox.square(dimension: 1.5),
          Expanded(
            flex: 100 - (fraction * 100).round().clamp(1, 99),
            child: _draw(second),
          ),
        ],
      ),
  };

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Split of ${split.layout.tabs.length} tabs',
    child: SizedBox(width: 20, height: 14, child: _draw(split.layout)),
  );
}

/// A chip's place in the strip, in tab widths, moving from where it was shown
/// towards its target as the strip's motion runs. A closing chip stays in
/// place while it shrinks and fades.
class _Placed {
  _Placed(this.tab, this.toX, {double size = 1}) : fromX = toX, fromSize = size;
  WorkspaceTab tab;
  double fromX, toX, fromSize, fromLift = 0;
  bool closing = false;

  /// The tab moving to the left end, which travels lifted on its own timing.
  bool lifted = false;

  /// While the chip is dragged along the strip, its place under the pointer;
  /// it is lifted there.
  double? heldX;

  /// The timing of every other change in the current motion.
  Curve shift = Curves.easeOutCubic;
  double get toSize => closing ? 0 : 1;

  double x(double t) {
    if (heldX case final held?) return held;
    if (!lifted) return lerpDouble(fromX, toX, shift.transform(t))!;
    // It reaches its place at three quarters of the motion, runs a few pixels
    // past and settles back, which reads as landing.
    final arrive = Curves.easeOutCubic.transform(math.min(1, t / .75));
    final past = math.min(.04, (toX - fromX).abs() * .05) * (toX - fromX).sign;
    final bounce = math.sin(math.pi * ((t - .55) / .45).clamp(0, 1));
    return lerpDouble(fromX, toX, arrive)! + past * bounce;
  }

  double size(double t) => lerpDouble(fromSize, toSize, shift.transform(t))!;

  /// Rises quickly as the chip leaves and fades as it lands.
  double lift(double t) {
    if (heldX != null) return 1;
    if (!lifted) return fromLift * (1 - shift.transform(t));
    if (t < .15) return Curves.easeOut.transform(t / .15);
    return 1 - Curves.easeInOut.transform(((t - .45) / .45).clamp(0, 1));
  }

  /// Starts the next motion from where the chip is shown now.
  void settle(double t) {
    fromSize = size(t);
    fromLift = lift(t);
    fromX = toX = x(t);
    lifted = false;
  }
}

// A mouse drag normally starts after one pixel, which turned slight movement
// during a click into a drag and lost the tab selection.
class _TabDraggable extends Draggable<WorkspaceTab> {
  const _TabDraggable({
    required super.child,
    required super.feedback,
    super.data,
    super.dragAnchorStrategy,
    super.onDragStarted,
    super.onDragEnd,
  });
  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => _TabDragRecognizer()..onStart = onStart;
}

class _TabDragRecognizer extends ImmediateMultiDragGestureRecognizer {
  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _TabDragState(event.position, event.kind, gestureSettings);
}

class _TabDragState extends MultiDragPointerState {
  _TabDragState(super.initialPosition, super.kind, super.gestureSettings);
  @override
  void checkForResolutionAfterMove() {
    if (pendingDelta!.distance > kTouchSlop) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) =>
      starter(initialPosition);
}

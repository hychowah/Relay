import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

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
  });
  final List<WorkspaceTab> tabs;
  final WorkspaceTab? selected;
  final ValueChanged<WorkspaceTab> onSelect, onClose;
  final List<WorkspaceTab>? split;

  /// Desktop only: chips can be dragged onto the page to split it.
  final bool draggable;

  @override
  State<WorkspaceTabs> createState() => _WorkspaceTabsState();
}

// Each chip is placed by position, so a tab that changes place slides there
// while the others make room; AnimatedList could only shrink and regrow it.
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
      _Placed(tab, index * _tabWidth),
  ];
  static const _tabWidth = 196.0;
  double get _t => Curves.easeOutCubic.transform(_motion.value);

  @override
  void dispose() {
    _motion.dispose();
    _scroll.dispose();
    super.dispose();
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
    if (listEquals(oldIds, newIds)) {
      // An app opened in a blank tab keeps the blank tab's id.
      for (final tab in widget.tabs) {
        placed[tab.id]!.tab = tab;
      }
    } else {
      final t = _t;
      for (final chip in _chips) {
        chip.settle(t);
        if (!newIds.contains(chip.tab.id)) chip.closing = true;
      }
      for (final (index, tab) in widget.tabs.indexed) {
        final x = index * _tabWidth;
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
        _motion.duration = duration;
        _motion.forward(from: 0);
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
          : widget.tabs.length * _tabWidth - position.viewportDimension;
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
    // Closing chips sit underneath and the selected chip on top, so a chip
    // sliding past the others stays readable.
    final ordered = [
      ..._chips.where((chip) => chip.closing),
      ..._chips.where((chip) => !chip.closing && chip.tab.id != selectedId),
      ..._chips.where((chip) => !chip.closing && chip.tab.id == selectedId),
    ];
    final children = {
      for (final placed in ordered) placed: _placedChip(placed, selectedId),
    };
    return SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      child: AnimatedBuilder(
        animation: _motion,
        builder: (context, _) {
          final t = _t;
          var width = 0.0;
          for (final chip in _chips) {
            width = math.max(width, chip.x(t) + chip.size(t) * _tabWidth);
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
                    left: chip.x(t),
                    top: 0,
                    bottom: 0,
                    child: ClipRect(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: chip.size(t),
                        child: Opacity(
                          opacity: chip.size(t),
                          child: SizedBox(width: _tabWidth, child: child),
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
  }

  Widget _placedChip(_Placed placed, String? selectedId) {
    final tab = placed.tab;
    if (placed.closing) {
      return ExcludeSemantics(
        child: ExcludeFocus(
          child: IgnorePointer(
            child: _chip(tab, selected: tab.id == selectedId),
          ),
        ),
      );
    }
    final chip = _chip(
      tab,
      selected: tab.id == selectedId,
      paired: widget.split?.contains(tab) ?? false,
      onSelect: () => widget.onSelect(tab),
      onClose: () => widget.onClose(tab),
    );
    if (!widget.draggable) return chip;
    return _TabDraggable(
      data: tab,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Transform.translate(
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
      childWhenDragging: Opacity(opacity: .5, child: chip),
      child: chip,
    );
  }

  Widget _chip(
    WorkspaceTab tab, {
    required bool selected,
    bool paired = false,
    VoidCallback? onSelect,
    VoidCallback? onClose,
  }) => Center(
    child: SizedBox(
      width: _tabWidth,
      child: Padding(
        padding: const EdgeInsets.only(right: 5),
        child: Material(
          color: selected
              ? colors.surface
              : paired
              ? colors.primaryContainer
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: selected ? colors.outline : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: onSelect,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 9, 6, 9),
                    child: Row(
                      children: [
                        Icon(
                          tab.isBrowser
                              ? Icons.language
                              : tab.appId == null
                              ? Icons.add
                              : Icons.grid_view_rounded,
                          size: 15,
                          color: selected
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tab.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: selected
                                  ? colors.onSurface
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (paired)
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

/// A chip's place in the strip, moving from where it was shown towards its
/// target as the strip's motion runs. A closing chip stays in place while it
/// shrinks and fades.
class _Placed {
  _Placed(this.tab, this.toX, {double size = 1}) : fromX = toX, fromSize = size;
  WorkspaceTab tab;
  double fromX, toX, fromSize;
  bool closing = false;
  double get toSize => closing ? 0 : 1;
  double x(double t) => lerpDouble(fromX, toX, t)!;
  double size(double t) => lerpDouble(fromSize, toSize, t)!;

  /// Starts the next motion from where the chip is shown now.
  void settle(double t) {
    fromSize = size(t);
    fromX = toX = x(t);
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
    super.childWhenDragging,
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

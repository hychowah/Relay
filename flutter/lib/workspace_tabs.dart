import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'workspace.dart';
import 'split_layout.dart';
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

  /// The tabs in the shown split, marked on their own chips.
  final List<WorkspaceTab>? split;

  /// Desktop only: chips can be dragged onto the page to split it.
  final bool draggable;

  @override
  State<WorkspaceTabs> createState() => _WorkspaceTabsState();
}

class _WorkspaceTabsState extends State<WorkspaceTabs> {
  ColorScheme get colors => Theme.of(context).colorScheme;
  final _list = GlobalKey<AnimatedListState>();
  final _scroll = ScrollController();
  static const _tabWidth = 196.0;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(WorkspaceTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = oldWidget.tabs.map((tab) => tab.id).toSet();
    final newIds = widget.tabs.map((tab) => tab.id).toSet();
    final duration = workspaceMotion(context);
    for (var i = oldWidget.tabs.length - 1; i >= 0; i--) {
      final tab = oldWidget.tabs[i];
      if (newIds.contains(tab.id)) continue;
      final chip = _chip(tab, selected: oldWidget.selected == tab);
      _list.currentState!.removeItem(
        i,
        (context, animation) => ExcludeSemantics(
          child: ExcludeFocus(
            child: IgnorePointer(child: _transition(animation, chip)),
          ),
        ),
        duration: duration,
      );
    }
    for (var i = 0; i < widget.tabs.length; i++) {
      if (!oldIds.contains(widget.tabs[i].id)) {
        _list.currentState!.insertItem(i, duration: duration);
      }
    }
    if (widget.tabs.isNotEmpty &&
        widget.selected == widget.tabs.last &&
        !oldIds.contains(widget.selected!.id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final position = _scroll.position;
        // Include the growing chip, whose full extent is not laid out yet.
        final end = widget.tabs.length * _tabWidth - position.viewportDimension;
        if (end <= position.pixels) return;
        if (duration == Duration.zero) {
          _scroll.jumpTo(end);
        } else {
          _scroll.animateTo(
            end,
            duration: duration,
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  Widget _transition(Animation<double> animation, Widget chip) {
    final reveal = animation.drive(CurveTween(curve: Curves.easeOutCubic));
    return SizeTransition(
      axis: Axis.horizontal,
      sizeFactor: reveal,
      alignment: Alignment.centerLeft,
      child: FadeTransition(opacity: reveal, child: chip),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedList(
    key: _list,
    controller: _scroll,
    scrollDirection: Axis.horizontal,
    initialItemCount: widget.tabs.length,
    padding: EdgeInsets.zero,
    itemBuilder: (context, index, animation) {
      final tab = widget.tabs[index];
      final chip = _chip(
        tab,
        selected: widget.selected == tab,
        inSplit: widget.split?.contains(tab) ?? false,
        onSelect: () => widget.onSelect(tab),
        onClose: () => widget.onClose(tab),
      );
      return _transition(
        animation,
        widget.draggable && tab is! SplitTab
            ? _TabDraggable(
                data: tab,
                dragAnchorStrategy: pointerDragAnchorStrategy,
                feedback: Transform.translate(
                  offset: const Offset(-24, -18),
                  child: Material(
                    elevation: 6,
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      child: Text(
                        tab.title,
                        style: TextStyle(fontSize: 12, color: colors.onSurface),
                      ),
                    ),
                  ),
                ),
                childWhenDragging: Opacity(opacity: .5, child: chip),
                child: chip,
              )
            : chip,
      );
    },
  );

  Widget _chip(
    WorkspaceTab tab, {
    required bool selected,
    bool inSplit = false,
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
              : inSplit
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
                          tab is SplitTab
                              ? Icons.space_dashboard_outlined
                              : tab.isBrowser
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

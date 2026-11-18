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
  });
  final List<WorkspaceTab> tabs;
  final WorkspaceTab? selected;
  final ValueChanged<WorkspaceTab> onSelect, onClose;

  @override
  State<WorkspaceTabs> createState() => _WorkspaceTabsState();
}

class _WorkspaceTabsState extends State<WorkspaceTabs> {
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
      return _transition(
        animation,
        _chip(
          tab,
          selected: widget.selected == tab,
          onSelect: () => widget.onSelect(tab),
          onClose: () => widget.onClose(tab),
        ),
      );
    },
  );

  Widget _chip(
    WorkspaceTab tab, {
    required bool selected,
    VoidCallback? onSelect,
    VoidCallback? onClose,
  }) => Center(
    child: SizedBox(
      width: _tabWidth,
      child: Padding(
        padding: const EdgeInsets.only(right: 5),
        child: Material(
          color: selected ? Colors.white : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: selected ? line : Colors.transparent),
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
                          color: selected ? accent : muted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tab.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: selected ? ink : muted,
                            ),
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

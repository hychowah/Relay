import 'package:material_ui/material_ui.dart';

import 'address_bar.dart';
import 'area_capture.dart';
import 'chat_dock.dart';
import 'conversation_view.dart';
import 'new_tab_page.dart';
import 'region_capture.dart';
import 'relay_records.dart';
import 'split_layout.dart';
import 'window_capture.dart';
import 'workspace.dart';

/// Every tab's page in one keyed slot of one stack, so showing it alone, in a
/// split pane or hidden only moves it and never recreates its native view.
/// [onResized] runs on each step of a divider drag so the tab strip's map
/// follows; the workspace hears only the drag's end.
class PageStack extends StatefulWidget {
  const PageStack(
    this.workspace,
    this.desktop,
    this.address,
    this.capture,
    this.layout,
    this.onChoose,
    this.onServers,
    this.onResized, {
    super.key,
  });
  final Workspace workspace;

  /// Split panes and drop zones show only in a wide workspace.
  final bool desktop;
  final AddressInput address;
  final AreaCapture capture;

  /// A tab dropped on a pane shows the page again, ending chat only.
  final ChatLayout layout;

  /// Opens the app chosen on a new tab page.
  final Future<void> Function(WorkspaceApp) onChoose;

  /// Opens the App servers screen for an app tab that could not load.
  final VoidCallback onServers;
  final VoidCallback onResized;
  @override
  State<PageStack> createState() => _PageStackState();
}

class _PageStackState extends State<PageStack> {
  ColorScheme get colors => Theme.of(context).colorScheme;
  Workspace get w => widget.workspace;

  /// The pane a tab is being dragged over and the side it would take.
  (WorkspaceTab, SplitSide)? dropping;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, area) => _pages(area.biggest, widget.desktop),
  );

  Widget _pages(Size size, bool desktop) {
    final split = desktop ? w.shownSplit?.layout : null;
    final area = Offset.zero & size;
    final rects = <WorkspaceTab, Rect>{};
    final dividers = <(SplitBranch, Rect, Rect)>[];
    if (split != null) {
      split.layOut(
        area,
        pane: (tab, rect) => rects[tab] = rect,
        divider: (branch, area, line) => dividers.add((branch, area, line)),
      );
    } else if (w.active case final tab?) {
      rects[tab] = area;
    }
    final shown = rects.keys.toList();
    Widget pane(WorkspaceTab tab, Widget child, {Key? key}) =>
        Positioned.fromRect(key: key, rect: rects[tab] ?? area, child: child);

    final frame = split == null ? 0.0 : 2.0;
    // A Browser tab's bar sits at the top of its own pane, so selecting
    // another pane never moves a page. A page in fullscreen fills its pane.
    double bar(WorkspaceTab tab) =>
        tab.isBrowser && tab.page?.browser?.fullScreen != true
        ? BrowserBar.height
        : 0;
    // What shows in place of the page, such as its error, starts below it.
    Widget below(WorkspaceTab tab, Widget child, {Key? key}) {
      final rect = rects[tab] ?? area;
      final top = bar(tab) == 0 ? 0.0 : frame + bar(tab);
      return Positioned.fromRect(
        key: key,
        rect: Rect.fromLTRB(rect.left, rect.top + top, rect.right, rect.bottom),
        child: child,
      );
    }

    // A tab dropped on a pane takes the side whose edge is nearest.
    Widget dropZone(WorkspaceTab target) => pane(
      target,
      Builder(
        builder: (zone) {
          SplitSide side(Offset global) {
            final box = zone.findRenderObject()! as RenderBox;
            return SplitSide.nearest(box.globalToLocal(global), box.size);
          }

          return DragTarget<WorkspaceTab>(
            onWillAcceptWithDetails: (details) =>
                details.data != target && details.data is! SplitTab,
            onMove: (details) {
              final next = (target, side(details.offset));
              if (dropping != next) setState(() => dropping = next);
            },
            onLeave: (_) {
              if (dropping?.$1 == target) setState(() => dropping = null);
            },
            onAcceptWithDetails: (details) {
              setState(() {
                dropping = null;
                widget.layout.showPage();
              });
              w.dropInSplit(details.data, target, side(details.offset));
            },
            builder: (context, candidates, _) {
              final hover = dropping;
              if (candidates.isEmpty || hover == null || hover.$1 != target) {
                return const SizedBox.expand();
              }
              final at = hover.$2;
              return Align(
                alignment: switch (at) {
                  SplitSide.left => Alignment.centerLeft,
                  SplitSide.right => Alignment.centerRight,
                  SplitSide.top => Alignment.topCenter,
                  SplitSide.bottom => Alignment.bottomCenter,
                },
                child: FractionallySizedBox(
                  widthFactor: at.axis == Axis.horizontal ? .5 : 1,
                  heightFactor: at.axis == Axis.vertical ? .5 : 1,
                  child: DecoratedBox(
                    key: ValueKey('drop-${at.name}'),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: .12),
                      border: Border.all(color: colors.primary, width: 2),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );

    return Stack(
      children: [
        for (final tab in w.tabs)
          if (tab.page != null)
            pane(
              tab,
              key: ValueKey(tab.id),
              // The selected pane's outline is a frame around its bar and
              // page, never a drawing over the page: anything painted over a
              // native page takes its mouse on macOS. Both panes keep the
              // frame, so selecting only changes a colour and never resizes
              // a page.
              Builder(
                builder: (context) {
                  final edge = ColoredBox(
                    color: split != null && w.active == tab
                        ? colors.primary.withValues(alpha: .45)
                        : Colors.transparent,
                  );
                  return Stack(
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: frame,
                        child: edge,
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: frame,
                        child: edge,
                      ),
                      Positioned(
                        left: 0,
                        top: frame,
                        bottom: frame,
                        width: frame,
                        child: edge,
                      ),
                      Positioned(
                        right: 0,
                        top: frame,
                        bottom: frame,
                        width: frame,
                        child: edge,
                      ),
                      Positioned.fill(
                        left: frame,
                        top: frame + bar(tab),
                        right: frame,
                        bottom: frame,
                        child: Offstage(
                          offstage: !rects.containsKey(tab),
                          child: PageSlot(page: tab.page!),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
        if (w.active == null)
          Positioned.fill(
            child: NewTabPage(
              apps: w.allowedApps,
              onChoose: widget.onChoose,
              onShow: w.refreshApps,
              devices: w.otherDevices,
              onOpenDevice: w.openDeviceTabs,
            ),
          ),
        for (final tab in shown) ...[
          if (widget.capture.pickingOn(tab) case final image?)
            below(
              tab,
              RegionCapture(
                key: ValueKey(image),
                image: image,
                onDone: widget.capture.finish,
              ),
            ),
          if (tab.appId == null)
            pane(
              tab,
              key: ValueKey('new-${tab.id}'),
              NewTabPage(
                apps: w.allowedApps,
                onChoose: widget.onChoose,
                onShow: w.refreshApps,
                devices: w.otherDevices,
                onOpenDevice: w.openDeviceTabs,
              ),
            ),
          if (tab.report != null && (tab.page == null || tab.error != null))
            below(
              tab,
              key: ValueKey('report-${tab.id}'),
              SavedReport(
                report: tab.report!,
                error: tab.error,
                onServers: tab.isBrowser ? null : widget.onServers,
              ),
            ),
          if (tab.error != null && tab.report == null)
            below(
              tab,
              key: ValueKey('error-${tab.id}'),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 16,
                  children: [
                    Text(tab.error!),
                    // The app's server may be stopped.
                    if (!tab.isBrowser)
                      OutlinedButton.icon(
                        onPressed: widget.onServers,
                        icon: const Icon(Icons.dns_outlined),
                        label: const Text('App servers'),
                      ),
                  ],
                ),
              ),
            ),
          if (tab.appId != null &&
              tab.page == null &&
              tab.report == null &&
              tab.error == null)
            below(
              tab,
              key: ValueKey('loading-${tab.id}'),
              const Center(child: CircularProgressIndicator()),
            ),
          // The selected tab's bar keeps one key as the selection moves
          // between panes, so its address field, with the shared controller
          // and focus, is never built twice.
          if (bar(tab) > 0)
            Positioned.fromRect(
              key: ValueKey(w.active == tab ? 'address-bar' : 'bar-${tab.id}'),
              rect: Rect.fromLTWH(
                rects[tab]!.left + frame,
                rects[tab]!.top + frame,
                rects[tab]!.width - 2 * frame,
                bar(tab),
              ),
              // Only the mouse is stopped by the tint, so the keyboard is
              // kept out too: these buttons act on the selected tab.
              child: ExcludeFocus(
                excluding: w.active != tab,
                child: BrowserBar(w, tab, widget.address),
              ),
            ),
          // The other pane's tint is painted over its page on purpose: on
          // macOS a native page loses the mouse wherever Flutter paints over
          // it, so one click there selects the pane.
          if (split != null && w.active != tab)
            pane(
              tab,
              key: ValueKey('pane-${tab.id}'),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) {
                  w.recorder.action('select tab', {'tab': tab.title});
                  w.select(tab);
                },
                child: ColoredBox(
                  color: colors.onSurface.withValues(alpha: .04),
                ),
              ),
            ),
        ],
        for (final (index, (branch, area, line)) in dividers.indexed)
          Positioned.fromRect(
            key: ValueKey('split-divider-$index'),
            rect: line,
            child: _divider(branch, area),
          ),
        if (desktop) ...[for (final tab in shown) dropZone(tab)],
      ],
    );
  }

  Widget _divider(SplitBranch branch, Rect area) {
    final horizontal = branch.axis == Axis.horizontal;
    void drag(DragUpdateDetails details) {
      if (horizontal) {
        branch.resize(details.delta.dx, area.width);
      } else {
        branch.resize(details.delta.dy, area.height);
      }
      widget.onResized();
    }

    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: horizontal ? drag : null,
        onHorizontalDragEnd: horizontal ? (_) => w.changed() : null,
        onVerticalDragUpdate: horizontal ? null : drag,
        onVerticalDragEnd: horizontal ? null : (_) => w.changed(),
        onDoubleTap: () {
          branch.fraction = .5;
          w.changed();
        },
        child: ColoredBox(color: colors.outline),
      ),
    );
  }
}

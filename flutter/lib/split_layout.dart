import 'package:flutter/painting.dart';

import 'workspace.dart';

/// The side of a pane that a dropped tab takes.
enum SplitSide {
  left(Axis.horizontal, true),
  right(Axis.horizontal, false),
  top(Axis.vertical, true),
  bottom(Axis.vertical, false);

  const SplitSide(this.axis, this.before);
  final Axis axis;

  /// Whether the new pane comes first: left of or above the old one.
  final bool before;

  /// The side whose edge is nearest to [point] in a pane of [size], or null
  /// in the pane's middle, a quarter or more from every edge, where a dropped
  /// tab takes the pane itself.
  static SplitSide? nearest(Offset point, Size size) {
    final x = point.dx / size.width, y = point.dy / size.height;
    final distances = {left: x, right: 1 - x, top: y, bottom: 1 - y};
    final near = distances.entries.reduce((a, b) => b.value < a.value ? b : a);
    return near.value < .25 ? near.key : null;
  }
}

/// A tab that shows other tabs in split panes. Closing it ends only the split;
/// its tabs stay open and each shows alone when its own tab is clicked.
class SplitTab extends WorkspaceTab {
  SplitTab() : super(name: 'Split');
  late SplitBranch layout;

  /// The pane selected last, which is selected again when the split shows.
  late WorkspaceTab focus;

  @override
  String get title => layout.tabs.map((tab) => tab.title).join(' + ');
}

/// Desktop split view: tabs tiled in panes. Each split divides one pane in
/// two, side by side or one above the other, so any number of panes can be
/// made by dragging without choosing a grid first.
sealed class SplitLayout {
  List<WorkspaceTab> get tabs;
  bool contains(WorkspaceTab? tab) => tabs.contains(tab);

  /// This layout without [tab]'s pane, its neighbour taking the space; null
  /// when no pane is left.
  SplitLayout? without(WorkspaceTab tab);

  /// This layout with [old]'s pane replaced by [layout].
  SplitLayout replaced(WorkspaceTab old, SplitLayout layout);

  /// This layout with [tab] in [old]'s pane; a tab that already has a pane
  /// trades places with [old].
  SplitLayout placed(WorkspaceTab old, WorkspaceTab tab) =>
      _map((each) => each == old ? tab : (each == tab ? old : each));

  /// This layout with each pane's tab given by [pick].
  SplitLayout _map(WorkspaceTab Function(WorkspaceTab tab) pick);

  /// Divides [target]'s pane to show [tab] on its [side]. A tab that already
  /// has a pane moves there.
  SplitLayout split(WorkspaceTab target, WorkspaceTab tab, SplitSide side) {
    final added = SplitPane(tab), kept = SplitPane(target);
    return without(tab)!.replaced(
      target,
      SplitBranch(
        side.axis,
        side.before ? added : kept,
        side.before ? kept : added,
      ),
    );
  }

  /// Places every pane and divider in [area], with [gap] pixels for each
  /// divider.
  void layOut(
    Rect area, {
    required void Function(WorkspaceTab tab, Rect rect) pane,
    required void Function(SplitBranch branch, Rect area, Rect divider) divider,
    double gap = 6,
  });

  /// Saved form, with each tab given by [index].
  Object toJson(int Function(WorkspaceTab tab) index);

  /// Reads a saved layout. A pane whose [tab] is null is left out and its
  /// neighbour takes the space.
  static SplitLayout? fromJson(
    Object? json,
    WorkspaceTab? Function(int index) tab,
  ) => switch (json) {
    final int index => switch (tab(index)) {
      final found? => SplitPane(found),
      null => null,
    },
    {
      'axis': final String axis,
      'fraction': final num fraction,
      'panes': [final first, final second],
    } =>
      switch ((fromJson(first, tab), fromJson(second, tab))) {
        (final a?, final b?) => SplitBranch(
          Axis.values.byName(axis),
          a,
          b,
          fraction.toDouble(),
        ),
        (final a, final b) => a ?? b,
      },
    _ => null,
  };
}

class SplitPane extends SplitLayout {
  SplitPane(this.tab);
  final WorkspaceTab tab;

  @override
  List<WorkspaceTab> get tabs => [tab];

  @override
  SplitLayout? without(WorkspaceTab tab) => tab == this.tab ? null : this;

  @override
  SplitLayout replaced(WorkspaceTab old, SplitLayout layout) =>
      old == tab ? layout : this;

  @override
  SplitLayout _map(WorkspaceTab Function(WorkspaceTab) pick) =>
      SplitPane(pick(tab));

  @override
  void layOut(
    Rect area, {
    required void Function(WorkspaceTab, Rect) pane,
    required void Function(SplitBranch, Rect, Rect) divider,
    double gap = 6,
  }) => pane(tab, area);

  @override
  Object toJson(int Function(WorkspaceTab) index) => index(tab);
}

class SplitBranch extends SplitLayout {
  SplitBranch(this.axis, this.first, this.second, [this.fraction = .5]);
  final Axis axis;
  final SplitLayout first, second;

  /// The first pane's share of the split; each new split starts at half.
  double fraction;

  @override
  List<WorkspaceTab> get tabs => [...first.tabs, ...second.tabs];

  @override
  SplitLayout? without(WorkspaceTab tab) {
    final a = first.without(tab), b = second.without(tab);
    if (a == null || b == null) return a ?? b;
    return identical(a, first) && identical(b, second)
        ? this
        : SplitBranch(axis, a, b, fraction);
  }

  @override
  SplitLayout replaced(WorkspaceTab old, SplitLayout layout) => contains(old)
      ? SplitBranch(
          axis,
          first.replaced(old, layout),
          second.replaced(old, layout),
          fraction,
        )
      : this;

  @override
  SplitLayout _map(WorkspaceTab Function(WorkspaceTab) pick) =>
      SplitBranch(axis, first._map(pick), second._map(pick), fraction);

  // Each side keeps at least 240 pixels or a fifth of the split, whichever is
  // larger.
  double _minimum(double extent) => (240 / extent).clamp(.2, .5);

  double _shown(double extent) =>
      fraction.clamp(_minimum(extent), 1 - _minimum(extent));

  /// Moves the divider by [delta] pixels within a split [extent] pixels long.
  void resize(double delta, double extent) =>
      fraction = (_shown(extent) + delta / extent).clamp(
        _minimum(extent),
        1 - _minimum(extent),
      );

  @override
  void layOut(
    Rect area, {
    required void Function(WorkspaceTab, Rect) pane,
    required void Function(SplitBranch, Rect, Rect) divider,
    double gap = 6,
  }) {
    final horizontal = axis == Axis.horizontal;
    final extent = horizontal ? area.width : area.height;
    final middle =
        (horizontal ? area.left : area.top) + extent * _shown(extent);
    final (before, line, after) = horizontal
        ? (
            Rect.fromLTRB(area.left, area.top, middle - gap / 2, area.bottom),
            Rect.fromLTRB(
              middle - gap / 2,
              area.top,
              middle + gap / 2,
              area.bottom,
            ),
            Rect.fromLTRB(middle + gap / 2, area.top, area.right, area.bottom),
          )
        : (
            Rect.fromLTRB(area.left, area.top, area.right, middle - gap / 2),
            Rect.fromLTRB(
              area.left,
              middle - gap / 2,
              area.right,
              middle + gap / 2,
            ),
            Rect.fromLTRB(area.left, middle + gap / 2, area.right, area.bottom),
          );
    first.layOut(before, pane: pane, divider: divider, gap: gap);
    divider(this, area, line);
    second.layOut(after, pane: pane, divider: divider, gap: gap);
  }

  @override
  Object toJson(int Function(WorkspaceTab) index) => {
    'axis': axis.name,
    'fraction': fraction,
    'panes': [first.toJson(index), second.toJson(index)],
  };
}

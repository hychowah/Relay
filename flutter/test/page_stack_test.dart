import 'dart:async';
import 'dart:math' show max;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/workspace.dart';
import 'package:relay_flutter/split_layout.dart';
import 'package:relay_flutter/window_capture.dart';
import 'package:relay_flutter/workspace_tabs.dart';

import 'support/fake_page.dart';
import 'support/fixture.dart';

void main() {
  testWidgets('dragging tabs splits the page without recreating either view', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    final browser = await f.w.openApp(f.w.apps[0]);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final roomView = find.text('View Room layout', skipOffstage: false);
    final browserView = find.text('View Browser', skipOffstage: false);
    final roomElement = tester.element(roomView);
    final browserElement = tester.element(browserView);
    Rect page(WorkspaceTab tab) =>
        tester.getRect(find.byKey(ValueKey('page-${tab.id}')));
    final whole = page(browser);
    // Both Browser tabs have the same title.
    Finder chip(String title, [int index = 0]) => find
        .descendant(of: find.byType(WorkspaceTabs), matching: find.text(title))
        .at(index);

    Future<void> dragTab(Finder tab, Offset to, String highlight) async {
      final drag = await tester.startGesture(
        tester.getCenter(tab),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(0, 40));
      await drag.moveTo(to);
      await tester.pump();
      expect(find.byKey(ValueKey(highlight)), findsOneWidget);
      await drag.up();
      await tester.pumpAndSettle();
    }

    await dragTab(
      chip('Room layout'),
      Offset(whole.left + 40, whole.center.dy),
      'drop-left',
    );
    final split = f.w.shownSplit!;
    expect(split.layout.tabs, [room, browser]);
    expect(f.w.active, room);
    expect(chip('Room layout + Browser'), findsOneWidget);
    // The split tab draws its panes as they are arranged.
    Rect mapPane(WorkspaceTab tab) =>
        tester.getRect(find.byKey(ValueKey('split-map-${tab.id}')));
    expect(mapPane(room).right, lessThan(mapPane(browser).left));
    expect(mapPane(room).height, mapPane(browser).height);
    expect(mapPane(room).height, greaterThan(10));
    expect(tester.element(roomView), same(roomElement));
    expect(tester.element(browserView), same(browserElement));
    final left = page(room);
    final right = page(browser);
    expect(left.right, lessThan(right.left));
    expect(left.width, closeTo(right.width, 1));
    expect(find.byIcon(Icons.vertical_split), findsNWidgets(2));

    // Browser's bar is at the top of its own pane whichever pane is
    // selected, so selecting a pane moves no page.
    final reload = tester.getRect(find.byTooltip('Reload'));
    expect(reload.left, greaterThan(right.left));
    expect(reload.bottom, lessThanOrEqualTo(right.top));
    expect(left.top, lessThan(right.top));
    await tester.tapAt(right.center);
    await tester.pump();
    expect(f.w.active, browser);
    expect((page(room), page(browser)), (left, right));
    await tester.tapAt(left.center);
    await tester.pump();
    expect(f.w.active, room);
    expect((page(room), page(browser)), (left, right));
    expect(tester.getRect(find.byTooltip('Reload')), reload);
    await tester.tapAt(right.center);
    await tester.pump();
    final selected = page(browser), beside = page(room);
    // On macOS a native page gets no input wherever Flutter paints over it, so
    // nothing may overlap the selected page, edges included. Its outline is a
    // frame around the page; each other pane has a tint that one click selects.
    void expectNothingOver(WorkspaceTab tab, List<WorkspaceTab> others) {
      final selected = page(tab);
      final pages = find
          .ancestor(
            of: find.byKey(ValueKey(tab.id)),
            matching: find.byType(Stack),
          )
          .first;
      // The slot's capture picture is painted under the page, not over it.
      final inPage = find
          .descendant(
            of: find.ancestor(
              of: find.byKey(ValueKey('page-${tab.id}')),
              matching: find.byType(PageSlot),
            ),
            matching: find.byWidgetPredicate((_) => true),
          )
          .evaluate()
          .toSet();
      final painted = find.descendant(
        of: pages,
        matching: find.byWidgetPredicate(
          (w) => w is ColoredBox || w is DecoratedBox || w is CustomPaint,
        ),
      );
      final outline = Theme.of(tester.element(pages)).colorScheme.primary
          .withValues(alpha: .45);
      var outlines = 0;
      for (final element in painted.evaluate()) {
        if (inPage.contains(element)) continue;
        final box = element.renderObject! as RenderBox;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        expect(
          rect.overlaps(selected),
          isFalse,
          reason: '$rect ${element.widget} ${element.widget.key}',
        );
        final widget = element.widget;
        if (widget is ColoredBox && widget.color == outline) outlines++;
      }
      expect(outlines, 4);
      expect(find.byKey(ValueKey('pane-${tab.id}')), findsNothing);
      for (final other in others) {
        expect(find.byKey(ValueKey('pane-${other.id}')), findsOneWidget);
      }
    }

    expectNothingOver(browser, [room]);

    // A second Browser tab dropped near the bottom edge stacks under it.
    final second = await f.w.openApp(f.w.apps[0]);
    f.w.select(split);
    await tester.pumpAndSettle();
    await dragTab(
      chip('Browser', 1),
      Offset(selected.center.dx, selected.bottom - 30),
      'drop-bottom',
    );
    expect(split.layout.tabs, [room, browser, second]);
    expect(page(browser).bottom, lessThan(page(second).top));
    expect(page(browser).left, selected.left);
    expect(page(second).width, page(browser).width);
    expect(mapPane(browser).bottom, lessThan(mapPane(second).top));
    expect(mapPane(room).right, lessThan(mapPane(second).left));
    expect(page(room), beside, reason: 'other panes keep their place');
    expect(tester.element(browserView.first), same(browserElement));
    expect(f.w.active, second);
    expectNothingOver(second, [room, browser]);
    // Only the selected pane has an address field; another Browser pane's bar
    // shows that pane's own address.
    (browser.page! as FakePage).url = 'https://example.org/other';
    f.w.changed();
    await tester.pump();
    final field = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == 'Search or enter a web address',
    );
    expect(field, findsOneWidget);
    expect(find.text('https://example.org/other'), findsOneWidget);
    // Nor does the keyboard reach the dimmed pane's bar, whose buttons would
    // act on the selected tab.
    await tester.tap(field);
    for (var i = 0; i < 40; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      var dimmed = false;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
        dimmed = e.widget.key == ValueKey('bar-${browser.id}');
        return !dimmed;
      });
      expect(dimmed, isFalse, reason: 'Tab $i');
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    // One click on the dimmed top pane selects it.
    await tester.tapAt(page(browser).center);
    await tester.pump();
    expect(f.w.active, browser);
    expectNothingOver(browser, [room, second]);
    // The split tab's map fills the pane selected last.
    Color? fill(WorkspaceTab tab) =>
        (tester
                    .widget<DecoratedBox>(
                      find.byKey(ValueKey('split-map-${tab.id}')),
                    )
                    .decoration
                as BoxDecoration)
            .color;
    expect(fill(browser), isNotNull);
    expect([fill(room), fill(second)], [null, null]);

    tester.view.physicalSize = const Size(700, 800);
    await tester.pumpAndSettle();
    expect(find.text('View Room layout'), findsNothing);
    expect(find.byIcon(Icons.vertical_split), findsNothing);
    expect(
      tester.widget<WorkspaceTabs>(find.byType(WorkspaceTabs)).selected,
      browser,
      reason: 'the strip marks the tab on screen, not the hidden split',
    );
    tester.view.physicalSize = const Size(1400, 800);
    await tester.pumpAndSettle();

    // Dragging a tab back to the tab strip takes it out of the split.
    final back = await tester.startGesture(
      tester.getCenter(chip('Browser', 1)),
      kind: PointerDeviceKind.mouse,
    );
    await back.moveBy(const Offset(0, 120));
    await back.moveTo(tester.getCenter(chip('Room layout')));
    await tester.pump();
    await back.up();
    await tester.pumpAndSettle();
    expect(split.layout.tabs, [room, browser]);
    expect(page(browser), right, reason: 'its neighbour grows');

    // Clicking an app's own tab shows it full screen; the split tab stays.
    await tester.tap(chip('Room layout'));
    await tester.pumpAndSettle();
    expect(f.w.shownSplit, isNull);
    expect(page(room).width, closeTo(whole.width, 1));
    expect(find.text('View Browser'), findsNothing);
    await tester.tap(chip('Room layout + Browser'));
    await tester.pumpAndSettle();
    expect(f.w.shownSplit, split);
    expect(f.w.active, browser, reason: 'the pane selected last');
    expect(page(room).width, beside.width);
    expect(page(room).left, beside.left);

    // Closing the split tab keeps every app open.
    await tester.tap(find.byTooltip('Close Room layout + Browser'));
    await tester.pumpAndSettle();
    expect(f.w.tabs, [room, browser, second]);
    expect(f.w.active, browser, reason: 'the selected pane shows alone');
    expect(page(browser).width, closeTo(whole.width, 1));
    expect(tester.element(roomView), same(roomElement));
    expect(tester.element(browserView.first), same(browserElement));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('split dividers resize side by side and stacked, and reset', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    final browser = await f.w.openApp(f.w.apps[0]);
    final second = await f.w.openApp(f.w.apps[0]);
    f.w.dropInSplit(room, second, SplitSide.left);
    f.w.dropInSplit(browser, second, SplitSide.top);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final roomView = find.text('View Room layout', skipOffstage: false);
    final roomElement = tester.element(roomView);
    Rect page(WorkspaceTab tab) =>
        tester.getRect(find.byKey(ValueKey('page-${tab.id}')));
    final width = page(browser).right - page(room).left;
    final (top, bottom) = (page(browser).height, page(second).height);
    Offset grip(int index) =>
        tester.getRect(find.byKey(ValueKey('split-divider-$index'))).center;
    double saved() => f.stored.last['tabs'][3]['split']['fraction'] as double;
    Future<void> dragDivider(int index, Offset by) async {
      final drag = await tester.startGesture(
        grip(index),
        kind: PointerDeviceKind.mouse,
      );
      // The first pixels of a move only start the drag, as a mouse does.
      await drag.moveBy(Offset(by.dx.sign * 2, by.dy.sign * 2));
      await drag.moveBy(by);
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
    }

    await dragDivider(0, const Offset(150, 0));
    expect(page(room).width, closeTo(width / 2 + 147, 2));
    expect(page(browser).width, closeTo(width / 2 - 153, 2));
    expect(saved(), closeTo(.5 + 150 / width, .01));
    expect(tester.element(roomView), same(roomElement));

    await dragDivider(0, const Offset(-2000, 0));
    expect(page(room).width, closeTo(max(240, width * .2) - 7, 1));

    // The divider between the stacked panes moves up and down.
    await dragDivider(1, const Offset(0, 100));
    expect(page(browser).height, closeTo(top + 100, 2));
    expect(page(second).height, closeTo(bottom - 100, 2));

    final reset = grip(0);
    await tester.tapAt(reset, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(reset, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(page(room).width, closeTo(page(browser).width, 1));
    expect(saved(), .5);

    // A narrow Browser pane's bar fits by leaving out Go and the PDF zoom.
    (second.page! as FakePage).pdf = true;
    f.w.changed();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Zoom in'), findsOneWidget);
    await dragDivider(0, const Offset(2000, 0));
    expect(page(browser).width, lessThan(480));
    expect(find.byTooltip('Zoom in'), findsNothing);
    expect(find.byTooltip('Go'), findsNothing);
    expect(find.byTooltip('Reload'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('an app tab that cannot load opens the App servers screen', (
    tester,
  ) async {
    final f = Fixture()..appDown = true;
    await f.w.start();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    // The pane for a tab without a page keeps its progress spinner turning,
    // so these steps pump a fixed time instead of settling.
    Future<void> settle() async {
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Future<void> opensServers() async {
      await tester.tap(find.widgetWithText(OutlinedButton, 'App servers'));
      await settle();
      expect(find.textContaining('No app servers are set up'), findsOneWidget);
      await tester.tap(find.byTooltip('Close app servers'));
      await settle();
    }

    await expectLater(f.w.openApp(f.w.apps[1]), throwsA(anything));
    await settle();
    expect(find.text('App is down.'), findsOneWidget);
    await opensServers();

    // A tab opened from a cited source shows the saved evidence instead.
    await f.w.openSource(deskReport);
    await settle();
    expect(find.textContaining('Its app view could not open'), findsOneWidget);
    await opensServers();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a loading app tab shows a spinner, and a Browser tab error '
      'offers no App servers', (tester) async {
    final f = Fixture();
    await f.w.start();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final view = f.holdView = Completer();
    final opening = f.w.openApp(f.w.apps[1]);
    await tester.pump();
    final loading = find.byKey(ValueKey('loading-${f.w.active!.id}'));
    expect(
      find.descendant(
        of: loading,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    view.complete();
    await opening;
    await tester.pumpAndSettle();
    expect(loading, findsNothing);
    expect(find.text('View Room layout'), findsOneWidget);

    final browser = await f.w.openApp(f.w.apps[0]);
    browser.error = 'The page failed.';
    f.w.changed();
    await tester.pumpAndSettle();
    expect(find.text('The page failed.'), findsOneWidget);
    expect(find.text('App servers'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("dragging a split divider moves the tab's split map with it; "
      'the workspace hears only the end', (tester) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    final browser = await f.w.openApp(f.w.apps[0]);
    f.w.dropInSplit(room, browser, SplitSide.left);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    double mapWidth(WorkspaceTab tab) =>
        tester.getRect(find.byKey(ValueKey('split-map-${tab.id}'))).width;
    final (left, right) = (mapWidth(room), mapWidth(browser));
    final saves = f.stored.length;
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('split-divider-0'))),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(2, 0));
    await drag.moveBy(const Offset(300, 0));
    await tester.pump();
    expect(mapWidth(room), greaterThan(left));
    expect(mapWidth(browser), lessThan(right));
    expect(f.stored, hasLength(saves));
    await drag.up();
    await tester.pumpAndSettle();
    expect(f.stored, hasLength(saves + 1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("what shows in place of a Browser tab's page starts below its "
      'bar, and its saved report offers no App servers', (tester) async {
    final f = Fixture();
    await f.w.start();
    final browser = await f.w.openApp(f.w.apps[0]);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    browser.error = 'The page failed.';
    f.w.changed();
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byKey(const ValueKey('address-bar')));
    expect(
      tester.getRect(find.byKey(ValueKey('error-${browser.id}'))).top,
      bar.bottom,
    );

    // A source cited from the Browser opens in its tab, whose page then fails.
    await f.w.openSource({...deskReport, 'appId': 'browser'});
    browser.error = 'The page failed.';
    f.w.changed();
    await tester.pumpAndSettle();
    final report = find.byKey(ValueKey('report-${browser.id}'));
    expect(report, findsOneWidget);
    expect(tester.getRect(report).top, bar.bottom);
    expect(find.textContaining('Its app view could not open'), findsOneWidget);
    expect(find.text('App servers'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a dragged tab highlights the half of a pane it would take, '
      'or the whole pane from its middle, and nothing over its own page', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    final browser = await f.w.openApp(f.w.apps[0]);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final page = tester.getRect(find.byKey(ValueKey('page-${browser.id}')));
    final bar = tester.getRect(find.byKey(const ValueKey('address-bar')));
    final pane = Rect.fromLTRB(page.left, bar.top, page.right, page.bottom);
    Finder chip(String title) => find.descendant(
      of: find.byType(WorkspaceTabs),
      matching: find.text(title),
    );
    final highlights = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('drop-'),
    );

    final own = await tester.startGesture(
      tester.getCenter(chip('Browser')),
      kind: PointerDeviceKind.mouse,
    );
    await own.moveBy(const Offset(0, 40));
    await own.moveTo(Offset(pane.left + 40, pane.center.dy));
    await tester.pump();
    expect(highlights, findsNothing);
    await own.up();
    await tester.pumpAndSettle();
    expect(f.w.shownSplit, isNull);

    final drag = await tester.startGesture(
      tester.getCenter(chip('Room layout')),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, 40));
    await drag.moveTo(Offset(pane.left + 40, pane.center.dy));
    await tester.pump();
    expect(
      tester.getRect(find.byKey(const ValueKey('drop-left'))),
      Rect.fromLTWH(pane.left, pane.top, pane.width / 2, pane.height),
    );
    await drag.moveTo(Offset(pane.center.dx, pane.bottom - 30));
    await tester.pump();
    expect(
      tester.getRect(find.byKey(const ValueKey('drop-bottom'))),
      Rect.fromLTWH(
        pane.left,
        pane.top + pane.height / 2,
        pane.width,
        pane.height / 2,
      ),
    );
    // From the middle, the tab takes the page's place instead of splitting.
    await drag.moveTo(pane.center);
    await tester.pump();
    expect(tester.getRect(find.byKey(const ValueKey('drop-centre'))), pane);
    expect(find.text('Show here'), findsOneWidget);
    await drag.up();
    await tester.pumpAndSettle();
    expect((f.w.shownSplit, f.w.active), (null, room));

    // In a split, a tab that has a pane trades places with the one it lands on.
    f.w.dropInSplit(browser, room, SplitSide.right);
    await tester.pumpAndSettle();
    final swap = await tester.startGesture(
      tester.getCenter(chip('Browser')),
      kind: PointerDeviceKind.mouse,
    );
    await swap.moveBy(const Offset(0, 40));
    await swap.moveTo(
      tester.getCenter(find.byKey(ValueKey('page-${room.id}'))),
    );
    await tester.pump();
    expect(find.text('Swap panes'), findsOneWidget);
    await swap.up();
    await tester.pumpAndSettle();
    expect(f.w.shownSplit!.layout.tabs, [browser, room]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a pane's buttons show another open tab or a chosen app in it, "
      'and take it out of the split, keeping its tab open', (tester) async {
    final f = Fixture();
    await f.w.start();
    final research = await f.w.openApp(f.w.apps[2]);
    final room = await f.w.openApp(f.w.apps[1]);
    final browser = await f.w.openApp(f.w.apps[0]);
    final second = await f.w.openApp(f.w.apps[0]);
    f.w.dropInSplit(room, browser, SplitSide.left);
    f.w.dropInSplit(second, browser, SplitSide.bottom);
    f.w.select(browser);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final split = f.w.shownSplit!;
    Finder button(WorkspaceTab pane, String tooltip) => find.descendant(
      of: find.byKey(ValueKey('pane-buttons-${pane.id}')),
      matching: find.byTooltip(tooltip),
    );
    Future<void> press(WorkspaceTab pane, String tooltip) async {
      await tester.tap(button(pane, tooltip));
      await tester.pumpAndSettle();
    }

    // One click works on a pane that is not selected.
    final top = tester.getRect(find.byKey(ValueKey('page-${browser.id}')));
    await press(second, 'Remove from split view');
    expect(split.layout.tabs, [room, browser]);
    expect(f.w.tabs, contains(second));
    expect(
      tester.getRect(find.byKey(ValueKey('page-${browser.id}'))).height,
      greaterThan(top.height),
    );

    // The menu lists the open tabs outside the split.
    await press(room, 'Show another tab here');
    final menu = find.byType(MenuItemButton);
    expect(
      tester
          .widgetList<Text>(
            find.descendant(of: menu, matching: find.byType(Text)),
          )
          .map((text) => text.data),
      ['Research', 'Browser', 'Choose an app…'],
    );
    await tester.tap(
      find.descendant(of: menu, matching: find.text('Research')),
    );
    await tester.pumpAndSettle();
    expect(split.layout.tabs, [research, browser]);
    expect(f.w.active, research);
    expect(f.w.tabs, contains(room));
    expect(f.stored.last['tabs'][4]['split']['panes'], [0, 2]);

    // Choose an app… shows the app picker in the pane.
    await press(research, 'Show another tab here');
    await tester.tap(find.text('Choose an app…'));
    await tester.pumpAndSettle();
    final blank = f.w.active!;
    expect(split.layout.tabs, [blank, browser]);
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('new-${blank.id}')),
        matching: find.text('Room layout'),
      ),
    );
    await tester.pumpAndSettle();
    expect(split.layout.tabs, [room, browser]);

    // A new tab taken out holds nothing, so it closes; a split left with one
    // pane ends, and every other tab stays open.
    await press(room, 'Show another tab here');
    await tester.tap(find.text('Choose an app…'));
    await tester.pumpAndSettle();
    await press(f.w.active!, 'Remove from split view');
    expect(f.w.shownSplit, isNull);
    expect(f.w.tabs, [research, room, browser, second]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a saved report shows again when its loaded app view fails', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final tab = await f.w.openSource(deskReport);
    await tester.pumpAndSettle();
    final report = find.byKey(ValueKey('report-${tab.id}'));
    expect(report, findsNothing);
    tab.error = 'The view stopped.';
    f.w.changed();
    await tester.pumpAndSettle();
    expect(report, findsOneWidget);
    expect(
      find.textContaining('could not open: The view stopped.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a split Browser pane's bar fits inside its frame, and a click "
      'that selects a dimmed pane is recorded', (tester) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    final browser = await f.w.openApp(f.w.apps[0]);
    f.w.dropInSplit(room, browser, SplitSide.left);
    f.w.select(browser);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    Rect page(WorkspaceTab tab) =>
        tester.getRect(find.byKey(ValueKey('page-${tab.id}')));
    final bar = tester.getRect(find.byKey(const ValueKey('address-bar')));
    expect((bar.left, bar.right), (page(browser).left, page(browser).right));

    f.w.recorder.start();
    await tester.tapAt(page(room).center);
    await tester.pump();
    expect(f.w.active, room);
    expect(
      f.w.recorder.events
          .where((e) => e['type'] == 'action')
          .map((e) => (e['name'], e['tab'])),
      [('select tab', 'Room layout')],
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('split dividers show resize cursors, and a stacked one saves '
      "at its drag's end", (tester) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    final browser = await f.w.openApp(f.w.apps[0]);
    final second = await f.w.openApp(f.w.apps[0]);
    f.w.dropInSplit(room, second, SplitSide.left);
    f.w.dropInSplit(browser, second, SplitSide.top);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    Finder divider(int index) => find.byKey(ValueKey('split-divider-$index'));
    MouseCursor cursor(int index) => tester
        .widget<MouseRegion>(
          find
              .descendant(
                of: divider(index),
                matching: find.byType(MouseRegion),
              )
              .first,
        )
        .cursor;
    expect(cursor(0), SystemMouseCursors.resizeColumn);
    expect(cursor(1), SystemMouseCursors.resizeRow);

    final saves = f.stored.length;
    final drag = await tester.startGesture(
      tester.getCenter(divider(1)),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, 2));
    await drag.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(f.stored, hasLength(saves));
    await drag.up();
    await tester.pumpAndSettle();
    expect(f.stored, hasLength(saves + 1));
    await tester.pumpWidget(const SizedBox());
  });
}

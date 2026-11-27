import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/split_layout.dart';
import 'package:relay_flutter/workspace.dart';
import 'package:relay_flutter/workspace_tabs.dart';

import 'support/fixture.dart';

void main() {
  Finder chip(String title) => find.descendant(
    of: find.byType(WorkspaceTabs),
    matching: find.text(title),
  );
  Rect chipRect(WidgetTester tester, String title) => tester.getRect(
    find.ancestor(of: chip(title), matching: find.byType(Material)).first,
  );

  testWidgets('tabs share the strip, narrowing as more open, then it scrolls', (
    tester,
  ) async {
    final tabs = <WorkspaceTab>[];
    Future<void> show(int count) async {
      tabs.addAll([
        for (var i = tabs.length; i < count; i++)
          WorkspaceTab(appId: 'browser', name: 'Tab $i', isBrowser: true),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 800,
                height: 48,
                child: WorkspaceTabs(
                  tabs: List.of(tabs),
                  selected: tabs.first,
                  onSelect: (_) {},
                  onClose: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Each chip keeps 5 px of its tab's width as the gap to the next.
    await show(3);
    await tester.pumpAndSettle();
    expect(chipRect(tester, 'Tab 2').width, 191, reason: 'full width fits');

    await show(6);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      chipRect(tester, 'Tab 0').width,
      allOf(lessThan(191), greaterThan(800 / 6 - 5)),
      reason: 'the tabs narrow as the new ones grow',
    );
    await tester.pumpAndSettle();
    expect(chipRect(tester, 'Tab 0').width, moreOrLessEquals(800 / 6 - 5));
    expect(chipRect(tester, 'Tab 5').right, moreOrLessEquals(800 - 5));
    expect(find.byTooltip('Close Tab 0'), findsOneWidget);
    expect(
      find.byTooltip('Close Tab 1'),
      findsNothing,
      reason: 'a narrow tab that is not selected leaves out its close button',
    );

    await show(10);
    await tester.pumpAndSettle();
    expect(chipRect(tester, 'Tab 9').width, 95, reason: 'the narrowest');
    final strip = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(strip.position.maxScrollExtent, 10 * 100 - 800);
  });

  testWidgets(
    'a tab dragged along the strip moves there, and the order is saved',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      final [browser, room, research] = [
        for (final app in f.w.apps) await f.w.openApp(app),
      ];
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      await tester.pumpAndSettle();
      final first = chipRect(tester, 'Browser'),
          second = chipRect(tester, 'Room layout');
      final step = second.left - first.left;

      // The chip follows the pointer and the one it passes makes room.
      final drag = await tester.startGesture(
        tester.getCenter(chip('Browser')),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(30, 0));
      await drag.moveBy(Offset(step, 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        chipRect(tester, 'Browser').center.dx,
        closeTo(first.center.dx + step + 30, 2),
      );
      expect(chipRect(tester, 'Room layout').left, first.left);
      expect(f.w.tabs, [browser, room, research], reason: 'not yet dropped');

      // Out over the page the chips go back; back on the strip they part again.
      await drag.moveBy(const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(chipRect(tester, 'Room layout').left, second.left);
      expect(chipRect(tester, 'Browser').left, first.left);
      await drag.moveBy(const Offset(0, -200));
      await drag.up();
      await tester.pumpAndSettle();
      expect(f.w.tabs, [room, browser, research]);
      expect(chipRect(tester, 'Browser').left, second.left);
      expect(chipRect(tester, 'Room layout').left, first.left);
      expect(
        [for (final tab in f.stored.last['tabs'] as List) tab['appId']],
        ['room-layout', 'browser', 'research'],
      );

      // A tab in the shown split only moves; it stays in the split.
      f.w.dropInSplit(research, room, SplitSide.right);
      await tester.pumpAndSettle();
      final split = f.w.shownSplit!;
      final start = tester.getCenter(chip('Research'));
      final move = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await move.moveBy(const Offset(-30, 0));
      await move.moveTo(tester.getCenter(chip('Room layout')));
      await move.up();
      await tester.pumpAndSettle();
      expect(f.w.tabs, [research, room, browser, split]);
      expect(f.w.shownSplit, split);
      expect(split.layout.tabs, [room, research]);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

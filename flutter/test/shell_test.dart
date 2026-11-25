
import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/split_layout.dart';
import 'package:relay_flutter/workspace_tabs.dart';

import 'support/fake_page.dart';
import 'support/fixture.dart';

void main() {
  testWidgets(
    'a fullscreen video takes the whole screen alone and its pane in split',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      final room = await f.w.openApp(f.w.apps[1]);
      final browser = await f.w.openApp(f.w.apps[0]);
      final video = browser.page! as FakePage;
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(
          workspace: f.w,
          initialDraft: 'Keep this draft',
          saveDraft: (_) async {},
        ),
      );
      await tester.pumpAndSettle();
      final view = find.byKey(ValueKey('page-${browser.id}'));
      final element = tester.element(view);
      final alone = tester.getRect(view);
      final menu = find.byTooltip('Workspace menu');
      final address = find.text('Search or enter a web address');
      final chat = find.text('Keep this draft');
      Future<void> pageFullScreen(bool on) async {
        video.fullScreen = on;
        video.changed(false);
        await tester.pumpAndSettle();
      }

      await pageFullScreen(true);
      expect(tester.getRect(view), const Rect.fromLTWH(0, 0, 1400, 800));
      expect(video.screenFills, [true]);
      expect(menu, findsNothing);
      expect(address, findsNothing);
      // Chat stays built, with its draft, but hidden.
      expect(chat, findsNothing);
      expect(find.text('Keep this draft', skipOffstage: false), findsOneWidget);
      expect(tester.element(view), same(element));

      // Escape in the page ends its fullscreen.
      await pageFullScreen(false);
      expect(tester.getRect(view), alone);
      expect(video.screenFills, [true, false]);
      expect(menu, findsOneWidget);
      expect(chat, findsOneWidget);

      // Another tab taking the screen ends the page's fullscreen.
      await pageFullScreen(true);
      f.w.select(room);
      await tester.pumpAndSettle();
      expect(video.screenFills, [true, false, true, false]);
      expect(video.fullScreen, isFalse);
      expect(menu, findsOneWidget);

      // In split view the video fills only its own pane, where its bar was.
      f.w.dropInSplit(browser, room, SplitSide.right);
      await tester.pumpAndSettle();
      final pane = tester.getRect(view);
      final beside = tester.getRect(find.byKey(ValueKey('page-${room.id}')));
      await pageFullScreen(true);
      expect(
        tester.getRect(view),
        Rect.fromLTRB(pane.left, beside.top, pane.right, pane.bottom),
      );
      expect(find.byTooltip('Reload'), findsNothing);
      expect(video.screenFills, [true, false, true, false]);
      expect(menu, findsOneWidget);
      expect(chat, findsOneWidget);
      await pageFullScreen(false);
      expect(tester.getRect(view), pane);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('a click that moves a few pixels still selects the tab', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    await f.w.openApp(f.w.apps[0]);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final click = await tester.startGesture(
      tester.getCenter(
        find.descendant(
          of: find.byType(WorkspaceTabs),
          matching: find.text('Room layout'),
        ),
      ),
      kind: PointerDeviceKind.mouse,
    );
    await click.moveBy(const Offset(4, 3));
    await click.up();
    await tester.pumpAndSettle();
    expect(f.w.active, room);
    expect(f.w.shownSplit, isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('newest tab first is a saved setting and slides the tab left', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    await f.w.openApp(f.w.apps[2]);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Newest tab first'));
    await tester.pumpAndSettle();
    expect(f.w.newestTabFirst, isTrue);
    expect(f.savedNewestFirst, [true]);

    Finder chip(String title) => find.descendant(
      of: find.byType(WorkspaceTabs),
      matching: find.text(title),
    );
    double left(String title) => tester.getTopLeft(chip(title)).dx;
    // The moving chip is drawn larger while it travels, then lands at rest.
    double width(String title) => tester
        .getRect(
          find.ancestor(of: chip(title), matching: find.byType(Material)).first,
        )
        .width;
    final start = left('Research'), end = left('Room layout');
    final rest = width('Research');
    await tester.tap(chip('Research'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(f.w.tabs.last, room);
    expect(left('Research'), allOf(lessThan(start), greaterThan(end)));
    expect(width('Research'), greaterThan(rest));
    expect(width('Room layout'), moreOrLessEquals(rest));
    await tester.pumpAndSettle();
    expect(left('Research'), end);
    expect(left('Room layout'), start);
    expect(width('Research'), rest);

    // A tab moved from the far end of a scrolled strip is scrolled into view.
    for (var i = 0; i < 6; i++) {
      f.w.newTab();
    }
    await tester.pumpAndSettle();
    final strip = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(WorkspaceTabs),
        matching: find.byType(Scrollable),
      ),
    );
    strip.position.jumpTo(strip.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(strip.position.pixels, greaterThan(0));
    await tester.tap(chip('Room layout'));
    await tester.pumpAndSettle();
    expect(f.w.tabs.first, room);
    expect(strip.position.pixels, 0);
    expect(left('Room layout'), end);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'with newest tab first, clicking tab D of A B C D gives D A B C',
    (tester) async {
      final f = Fixture()
        ..configApps = [
          ...apps,
          {'id': 'notes', 'name': 'Notes', 'description': 'Notes'},
        ];
      await f.w.start();
      final [a, b, c, d] = [for (final app in f.w.apps) await f.w.openApp(app)];
      f.w.select(a);
      f.w.setNewestTabFirst(true);
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(WorkspaceTabs),
          matching: find.text('Notes'),
        ),
      );
      await tester.pumpAndSettle();
      expect(f.w.tabs, [d, a, b, c]);
      expect(f.w.active, d);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'deleting a tab during insertion keeps the next tab interactive',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      final room = await f.w.openApp(f.w.apps[1]);
      final page = room.page!;
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      await tester.tap(find.byTooltip('New tab'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      f.w.closeTab(f.w.active!);
      await tester.tap(find.byTooltip('New tab'));
      await tester.pumpAndSettle();
      expect(f.w.tabs, [room, f.w.active]);
      expect(find.byTooltip('Close New tab'), findsOneWidget);
      await tester.tap(find.byTooltip('Close New tab'));
      await tester.pumpAndSettle();
      expect(f.w.active?.page, same(page));
      expect(find.byTooltip('Close New tab'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the toolbar names Relay from 600 px wide, records chat '
      'toggles, and New tab closes chat on a phone', (tester) async {
    final f = Fixture();
    await f.w.start();
    tester.view.physicalSize = const Size(599, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    expect(find.text('Relay'), findsNothing);
    tester.view.physicalSize = const Size(600, 800);
    await tester.pumpAndSettle();
    expect(find.text('Relay'), findsOneWidget);

    final panel = find.byKey(const ValueKey('conversation-panel'));
    expect(panel, findsOneWidget);
    await tester.tap(find.byTooltip('New tab'));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    f.w.recorder.start();
    await tester.tap(find.byTooltip('Toggle chat'));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    await tester.tap(find.byTooltip('New tab'));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    await tester.tap(find.byTooltip('Toggle chat'));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(
      [
        for (final event in f.w.recorder.events)
          if (event['name'] case 'open chat' || 'close chat') event['name'],
      ],
      ['open chat', 'close chat'],
    );
    f.w.recorder.stop();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('returning to the app opens the conversation last opened on '
      'another device', (tester) async {
    final f = Fixture();
    await f.w.start();
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    expect(f.w.conversationId, isNull);
    f.current = 'elsewhere';
    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(f.w.conversationId, 'elsewhere');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the toolbar shows where chat is, and a tab or Toggle chat ends '
      'chat only', (tester) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final toggle = find.byTooltip('Toggle chat');
    final panel = find.byKey(const ValueKey('conversation-panel'));
    final colors = Theme.of(tester.element(toggle)).colorScheme;
    Color? toggleColour() => tester
        .widget<Icon>(find.descendant(of: toggle, matching: find.byType(Icon)))
        .color;
    Object? selected() =>
        tester.widget<WorkspaceTabs>(find.byType(WorkspaceTabs)).selected;
    Future<void> chatOnly() async {
      await tester.tap(find.byTooltip('Workspace menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Chat only'));
      await tester.pumpAndSettle();
      expect(f.w.pageShown, isFalse);
    }

    expect(toggleColour(), colors.primary);
    expect(selected(), room);
    await chatOnly();
    expect(selected(), isNull);
    await tester.tap(
      find.descendant(
        of: find.byType(WorkspaceTabs),
        matching: find.text('Room layout'),
      ),
    );
    await tester.pumpAndSettle();
    expect(f.w.pageShown, isTrue);
    expect(selected(), room);
    expect(panel, findsOneWidget);

    await chatOnly();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(f.w.pageShown, isTrue);
    expect(panel, findsNothing);
    expect(toggleColour(), colors.onSurfaceVariant);
    await tester.pumpWidget(const SizedBox());
  });
}


import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/main.dart';

import 'support/fake_page.dart';
import 'support/fixture.dart';

void main() {
  testWidgets(
    'chat can reverse mid-slide and reduced motion closes immediately',
    (tester) async {
      final f = Fixture();
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dispatcher = tester.binding.platformDispatcher;
      addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pumpWidget(
        RelayApp(
          workspace: f.w,
          initialDraft: 'Keep this draft',
          saveDraft: (_) async {},
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.byTooltip('Toggle chat');
      final panel = find.byKey(const ValueKey('conversation-panel'));
      final docked = tester.getTopLeft(panel).dx;
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getTopLeft(panel).dx, inExclusiveRange(docked, 1200));
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(panel).dx, docked);
      expect(find.text('Keep this draft'), findsOneWidget);

      dispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pump();
      expect(panel, findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('chat reopens closed when it was left closed', (tester) async {
    final f = Fixture();
    final saved = <bool>[];
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(
        workspace: f.w,
        initialChatOpen: false,
        saveChatOpen: (open) async => saved.add(open),
        saveDraft: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('conversation-panel'));
    expect(panel, findsNothing);
    await tester.tap(find.byTooltip('Toggle chat'));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    expect(saved, [true]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a phone's compact chat bar names the chat, stops a reply and "
      'opens chat', (tester) async {
    final f = Fixture();
    await f.w.start();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(workspace: f.w, initialChatOpen: false, saveDraft: (_) async {}),
    );
    await tester.pumpAndSettle();
    expect(find.text('Talk to Relay'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);

    f.w.conversationId = 'conversation';
    f.messages = [
      {'role': 'assistant', 'text': 'A reply'},
    ];
    f.runs = [
      {'id': 'run', 'status': 'running'},
    ];
    await f.w.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Thinking…'), findsOneWidget);
    f.w.recorder.start();
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(
      f.w.recorder.events.where((e) => e['name'] == 'stop reply'),
      hasLength(1),
    );
    f.w.recorder.stop();
    f.runs = [];
    await f.w.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Stop'), findsNothing);

    final panel = find.byKey(const ValueKey('conversation-panel'));
    expect(panel, findsNothing);
    await tester.tap(find.text('Open conversation'));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    expect(find.text('Open conversation'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dragging the chat divider resizes chat as it moves and saves '
      'the width once', (tester) async {
    final f = Fixture();
    final saved = <double>[];
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(
        workspace: f.w,
        saveChatWidth: (width) async => saved.add(width),
        saveDraft: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('conversation-panel'));
    final docked = tester.getRect(panel);
    expect(docked.width, 1200 * .30 + 6);
    final drag = await tester.startGesture(
      Offset(docked.left + 3, docked.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(-2, 0));
    await drag.moveBy(const Offset(-60, 0));
    await tester.pump();
    await drag.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(tester.getRect(panel).left, closeTo(docked.left - 120, 4));
    expect(saved, isEmpty);
    await drag.up();
    await tester.pumpAndSettle();
    expect(saved, [closeTo(.40, .004)]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an agent presentation closes chat on a phone and ends chat only '
      'on the desktop', (tester) async {
    final f = Fixture();
    await f.w.start();
    await f.w.openApp(f.w.apps[1]);
    f.w.conversationId = 'conversation';
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('conversation-panel'));
    expect(panel, findsOneWidget);
    Future<void> present(String id) async {
      f.commands = [f.command(id, 'room-layout')];
      await f.w.refresh();
      await tester.pumpAndSettle();
      expect(f.acks.last['status'], 'applied');
    }

    await present('on-phone');
    expect(panel, findsNothing);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Toggle chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chat only'));
    await tester.pumpAndSettle();
    expect(f.w.pageShown, isFalse);
    await present('on-desktop');
    expect(f.w.pageShown, isTrue);
    expect(panel, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Chat only opens chat that was closed', (tester) async {
    final f = Fixture();
    final saved = <bool>[];
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(
        workspace: f.w,
        initialChatOpen: false,
        saveChatOpen: (open) async => saved.add(open),
        saveDraft: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Chat only'));
    await tester.pumpAndSettle();
    expect(saved, [true]);
    await tester.tap(find.byTooltip('Conversation options'));
    await tester.pumpAndSettle();
    expect(find.text('Show workspace'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('chat stays between 320 px and half the window wide', (
    tester,
  ) async {
    final f = Fixture();
    final saved = <double>[];
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(
        workspace: f.w,
        initialChatWidth: .9,
        saveChatWidth: (width) async => saved.add(width),
        saveDraft: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('conversation-panel'));
    expect(tester.getRect(panel).width, 600 + 6);
    Future<void> dragDivider(double dx) async {
      final rect = tester.getRect(panel);
      final drag = await tester.startGesture(
        Offset(rect.left + 3, rect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(Offset(dx.sign * 2, 0));
      await drag.moveBy(Offset(dx, 0));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
    }

    await dragDivider(-300);
    expect(tester.getRect(panel).width, 600 + 6);
    expect(saved, [.5]);
    await dragDivider(500);
    expect(tester.getRect(panel).width, closeTo(320 + 6, .001));
    expect(saved.last, closeTo(320 / 1200, .0001));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('chat only fills the workspace on a desktop and a phone, and a '
      "phone's sheet slides down as it closes", (tester) async {
    final f = Fixture();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('conversation-panel'));
    // Below the 48 px toolbar.
    const workspace = Rect.fromLTRB(0, 48, 1200, 800);
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Chat only'));
    await tester.pumpAndSettle();
    expect(tester.getRect(panel), workspace);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    const phone = Rect.fromLTRB(0, 48, 390, 844);
    expect(tester.getRect(panel), phone);
    await tester.tap(find.byTooltip('Toggle chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Toggle chat'));
    await tester.pumpAndSettle();
    final sheet = tester.getRect(panel);
    expect(sheet.bottom, phone.bottom);
    expect(sheet.height, closeTo(phone.height * .72, .001));
    await tester.tap(find.byTooltip('Toggle chat'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester.getRect(panel).top,
      inExclusiveRange(sheet.top, phone.bottom),
    );
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('chat only keeps the keyboard out of the page', (tester) async {
    final f = Fixture();
    await f.w.start();
    await f.w.openApp(f.w.apps[0]);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final address = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == 'Search or enter a web address',
      skipOffstage: false,
    );
    await tester.tap(address);
    await tester.pumpAndSettle();
    bool focused() => tester.widget<TextField>(address).focusNode!.hasFocus;
    expect(focused(), isTrue);
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Chat only'));
    await tester.pumpAndSettle();
    expect(focused(), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a page that fills the screen shows over chat only and hides a '
      "phone's compact chat bar", (tester) async {
    final f = Fixture();
    await f.w.start();
    final browser = await f.w.openApp(f.w.apps[0]);
    final video = browser.page! as FakePage;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(workspace: f.w, initialChatOpen: false, saveDraft: (_) async {}),
    );
    await tester.pumpAndSettle();
    Future<void> pageFullScreen(bool on) async {
      video.fullScreen = on;
      video.changed(false);
      await tester.pumpAndSettle();
    }

    final bar = find.text('Talk to Relay');
    expect(bar, findsOneWidget);
    await pageFullScreen(true);
    expect(bar, findsNothing);
    await pageFullScreen(false);
    expect(bar, findsOneWidget);

    tester.view.physicalSize = const Size(1400, 800);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Chat only'));
    await tester.pumpAndSettle();
    expect(f.w.pageShown, isFalse);
    await pageFullScreen(true);
    expect(f.w.pageShown, isTrue);
    expect(
      tester.getRect(find.byKey(ValueKey('page-${browser.id}'))),
      const Rect.fromLTWH(0, 0, 1400, 800),
    );
    await tester.pumpWidget(const SizedBox());
  });
}

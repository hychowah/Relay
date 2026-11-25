import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/conversation_view.dart';
import 'package:relay_flutter/main.dart';

import 'support/fixture.dart';

void main() {
  testWidgets('a transcript selection stays while the page selects nothing, '
      'and goes once its pane closes', (tester) async {
    final f = Fixture();
    await f.w.start();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await f.w.openApp(f.w.apps[0]);
    final page = f.pages.last
      ..url = 'https://www.youtube.com/watch?v=video'
      ..transcript = {
        'language': 'English',
        'text': '[0:01] Hello there\n[0:40] Second part',
      };
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();
    final paragraph = find.text('[0:40] Second part');
    final drag = await tester.startGesture(
      tester.getTopLeft(paragraph) + const Offset(1, 5),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveTo(tester.getTopRight(paragraph) + const Offset(-1, 5));
    await drag.up();
    await tester.pumpAndSettle();
    final fromTranscript = find.text('“[0:40] Second part”');
    expect(fromTranscript, findsOneWidget);

    page.selection = '';
    f.w.changed();
    await tester.pumpAndSettle();
    expect(fromTranscript, findsOneWidget);
    page.selection = 'selected passage';
    f.w.changed();
    await tester.pumpAndSettle();
    expect(fromTranscript, findsOneWidget);

    // Closing the pane drops it, and reopening does not bring it back.
    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();
    expect(fromTranscript, findsNothing);
    expect(find.text('“selected passage”'), findsOneWidget);
    await tester.tap(find.text('Transcript'));
    await tester.pumpAndSettle();
    expect(paragraph, findsOneWidget);
    expect(fromTranscript, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a tap on the field reads an included page's selection again "
      'and shows it, unless the bot may not use the app', (tester) async {
    final f = Fixture();
    await f.w.start();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await f.w.openApp(f.w.apps[1]);
    final page = f.pages.last;
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    Future<void> tapField() async {
      await tester.tap(_composer);
      // Apart enough not to count as a double tap.
      await tester.pump(const Duration(milliseconds: 500));
    }

    // The page's newer selection, not drawn until the field asks for it.
    page.selection = 'the desk';
    await tapField();
    expect(page.selectionRefreshes, 1);
    expect(find.text('“the desk”'), findsOneWidget);

    await tester.tap(
      find.byTooltip('Current page included. Click to exclude.'),
    );
    await tester.pumpAndSettle();
    await tapField();
    expect(page.selectionRefreshes, 1);
    await tester.tap(
      find.byTooltip('Current page excluded. Click to include.'),
    );
    await tester.pumpAndSettle();

    f.w
      ..bots = [
        {
          'id': 'reader',
          'name': 'Reader',
          'appIds': ['browser'],
        },
      ]
      ..selectedBotId = 'reader'
      ..changed();
    await tester.pumpAndSettle();
    await tapField();
    expect(page.selectionRefreshes, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Enter does not send while the input method is composing', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    await tester.tap(_composer);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'nihon',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(f.sent, isNull);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '日本',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(f.sent!['text'], '日本');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Send keeps a blank draft and an edit made while sending, and '
      'a sent draft clears and shows the newest message', (tester) async {
    final f = Fixture()..current = 'conversation';
    f.messages = [
      for (var i = 0; i < 40; i++)
        {'role': 'assistant', 'text': 'Reply $i ${'words ' * 30}'},
    ];
    await f.w.start();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    String draft() => tester.widget<TextField>(_composer).controller!.text;
    final send = find.byTooltip('Send message');

    await tester.enterText(_composer, '   ');
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect((f.sent, draft()), (null, '   '));

    final messages = find
        .descendant(
          of: find.byType(ConversationMessages),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.drag(messages, const Offset(0, 300));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(messages).position;
    final older = scroll.pixels;
    expect(older, greaterThan(0));

    // Edited while the server takes the message: the edit stays.
    f.holdSnapshot = Completer();
    await tester.enterText(_composer, 'Hello');
    await tester.tap(send);
    await tester.pump();
    await tester.enterText(_composer, 'Hello again');
    f.holdSnapshot!.complete();
    f.holdSnapshot = null;
    await tester.pumpAndSettle();
    expect((f.sent!['text'], draft()), ('Hello', 'Hello again'));
    expect(scroll.pixels, older);

    await tester.tap(send);
    await tester.pumpAndSettle();
    expect((f.sent!['text'], draft()), ('Hello again', ''));
    expect(scroll.pixels, 0);
    await tester.pumpWidget(const SizedBox());
  });
}

/// The chat's message field.
final _composer = find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      w.decoration?.hintText == 'Ask Relay about your workspace…',
);

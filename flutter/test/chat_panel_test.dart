
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/provider_settings.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/transcript_pane.dart';

import 'support/fixture.dart';

void main() {
  testWidgets('forwarded chat shows the handoff before the first message', (
    tester,
  ) async {
    final f = Fixture();
    f.w.snapshot = ConversationSnapshot.fromJson({
      'messages': [],
      'forwards': [
        {
          'sourceTitle': 'Room dimensions',
          'sourceConversationId': 'source-chat',
          'messageIds': ['message-1'],
          'note': 'Check doorway clearance',
        },
      ],
    });
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    expect(find.textContaining('Check doorway clearance'), findsOneWidget);
    await tester.tap(find.text('Forwarded: Room dimensions'));
    await tester.pumpAndSettle();
    expect(f.w.conversationId, 'source-chat');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'compact chat keeps context, keyboard sending and grouped menus usable',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      await f.w.openApp(f.w.apps[1]);
      f.w.provider = {'model': 'DeepSeek', 'supportsReasoningEffort': true};
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byTooltip('Current page included. Click to exclude.'),
      );
      await tester.pump();
      expect(f.w.includeContext, isFalse);
      await tester.tap(find.byTooltip('Workspace menu'));
      await tester.pumpAndSettle();
      expect(find.text('WORKSPACE'), findsOneWidget);
      expect(find.text('Provider and model'), findsOneWidget);
      await tester.tap(find.text('Chat only'));
      await tester.pumpAndSettle();
      final input = find.byType(EditableText).last;
      await tester.enterText(input, 'First line');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(f.sent, isNull);
      await tester.enterText(input, 'First line\nSecond line');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(f.sent!['text'], 'First line\nSecond line');
      expect(f.sent!.containsKey('appContext'), isFalse);
      expect(tester.widget<EditableText>(input).controller.text, isEmpty);
      f.messages = [
        {'role': 'assistant', 'text': 'A readable reply'},
      ];
      await f.w.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Conversation options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show workspace'));
      await tester.pumpAndSettle();
      expect(find.text('A readable reply'), findsOneWidget);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(find.text('A readable reply'), findsOneWidget);
      await tester.tap(find.byTooltip('Workspace menu'));
      await tester.pumpAndSettle();
      expect(find.text('Provider and model'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'a YouTube Browser tab offers a selectable transcript beside chat',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await f.w.openApp(f.w.apps[0]);
      final page = f.pages.last;
      await tester.pumpWidget(
        RelayApp(workspace: f.w, initialDraft: '', saveDraft: (_) async {}),
      );
      await tester.pumpAndSettle();
      expect(find.text('Transcript'), findsNothing);

      page.url = 'https://www.youtube.com/watch?v=video';
      f.w.changed();
      await tester.pumpAndSettle();
      expect(find.text('Transcript'), findsOneWidget);
      expect(page.transcriptLoads, 0);

      page.transcriptError = StateError('This video has no captions.');
      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();
      expect(find.text('This video has no captions.'), findsOneWidget);
      page
        ..transcriptError = null
        ..transcript = {
          'language': 'English',
          'text': '[0:01] Hello there\n[0:40] Second part',
        };
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(page.transcriptLoads, 2);
      final paragraph = find.text('[0:40] Second part');
      final panel = tester.getRect(
        find.byKey(const ValueKey('conversation-panel')),
      );
      expect(tester.getCenter(paragraph).dy, lessThan(panel.center.dy));

      final drag = await tester.startGesture(
        tester.getTopLeft(paragraph) + const Offset(1, 5),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(tester.getTopRight(paragraph) + const Offset(-1, 5));
      await drag.up();
      await tester.pumpAndSettle();
      expect(find.text('“[0:40] Second part”'), findsOneWidget);

      // Focus moving to the composer keeps the transcript selection.
      await tester.tap(find.byType(TextField).last);
      await tester.enterText(find.byType(TextField).last, 'What happens here?');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        f.sent!['appContext']['surface']['selection'],
        '[0:40] Second part',
      );
      await tester.tapAt(
        tester.getCenter(paragraph),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('“selected passage”'), findsOneWidget);

      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();
      expect(find.text('[0:40] Second part'), findsNothing);
      expect(find.text('“selected passage”'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'And now?');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(f.sent!['appContext']['surface']['selection'], 'selected passage');

      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();
      expect(find.text('[0:40] Second part'), findsOneWidget);

      // A newer selection on the page replaces the transcript's.
      final again = await tester.startGesture(
        tester.getTopLeft(paragraph) + const Offset(1, 5),
        kind: PointerDeviceKind.mouse,
      );
      await again.moveTo(tester.getTopRight(paragraph) + const Offset(-1, 5));
      await again.up();
      await tester.pumpAndSettle();
      expect(find.text('“[0:40] Second part”'), findsOneWidget);
      page.selection = 'newer page text';
      f.w.changed();
      await tester.pumpAndSettle();
      expect(find.text('“newer page text”'), findsOneWidget);
      page.selection = 'selected passage';

      // The expanded conversation keeps the transcript.
      await tester.tap(find.byTooltip('Conversation options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expand conversation'));
      await tester.pumpAndSettle();
      expect(find.text('[0:40] Second part'), findsOneWidget);
      // It covers the page, so the page's form cannot be filled meanwhile.
      expect(f.w.pageShown, isFalse);
      await tester.tap(find.byTooltip('Conversation options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show workspace'));
      await tester.pumpAndSettle();
      expect(find.text('[0:40] Second part'), findsOneWidget);
      expect(f.w.pageShown, isTrue);

      page.url = 'https://www.youtube.com/';
      f.w.changed();
      await tester.pumpAndSettle();
      expect(find.text('Transcript'), findsNothing);
      expect(find.text('“selected passage”'), findsOneWidget);

      page.url = 'https://www.youtube.com/watch?v=video';
      tester.view.physicalSize = const Size(390, 844);
      f.w.changed();
      await tester.pumpAndSettle();
      expect(find.text('Transcript'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the transcript follows the video until the user scrolls or selects',
    (tester) async {
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
          'text': [
            for (var i = 0; i < 30; i++)
              '[${i ~/ 3}:${(i % 3 * 20).toString().padLeft(2, '0')}] '
                  'Part $i ${'words ' * 100}',
          ].join('\n'),
        };
      await tester.pumpWidget(
        RelayApp(workspace: f.w, initialDraft: '', saveDraft: (_) async {}),
      );
      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();

      Finder part(int i) => find.textContaining(RegExp('] Part $i '));
      Color? shade(int i) =>
          (tester
                      .widget<DecoratedBox>(
                        find
                            .ancestor(
                              of: part(i),
                              matching: find.byType(DecoratedBox),
                            )
                            .first,
                      )
                      .decoration
                  as BoxDecoration)
              .color;
      final pane = tester.getRect(find.byType(TranscriptPane));
      final tint = Theme.of(tester.element(find.byType(TranscriptPane)))
          .colorScheme
          .primary
          .withValues(alpha: .14);
      bool shown(int i) => pane.contains(tester.getTopLeft(part(i)));
      final scroll = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byType(TranscriptPane),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      Future<void> play(double? seconds) async {
        page.time = seconds;
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
      }

      final follow = find.text('Follow video');
      expect(shade(0), isNull);
      // 2:30 is within Part 7, which starts at 2:20.
      await play(150);
      expect(shade(7), tint);
      expect(shown(7), isTrue);
      expect(follow, findsNothing);
      // A seek back moves it, rebuilding only the two paragraphs that change;
      // an unknown time, as during an ad, keeps it.
      final rebuilt = <Widget>[];
      debugOnRebuildDirtyWidget = (element, _) => rebuilt.add(element.widget);
      await play(5);
      debugOnRebuildDirtyWidget = null;
      expect(rebuilt.whereType<TranscriptPane>(), isEmpty);
      expect(rebuilt.whereType<ValueListenableBuilder<bool>>(), hasLength(2));
      expect([shade(0), shade(7)], [tint, null]);
      expect(shown(0), isTrue);
      await play(null);
      expect(shade(0), tint);

      // Scrolling by hand stops following; the highlight still moves.
      final wheel = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(wheel.hover(pane.center));
      await tester.sendEventToBinding(wheel.scroll(const Offset(0, 300)));
      await tester.pumpAndSettle();
      expect(follow, findsOneWidget);
      final offset = scroll.pixels;
      await play(570);
      expect(shade(28), tint);
      expect(scroll.pixels, offset);
      await tester.tap(follow);
      await tester.pumpAndSettle();
      expect(shown(28), isTrue);
      expect(follow, findsNothing);

      // Selecting stops following, which never disturbs the selection.
      final start = tester.getTopLeft(part(28)) + const Offset(1, 5);
      final drag = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(start + const Offset(150, 0));
      await drag.up();
      await tester.pumpAndSettle();
      final kept = find.textContaining('“[9:20] Part');
      expect(kept, findsOneWidget);
      expect(follow, findsOneWidget);
      await play(20);
      expect(shade(1), tint);
      expect(shown(28), isTrue);
      await tester.tap(follow);
      await tester.pumpAndSettle();
      expect(shown(1), isTrue);
      expect(kept, findsOneWidget);

      // Closing the pane stops reading the time.
      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();
      final reads = page.timeReads;
      await tester.pump(const Duration(seconds: 2));
      expect(page.timeReads, reads);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the effort menu marks its choice and shows a failed change', (
    tester,
  ) async {
    // No start, so no poll can put its own error in the banner.
    final f = Fixture();
    f.w.provider = {'model': 'DeepSeek', 'supportsReasoningEffort': true};
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    Finder checked(String item) => find.descendant(
      of: find.widgetWithText(MenuItemButton, item),
      matching: find.byIcon(Icons.check),
    );
    await tester.tap(find.text('Thinking'));
    await tester.pumpAndSettle();
    expect(find.text('THINKING EFFORT'), findsOneWidget);
    expect(checked('Connection default'), findsOneWidget);
    expect(checked('High'), findsNothing);
    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();
    expect(f.w.draftEffort, 'high');
    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();
    expect(checked('Connection default'), findsNothing);
    expect(checked('High'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // A saved conversation's change goes to the server; its failure shows.
    f.w.conversationId = 'conversation';
    f.failSnapshot = true;
    f.w.changed();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thinking'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Low'));
    await tester.pumpAndSettle();
    expect((f.w.error, f.w.pollError), ('Snapshot failed', null));
    expect(
      find.descendant(
        of: find.byType(MaterialBanner),
        matching: find.text('Snapshot failed'),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Send turns to Stop while a reply runs, and a send in flight holds '
    'history and new conversation',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      f.w.provider = {'model': 'DeepSeek'};
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      await tester.pumpAndSettle();
      f.w.recorder.start();
      // The model button opens the provider settings.
      await tester.tap(find.text('DeepSeek'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderSettings), findsOneWidget);
      expect(
        f.w.recorder.events.where((e) => e['name'] == 'menu').single['item'],
        'provider',
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      bool enabled(IconData icon) =>
          tester
              .widget<IconButton>(find.widgetWithIcon(IconButton, icon))
              .onPressed !=
          null;
      // The spinner of a running reply never settles.
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }

      expect(find.byTooltip('Send message'), findsOneWidget);
      // A send waiting for the server.
      f.holdSnapshot = Completer();
      await tester.enterText(composer, 'Hello');
      await tester.tap(find.byTooltip('Send message'));
      await settle();
      expect(f.w.sending, isTrue);
      expect(find.byTooltip('Stop response'), findsOneWidget);
      expect(enabled(Icons.history_rounded), isFalse);
      expect(enabled(Icons.edit_square), isFalse);
      f.runs = [
        {'id': 'run', 'status': 'running'},
      ];
      f.holdSnapshot!.complete();
      f.holdSnapshot = null;
      await settle();
      // A reply running after the send leaves them usable.
      expect((f.w.sending, f.w.busy), (false, true));
      expect(find.byTooltip('Stop response'), findsOneWidget);
      expect(enabled(Icons.history_rounded), isTrue);
      expect(enabled(Icons.edit_square), isTrue);
      await tester.tap(find.byTooltip('Stop response'));
      await settle();
      expect(
        f.w.recorder.events.where((e) => e['name'] == 'stop reply'),
        hasLength(1),
      );
      f.runs = [];
      await f.w.refresh();
      await settle();
      expect(find.byTooltip('Send message'), findsOneWidget);
      f.w.recorder.stop();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the draft is saved 300 ms after typing and when the window '
      'closes', (tester) async {
    final f = Fixture();
    final drafts = <String>[];
    await tester.pumpWidget(
      RelayApp(workspace: f.w, saveDraft: (text) async => drafts.add(text)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(composer, 'Half');
    await tester.pump(const Duration(milliseconds: 299));
    expect(drafts, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(drafts, ['Half']);
    await tester.enterText(composer, 'Half a thought');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    expect(drafts, ['Half', 'Half a thought']);
    await tester.pump(const Duration(seconds: 1));
    expect(drafts, ['Half', 'Half a thought']);
  });

  testWidgets(
    'closed chat keeps its draft and transcript, and drops a transcript '
    'selection that a newer page selection replaced',
    (tester) async {
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
      await tester.pumpWidget(
        RelayApp(workspace: f.w, initialDraft: '', saveDraft: (_) async {}),
      );
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
      await tester.enterText(composer, 'Keep this draft');
      final fromTranscript = find.text('“[0:40] Second part”');
      expect(fromTranscript, findsOneWidget);

      // Closing chat removes its panel.
      final panel = find.byKey(const ValueKey('conversation-panel'));
      Future<void> toggleChat() async {
        await tester.tap(find.byTooltip('Toggle chat'));
        await tester.pumpAndSettle();
      }

      await toggleChat();
      expect(panel, findsNothing);
      await toggleChat();
      expect(find.text('Keep this draft'), findsOneWidget);
      expect(paragraph, findsOneWidget);
      expect(fromTranscript, findsOneWidget);

      // Selecting something newer on the page while chat is closed drops the
      // transcript's selection, even once the page's selection is back.
      await toggleChat();
      page.selection = 'newer page text';
      f.w.changed();
      await tester.pumpAndSettle();
      page.selection = 'selected passage';
      f.w.changed();
      await tester.pumpAndSettle();
      await toggleChat();
      expect(fromTranscript, findsNothing);
      expect(find.text('“selected passage”'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('New conversation clears the draft, and a conversation chosen '
      'from the menu opens chat', (tester) async {
    final f = Fixture()..current = 'conversation';
    await f.w.start();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(
        workspace: f.w,
        initialDraft: 'Old draft',
        saveDraft: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    expect(f.w.conversationId, 'conversation');
    await tester.tap(find.byTooltip('New conversation'));
    await tester.pumpAndSettle();
    expect(f.w.conversationId, isNull);
    expect(find.text('Old draft'), findsNothing);

    final panel = find.byKey(const ValueKey('conversation-panel'));
    await tester.tap(find.byTooltip('Toggle chat'));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Bots'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personal chat'));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

/// The chat's message field.
final composer = find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      w.decoration?.hintText == 'Ask Relay about your workspace…',
);

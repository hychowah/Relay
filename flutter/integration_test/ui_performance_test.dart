// The Mac UI smoothness suite. Run it from WSL with `npm run perf:ui`, which
// builds it under its own bundle id so it cannot read or write the installed
// app's settings and data. Each scenario repeats an everyday action against a
// loopback fixture server and summarizes Flutter's frame timings.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/conversation_view.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/relay_records.dart';
import 'package:relay_flutter/transcript_pane.dart';
import 'package:relay_flutter/workspace_tabs.dart';

import 'fixture.dart';

// Seed sizes and repeat counts.
const shortConversationMessages = 24;
const longConversationMessages = 2000;
const streamHistoryMessages = 40;
const streamSeconds = 12;
const panelCycles = 6; // open and close, after one warm-up cycle
const tabRounds = 3; // switches through every tab, after one warm-up round
const typingRounds = 3; // after one warm-up round
const typedText = 'Compare the harbour and orchard plans for next week.';
const scrollPixels = 40000.0;
const transcriptScrollPixels = 12000.0;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Mac UI smoothness', (tester) async {
    final workspace = await startFixtureApp(
      tester,
      const Fixture(
        apps: 3,
        conversations: {
          'short': shortConversationMessages,
          'long': longConversationMessages,
        },
        streamHistory: streamHistoryMessages,
        streamSeconds: streamSeconds,
        streamParts: 6,
      ),
      'short',
    );
    WorkspaceApp app(String id) => workspace.apps.firstWhere((a) => a.id == id);
    final size = tester.getSize(find.byType(RelayShell));
    expect(size.width, greaterThanOrEqualTo(900));
    final toggle = find.byTooltip('Toggle chat');
    expect(MediaQuery.disableAnimationsOf(tester.element(toggle)), isFalse);

    final frames = FrameRecorder(binding);
    final measure = frames.measure, settle = frames.settle;
    Future<void> scroll(Finder area, double pixels, {required bool up}) =>
        frames.scroll(tester, area, pixels, up: up);

    // Chat panel: the slide in and out, over an empty tab and a web page.
    final panel = find.byKey(const ValueKey('conversation-panel'));
    final dockedX = tester.getTopLeft(panel).dx;
    Future<void> slide() async {
      final open = panel.evaluate().isEmpty;
      await tester.tap(toggle);
      final deadline = DateTime.now().add(const Duration(seconds: 4));
      while (true) {
        await binding.endOfFrame.timeout(const Duration(seconds: 4));
        final present = panel.evaluate().isNotEmpty;
        if (open
            ? present && tester.getTopLeft(panel).dx == dockedX
            : !present) {
          break;
        }
        expect(
          DateTime.now().isBefore(deadline),
          isTrue,
          reason: 'Panel did not finish moving',
        );
      }
    }

    for (final (scenario, appId) in [
      ('Chat panel, empty tab', null),
      ('Chat panel, web page', 'fixture-a'),
    ]) {
      if (appId != null) {
        await workspace.openApp(app(appId));
        await settle();
        await pause(500);
      }
      for (var cycle = 0; cycle <= panelCycles * 2 + 1; cycle++) {
        await measure(scenario, slide, record: cycle > 1);
        await pause();
      }
    }

    // Typing in the composer, one character per frame: each frame handles a
    // keystroke, as the platform's text input delivers it.
    final composer = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Ask Relay about your workspace…',
    );
    await tester.tap(composer);
    await settle();
    final input = tester.state<EditableTextState>(
      find.descendant(of: composer, matching: find.byType(EditableText)),
    );
    for (var round = 0; round <= typingRounds; round++) {
      await measure('Typing in the composer', () async {
        for (var i = 1; i <= typedText.length; i++) {
          input.updateEditingValue(
            TextEditingValue(
              text: typedText.substring(0, i),
              selection: TextSelection.collapsed(offset: i),
            ),
          );
          await binding.endOfFrame.timeout(const Duration(seconds: 4));
        }
        await settle();
      }, record: round > 0);
      input.updateEditingValue(TextEditingValue.empty);
      await settle();
      await pause();
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await settle();

    // Switching between three app pages, a Browser page and a new tab, each
    // a loaded WKWebView except the new tab.
    for (final id in ['fixture-b', 'fixture-c', WorkspaceApp.browserId]) {
      await workspace.openApp(app(id));
    }
    workspace.newTab();
    expect(workspace.error, isNull);
    await settle();
    await pause(1000);
    Finder chip(String title) => find.descendant(
      of: find.byType(WorkspaceTabs),
      matching: find.text(title),
    );
    final titles = [for (final tab in workspace.tabs) tab.title];
    for (var round = 0; round <= tabRounds; round++) {
      for (final title in titles) {
        await measure('Switching tabs', () async {
          await tester.tap(chip(title));
          await settle();
        }, record: round > 0);
        await pause();
      }
    }

    // The transcript pane of an hour-long video: opening it, then scrolling
    // through it and back.
    await tester.tap(chip('Synthetic video'));
    await settle();
    await pause();
    const transcript = 'Transcript pane, hour-long video';
    await measure(transcript, () async {
      await tester.tap(find.text('Transcript'));
      await settle();
    });
    await pause(1000);
    final pane = find.byType(TranscriptPane);
    await measure(
      transcript,
      () => scroll(pane, transcriptScrollPixels, up: false),
    );
    await measure(
      transcript,
      () => scroll(pane, transcriptScrollPixels, up: true),
    );
    await tester.tap(find.text('Transcript'));
    await settle();
    await pause();

    // Scrolling a long conversation up through older replies and back, while
    // the client polls it every second as usual.
    await tester.tap(chip('Fixture A'));
    await workspace.selectConversation('long');
    await settle();
    await pause(1000);
    final messages = find.byType(ConversationMessages);
    for (final up in [true, false]) {
      await measure(
        'Scrolling a long conversation',
        () => scroll(messages, scrollPixels, up: up),
      );
    }
    await pause();

    // A reply streaming in: each poll returns a longer reply until its run
    // completes.
    await workspace.selectConversation('stream');
    expect(workspace.running, isNotNull);
    await measure('Reply streaming in', () async {
      final deadline = DateTime.now().add(
        const Duration(seconds: streamSeconds + 10),
      );
      while (workspace.running != null) {
        await binding.endOfFrame.timeout(const Duration(seconds: 4));
        expect(DateTime.now().isBefore(deadline), isTrue);
      }
      await settle();
    });
    expect(workspace.error, isNull);

    final hz = tester.view.display.refreshRate;
    binding.reportData = {
      'display_hz': hz,
      'window_width': size.width,
      'window_height': size.height,
      'scenarios': await frames.summaries(hz),
    };
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 6)));
}

// The Mac memory and stress suite. Run it from WSL with `npm run perf:stress`,
// which builds it under its own bundle id so it cannot read or write the
// installed app's settings and data. It repeats everyday actions to show
// memory that keeps growing, then loads the app heavily and measures
// smoothness and memory under that load.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/conversation_view.dart';
import 'package:relay_flutter/relay_records.dart';
import 'package:relay_flutter/main.dart';

import 'fixture.dart';
import 'memory.dart';

// Sizes and cycle counts. The first two readings of each repeated action are
// a warm-up and do not count towards its growth.
const tabsPerCycle = 10;
const tabCycles = 6;
const conversations = 20;
const conversationCycles = 6;
const transcriptCycles = 6;
const pollConversationMessages = 2000;
const pollMinutes = 5;
const pollReadingSeconds = 5;
const idleSeconds = 3; // before each end reading, so memory can be released
const stressMessages = 10000;
const stressTabs = 15;
const stressStreamSeconds = 60;
const stressStreamParts = 60;
const stressScrollPixels = 20000.0;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Mac memory and stress', (tester) async {
    final workspace = await startFixtureApp(
      tester,
      Fixture(
        apps: stressTabs,
        conversations: {
          for (var i = 0; i < conversations; i++) 'c$i': 20 + i * 20,
          'long': pollConversationMessages,
        },
        streamHistory: stressMessages,
        streamSeconds: stressStreamSeconds,
        streamParts: stressStreamParts,
      ),
      'c0',
    );
    WorkspaceApp app(String id) => workspace.apps.firstWhere((a) => a.id == id);
    final frames = FrameRecorder(binding);
    final memory = <String, Map<String, num>>{};
    Future<MemorySample> idleReading() async {
      await frames.settle();
      await pause(idleSeconds * 1000);
      return sampleMemory();
    }

    Future<void> showConversation(String id) async {
      await workspace.selectConversation(id);
      await frames.framesUntil(
        () => workspace.snapshot?.conversation?.id == id,
        const Duration(seconds: 10),
      );
      // A running reply keeps its progress indicator moving.
      if (workspace.running == null) await frames.settle();
    }

    Future<void> framesFor(Duration duration) {
      final clock = Stopwatch()..start();
      return frames.framesUntil(
        () => clock.elapsed >= duration,
        duration + const Duration(seconds: 5),
      );
    }

    // Opening and closing web tabs: each closed tab's WKWebView and its
    // WebContent process should go.
    var start = await idleReading();
    var ends = <MemorySample>[], during = <MemorySample>[];
    for (var cycle = 0; cycle < tabCycles; cycle++) {
      for (var i = 0; i < tabsPerCycle; i++) {
        await workspace.openApp(app(fixtureAppId(i)));
      }
      await frames.settle();
      during.add(await sampleMemory());
      for (final tab in List.of(workspace.tabs)) {
        workspace.closeTab(tab);
      }
      workspace.newTab();
      ends.add(await idleReading());
    }
    memory['Open and close $tabsPerCycle web tabs'] = {
      ...memorySummary(start, ends, others: during),
      'cycles': tabCycles,
    };
    expect(workspace.error, isNull);

    // Switching through conversations of 20 to 400 messages.
    start = await idleReading();
    ends = [];
    for (var cycle = 0; cycle < conversationCycles; cycle++) {
      for (var i = 0; i < conversations; i++) {
        await showConversation('c$i');
      }
      ends.add(await idleReading());
    }
    memory['Switch through $conversations conversations'] = {
      ...memorySummary(start, ends),
      'cycles': conversationCycles,
    };

    // Opening and closing the transcript pane of an hour-long video.
    await workspace.openApp(app(WorkspaceApp.browserId));
    start = await idleReading();
    ends = [];
    during = [];
    for (var cycle = 0; cycle < transcriptCycles; cycle++) {
      await tester.tap(find.text('Transcript'));
      await frames.settle();
      await pause(1000);
      during.add(await sampleMemory());
      await tester.tap(find.text('Transcript'));
      ends.add(await idleReading());
    }
    memory['Open and close the transcript pane'] = {
      ...memorySummary(start, ends, others: during),
      'cycles': transcriptCycles,
    };

    // A long conversation left open and polled every second.
    await showConversation('long');
    start = await idleReading();
    ends = [];
    final minutes = <double>[];
    final clock = Stopwatch()..start();
    for (var k = 1; k <= pollMinutes * 60 ~/ pollReadingSeconds; k++) {
      await pause(k * pollReadingSeconds * 1000 - clock.elapsedMilliseconds);
      ends.add(await sampleMemory());
      minutes.add(clock.elapsedMilliseconds / 60000);
    }
    memory['Poll a $pollConversationMessages-message conversation'] = {
      ...memorySummary(
        start,
        ends,
        at: minutes,
        warmUp: 60 ~/ pollReadingSeconds,
      ),
      'minutes': pollMinutes,
    };
    expect(workspace.error, isNull);

    // Stress: a long reply streaming into a 10,000-message conversation with
    // 15 tabs open, while scrolling and switching tabs.
    for (var i = 0; i < stressTabs - 1; i++) {
      await workspace.openApp(app(fixtureAppId(i)));
    }
    expect(workspace.tabs, hasLength(stressTabs));
    start = await idleReading();
    during = [];
    final sampler = Timer.periodic(const Duration(seconds: 3), (_) async {
      during.add(await sampleMemory());
    });
    await showConversation('stream');
    expect(workspace.running, isNotNull);
    await frames.measure(
      'Reply streaming, 10,000 messages',
      () => framesFor(const Duration(seconds: 10)),
    );
    final messages = find.byType(ConversationMessages);
    for (final up in [true, false]) {
      await frames.measure(
        'Scrolling while streaming',
        () => frames.scroll(
          tester,
          messages,
          stressScrollPixels,
          up: up,
          settle: false,
        ),
      );
    }
    for (final tab in List.of(workspace.tabs)) {
      await frames.measure(
        'Switching $stressTabs tabs while streaming',
        () async {
          workspace.select(tab);
          await framesFor(const Duration(milliseconds: 500));
        },
      );
    }
    expect(
      workspace.running,
      isNotNull,
      reason: 'The reply finished before the stress ended',
    );
    await frames.framesUntil(
      () => workspace.running == null,
      const Duration(seconds: stressStreamSeconds + 30),
    );
    sampler.cancel();
    during.add(await sampleMemory());
    // Then back to everyday use: the tabs closed and a short conversation.
    for (final tab in List.of(workspace.tabs)) {
      workspace.closeTab(tab);
    }
    workspace.newTab();
    await showConversation('c0');
    memory['Stress, then tabs closed'] = memorySummary(start, [
      await idleReading(),
    ], others: during);
    expect(workspace.error, isNull);

    final hz = tester.view.display.refreshRate;
    final size = tester.getSize(find.byType(RelayShell));
    binding.reportData = {
      'display_hz': hz,
      'window_width': size.width,
      'window_height': size.height,
      'scenarios': await frames.summaries(hz),
      'memory': memory,
    };
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 12)));
}

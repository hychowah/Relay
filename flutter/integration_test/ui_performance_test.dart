// The Mac UI smoothness suite. Run it from WSL with `npm run perf:ui`, which
// builds it under its own bundle id so it cannot read or write the installed
// app's settings and data. Each scenario repeats an everyday action against a
// loopback fixture server and summarizes Flutter's frame timings.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:relay_flutter/browser_transcript.dart';
import 'package:relay_flutter/conversation_view.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/transcript_pane.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:relay_flutter/workspace.dart';
import 'package:relay_flutter/workspace_tabs.dart';

import 'frame_summary.dart';

// Seed sizes and repeat counts. The whole suite runs in about two minutes.
const shortConversationMessages = 24;
const longConversationMessages = 2000;
const streamHistoryMessages = 40;
const streamSeconds = 12;
const panelCycles = 6; // open and close, after one warm-up cycle
const tabRounds = 3; // switches through every tab, after one warm-up round
const typingRounds = 3; // after one warm-up round
const typedText = 'Compare the harbour and orchard plans for next week.';
const scrollPixels = 40000.0;
const scrollPixelsPerSecond = 4000.0;
const transcriptMinutes = 60;
const transcriptScrollPixels = 12000.0;

const installedBundleId = 'app.relay.flutterExperiment';

// Synthetic text only.
const _words = [
  'harbour', 'lantern', 'orchard', 'granite', 'meadow', 'copper', //
  'willow', 'saffron', 'signal', 'ledger', 'canvas', 'summit', //
  'river', 'beacon', 'quarry', 'timber', 'forecast', 'budget',
];

String _sentence(int seed, [int? length]) {
  final count = length ?? 8 + seed % 9;
  final text = [
    for (var k = 0; k < count; k++) _words[(seed * 7 + k * 5) % _words.length],
  ].join(' ');
  return '${text[0].toUpperCase()}${text.substring(1)}.';
}

String _paragraph(int seed, int sentences) =>
    [for (var k = 0; k < sentences; k++) _sentence(seed * 13 + k)].join(' ');

String _userText(int i) => _paragraph(i, 1 + i % 3);

/// Markdown in the shapes replies take: short answers, headings with lists,
/// code blocks, numbered steps, long paragraphs, tables and quotes.
String _assistantText(int i) {
  final word = _words[i % _words.length];
  return switch (i % 6) {
    0 =>
      '${_paragraph(i, 2)} The **$word** option keeps `$word-$i` as its key.',
    1 =>
      '## The $word review\n\n${_paragraph(i, 3)}\n\n'
          '${[for (var k = 0; k < 4; k++) '- ${_sentence(i + k)}'].join('\n')}',
    2 =>
      '${_paragraph(i, 2)}\n\n```dart\n'
          '${[for (var k = 0; k < 10; k++) "final $word$k = load('$word', limit: ${k * 10});"].join('\n')}'
          '\n```\n\n${_sentence(i + 1)}',
    3 =>
      '### Steps\n\n'
          '${[for (var k = 1; k <= 4; k++) '$k. ${_sentence(i + k)}'].join('\n')}'
          '\n\n${_paragraph(i + 5, 4)}',
    4 => [for (var k = 0; k < 3; k++) _paragraph(i * 3 + k, 5)].join('\n\n'),
    _ =>
      '| Item | Value | Note |\n| --- | --- | --- |\n'
          '${[for (var k = 0; k < 4; k++) '| ${_words[(i + k) % _words.length]} | ${k * 17 + i % 50} | ${_sentence(i + k, 5)} |'].join('\n')}'
          '\n\n> ${_sentence(i + 2)}\n\n${_paragraph(i + 3, 2)}',
  };
}

final _start = DateTime.utc(2026, 1, 5, 9);

List<Json> _history(String id, int count) => [
  for (var i = 0; i < count; i++)
    {
      'id': '$id-$i',
      'role': i.isEven ? 'user' : 'assistant',
      'text': i.isEven ? _userText(i) : _assistantText(i ~/ 2),
      'createdAt': _start.add(Duration(minutes: i)).toIso8601String(),
    },
];

Json _snapshot(String id, List<Json> messages, [List<Json> runs = const []]) =>
    {
      'conversation': {'id': id, 'title': 'Synthetic $id conversation'},
      'messages': messages,
      'runs': runs,
    };

final _streamReply = [for (var k = 0; k < 6; k++) _assistantText(500 + k)]
    .join('\n\n');

List<int> _json(Object? data) => utf8.encode(jsonEncode(data));

/// The loopback fixture server. It runs in its own isolate so that encoding
/// replies does not add to the app's frame work.
Future<void> _serve(SendPort ready) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final apps = [
    {'id': WorkspaceApp.browserId, 'name': 'Browser'},
    for (final name in ['A', 'B', 'C'])
      {
        'id': 'fixture-${name.toLowerCase()}',
        'name': 'Fixture $name',
        'protocolVersion': 2,
      },
  ];
  final fixed = {
    '/api/config': _json({'apps': apps}),
    '/api/bots': _json([]),
    for (final (id, count) in [
      ('short', shortConversationMessages),
      ('long', longConversationMessages),
    ])
      '/api/conversations/$id': _json(_snapshot(id, _history(id, count))),
  };
  final history = _history('stream', streamHistoryMessages);
  final asked = _start.add(const Duration(days: 1)).toIso8601String();
  Stopwatch? streaming;
  // A running reply grows on each poll, as the service shows a model's
  // output, and its run completes when the whole text is there.
  List<int> stream() {
    final clock = streaming ??= Stopwatch()..start();
    final share = clock.elapsedMilliseconds / (streamSeconds * 1000);
    final shown = (_streamReply.length * min(share, 1)).floor();
    return _json(
      _snapshot(
        'stream',
        [
          ...history,
          {
            'id': 'stream-question',
            'role': 'user',
            'text': 'Summarize the review.',
            'createdAt': asked,
          },
          if (shown > 0)
            {
              'id': 'stream-reply',
              'role': 'assistant',
              'text': _streamReply.substring(0, shown),
              'createdAt': asked,
            },
        ],
        [
          {
            'id': 'stream-run',
            'status': share >= 1 ? 'completed' : 'running',
            'startedAt': asked,
          },
        ],
      ),
    );
  }

  server.listen((request) async {
    final path = request.uri.path;
    final response = request.response;
    if (path == '/flutter-host.html') {
      response.headers.contentType = ContentType.html;
      response.write('''
        <!doctype html><meta charset="utf-8"><title>Fixture</title>
        <style>main { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px } article { padding: 12px; border: 1px solid }</style>
        <main>${List.generate(100, (i) => '<article>Fixture item $i with a wrapping description.</article>').join()}</main>
        <script>onload = () => RelayHost.postMessage(JSON.stringify({
          version: 2, type: 'relay.ready', token: new URL(location.href).searchParams.get('view')
        }));</script>''');
    } else {
      final body = path == '/api/conversations/stream'
          ? stream()
          : RegExp(r'^/api/apps/[^/]+/view$').hasMatch(path)
          ? _json({})
          : fixed[path];
      response.statusCode = body == null ? 404 : 200;
      response.headers.contentType = ContentType.json;
      if (body != null) response.add(body);
    }
    await response.close();
  });
  ready.send(server.port);
}

const _videoUrl = 'https://www.youtube.com/watch?v=AAAAAAAAAAA';

String _clockText(int seconds) {
  final h = seconds ~/ 3600, m = seconds ~/ 60 % 60, s = seconds % 60;
  final ss = '$s'.padLeft(2, '0');
  return h > 0 ? '$h:${'$m'.padLeft(2, '0')}:$ss' : '$m:$ss';
}

final _transcript = transcriptFromSegments({
  'url': _videoUrl,
  'title': 'Synthetic lecture',
  'language': 'English',
  'segments': [
    for (var s = 0; s < transcriptMinutes * 60; s += 4)
      {'time': _clockText(s), 'text': _sentence(s, 9 + s % 5)},
  ],
});

/// A real Browser tab that reports a YouTube video and answers with a
/// synthetic transcript, so the transcript pane opens beside a real WKWebView
/// without any network.
class _VideoPage extends PageSurface with BrowserSurface {
  _VideoPage(this.inner);
  final PageSurface inner;
  final _clock = Stopwatch()..start();
  @override
  BrowserSurface get browser => this;
  @override
  Widget get widget => inner.widget;
  @override
  String get title => 'Synthetic video';
  @override
  String get url => _videoUrl;
  @override
  Json? get context => inner.context;
  @override
  Future<void> get ready => inner.ready;
  @override
  Future<void> refreshSelection() => inner.refreshSelection();
  @override
  Future<Json> present(Json command) => inner.present(command);
  @override
  void cancel(String commandId) => inner.cancel(commandId);
  @override
  void dispose() => inner.dispose();
  @override
  Future<Json> read() => inner.browser!.read();
  @override
  Future<Json> loadTranscript() async => _transcript;
  @override
  Future<double?> playbackTime() async => _clock.elapsedMilliseconds / 1000;
  @override
  Future<void> navigate(String text) => inner.browser!.navigate(text);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Mac UI smoothness', (tester) async {
    expect(
      Platform.isMacOS && kProfileMode,
      isTrue,
      reason: 'Run on macOS in profile mode.',
    );
    expect(
      (await PackageInfo.fromPlatform()).packageName,
      isNot(installedBundleId),
      reason:
          'Run through npm run perf:ui, which builds under its own bundle id '
          "so the installed app's settings and data stay untouched.",
    );
    final fixture = ReceivePort();
    final server = await Isolate.spawn(_serve, fixture.sendPort);
    addTearDown(() => server.kill(priority: Isolate.immediate));
    final port = await fixture.first as int;
    final workspace = Workspace(
      api: RelayApi(Uri.http('127.0.0.1:$port', '')),
      deviceId: 'benchmark',
      conversationId: 'short',
      pages: (spec, changed) {
        final page = createWebPage(spec, changed);
        return spec.browser ? _VideoPage(page) : page;
      },
      saveConversation: (_) async {},
    )..newTab();
    await workspace.start();
    expect(workspace.error, isNull);
    WorkspaceApp app(String id) => workspace.apps.firstWhere((a) => a.id == id);
    await tester.pumpWidget(
      RelayApp(workspace: workspace, saveDraft: (_) async {}),
    );
    final size = tester.getSize(find.byType(RelayShell));
    expect(size.width, greaterThanOrEqualTo(900));
    final toggle = find.byTooltip('Toggle chat');
    expect(MediaQuery.disableAnimationsOf(tester.element(toggle)), isFalse);

    final timings = <int, FrameTiming>{};
    void collect(List<FrameTiming> batch) {
      for (final timing in batch) {
        timings[timing.frameNumber] = timing;
      }
    }

    binding.addTimingsCallback(collect);
    addTearDown(() => binding.removeTimingsCallback(collect));
    int frame() => binding.platformDispatcher.frameData.frameNumber;
    Future<void> pause([int ms = 250]) =>
        Future<void>.delayed(Duration(milliseconds: ms));
    // Waits for the frames an action started, such as an ink ripple or a
    // slide, to finish.
    Future<void> settle() async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (binding.hasScheduledFrame) {
        await binding.endOfFrame.timeout(const Duration(seconds: 4));
        expect(
          DateTime.now().isBefore(deadline),
          isTrue,
          reason: 'The UI kept animating',
        );
      }
    }

    final ranges = <String, List<(int, int)>>{};
    Future<void> measure(
      String scenario,
      Future<void> Function() action, {
      bool record = true,
    }) async {
      final before = frame();
      await action();
      if (record) (ranges[scenario] ??= []).add((before, frame()));
    }

    // A mouse wheel or trackpad scroll at a steady speed, one step per frame.
    Future<void> scroll(Finder area, double pixels, {required bool up}) async {
      final pointer = TestPointer(2, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.addPointer(location: tester.getCenter(area)),
      );
      final clock = Stopwatch()..start();
      var moved = 0.0;
      while (moved < pixels) {
        final target = min(
          pixels,
          clock.elapsedMicroseconds / 1e6 * scrollPixelsPerSecond,
        );
        if (target > moved) {
          await tester.sendEventToBinding(
            pointer.scroll(Offset(0, (up ? -1 : 1) * (target - moved))),
          );
          moved = target;
        }
        await binding.endOfFrame.timeout(const Duration(seconds: 4));
      }
      await tester.sendEventToBinding(pointer.removePointer());
      await settle();
    }

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

    // Engine frame timing batches can arrive after the UI has settled.
    final lastFrame = frame();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!timings.containsKey(lastFrame)) {
      expect(
        DateTime.now().isBefore(deadline),
        isTrue,
        reason: 'Missing engine frame timings',
      );
      await pause(100);
    }
    final hz = tester.view.display.refreshRate;
    binding.reportData = {
      'display_hz': hz,
      'window_width': size.width,
      'window_height': size.height,
      'settings': {
        'short_conversation_messages': shortConversationMessages,
        'long_conversation_messages': longConversationMessages,
        'stream_history_messages': streamHistoryMessages,
        'stream_seconds': streamSeconds,
        'stream_reply_characters': _streamReply.length,
        'panel_cycles': panelCycles,
        'tab_rounds': tabRounds,
        'tabs': titles.length,
        'typing_rounds': typingRounds,
        'typed_characters': typedText.length,
        'scroll_pixels': scrollPixels,
        'scroll_pixels_per_second': scrollPixelsPerSecond,
        'transcript_minutes': transcriptMinutes,
        'transcript_characters': '${_transcript['text']}'.length,
        'transcript_scroll_pixels': transcriptScrollPixels,
      },
      'scenarios': {
        for (final entry in ranges.entries)
          entry.key: frameSummary(
            entry.value,
            timings,
            Duration.microsecondsPerSecond / hz,
          ),
      },
    };
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 6)));
}

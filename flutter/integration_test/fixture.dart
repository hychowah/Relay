// Shared by the Mac performance suites: synthetic data, the loopback fixture
// server, a Browser tab with a video transcript, and frame-timing helpers.
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
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:relay_flutter/workspace.dart';

import 'frame_summary.dart';

const _installedBundleId = 'app.relay.flutterExperiment';
const _transcriptMinutes = 60;
const _scrollPixelsPerSecond = 4000.0;

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

List<int> _json(Object? data) => utf8.encode(jsonEncode(data));

/// What the fixture server serves. App pages are titled 'Fixture A',
/// 'Fixture B' and so on, with ids 'fixture-a', 'fixture-b'.
class Fixture {
  const Fixture({
    required this.apps,
    required this.conversations,
    required this.streamHistory,
    required this.streamSeconds,
    required this.streamParts,
  });

  final int apps;

  /// Message counts of the conversations served as they are, by id.
  final Map<String, int> conversations;

  /// The 'stream' conversation: its earlier messages, then a reply of
  /// [streamParts] Markdown replies that grows over [streamSeconds].
  final int streamHistory, streamSeconds, streamParts;
}

String fixtureAppId(int i) => 'fixture-${String.fromCharCode(97 + i)}';

/// The loopback fixture server. It runs in its own isolate so that encoding
/// replies does not add to the app's frame work. Fixed replies are encoded
/// once, so its memory stays level after start.
Future<void> _serve((SendPort, Fixture) message) async {
  final (ready, fixture) = message;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final apps = [
    {'id': WorkspaceApp.browserId, 'name': 'Browser'},
    for (var i = 0; i < fixture.apps; i++)
      {
        'id': fixtureAppId(i),
        'name': 'Fixture ${String.fromCharCode(65 + i)}',
        'protocolVersion': 2,
      },
  ];
  final fixed = {
    '/api/config': _json({'apps': apps}),
    '/api/bots': _json([]),
    for (final MapEntry(key: id, value: count) in fixture.conversations.entries)
      '/api/conversations/$id': _json(_snapshot(id, _history(id, count))),
  };
  final history = _history('stream', fixture.streamHistory);
  final reply = [
    for (var k = 0; k < fixture.streamParts; k++) _assistantText(500 + k),
  ].join('\n\n');
  final asked = _start.add(const Duration(days: 1)).toIso8601String();
  Stopwatch? streaming;
  // A running reply grows on each poll, as the service shows a model's
  // output, and its run completes when the whole text is there.
  List<int> stream() {
    final clock = streaming ??= Stopwatch()..start();
    final share = clock.elapsedMilliseconds / (fixture.streamSeconds * 1000);
    final shown = (reply.length * min(share, 1)).floor();
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
              'text': reply.substring(0, shown),
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
    for (var s = 0; s < _transcriptMinutes * 60; s += 4)
      {'time': _clockText(s), 'text': _sentence(s, 9 + s % 5)},
  ],
});

/// A real Browser tab that reports a YouTube video and answers with a
/// synthetic hour-long transcript, so the transcript pane opens beside a real
/// WKWebView without any network.
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

/// Checks that this is a profile build under the test bundle id, starts the
/// fixture server and shows the app on [conversationId] with one empty tab.
Future<Workspace> startFixtureApp(
  WidgetTester tester,
  Fixture fixture,
  String conversationId,
) async {
  expect(
    Platform.isMacOS && kProfileMode,
    isTrue,
    reason: 'Run on macOS in profile mode.',
  );
  expect(
    (await PackageInfo.fromPlatform()).packageName,
    isNot(_installedBundleId),
    reason:
        'Run through npm run perf:ui or perf:stress, which build under their '
        "own bundle id so the installed app's settings and data stay untouched.",
  );
  final ready = ReceivePort();
  final server = await Isolate.spawn(_serve, (ready.sendPort, fixture));
  addTearDown(() => server.kill(priority: Isolate.immediate));
  final port = await ready.first as int;
  final workspace = Workspace(
    api: RelayApi(Uri.http('127.0.0.1:$port', '')),
    deviceId: 'benchmark',
    conversationId: conversationId,
    pages: (spec, changed) {
      final page = createWebPage(spec, changed);
      return spec.browser ? _VideoPage(page) : page;
    },
    saveConversation: (_) async {},
  )..newTab();
  await workspace.start();
  expect(workspace.error, isNull);
  await tester.pumpWidget(
    RelayApp(workspace: workspace, saveDraft: (_) async {}),
  );
  return workspace;
}

Future<void> pause([int ms = 250]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Records Flutter's frame timings and the frame ranges of each scenario.
class FrameRecorder {
  FrameRecorder(this.binding) {
    binding.addTimingsCallback(_collect);
    addTearDown(() => binding.removeTimingsCallback(_collect));
  }

  final IntegrationTestWidgetsFlutterBinding binding;
  final _timings = <int, FrameTiming>{};
  final _ranges = <String, List<(int, int)>>{};

  void _collect(List<FrameTiming> batch) {
    for (final timing in batch) {
      _timings[timing.frameNumber] = timing;
    }
  }

  int get _frame => binding.platformDispatcher.frameData.frameNumber;

  Future<void> measure(
    String scenario,
    Future<void> Function() action, {
    bool record = true,
  }) async {
    final before = _frame;
    await action();
    if (record) (_ranges[scenario] ??= []).add((before, _frame));
  }

  /// Waits for the frames an action started, such as an ink ripple or a
  /// slide, to finish.
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

  /// Keeps frames coming, as a running animation would, until [done].
  Future<void> framesUntil(bool Function() done, Duration limit) async {
    final deadline = DateTime.now().add(limit);
    while (!done()) {
      await binding.endOfFrame.timeout(const Duration(seconds: 4));
      expect(DateTime.now().isBefore(deadline), isTrue);
    }
  }

  /// A mouse wheel or trackpad scroll at a steady speed, one step per frame.
  Future<void> scroll(
    WidgetTester tester,
    Finder area,
    double pixels, {
    required bool up,
    bool settle = true,
  }) async {
    final pointer = TestPointer(2, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.addPointer(location: tester.getCenter(area)),
    );
    final clock = Stopwatch()..start();
    var moved = 0.0;
    while (moved < pixels) {
      final target = min(
        pixels,
        clock.elapsedMicroseconds / 1e6 * _scrollPixelsPerSecond,
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
    if (settle) await this.settle();
  }

  /// Each scenario's frame summary, once the engine has reported every frame.
  Future<Map<String, Map<String, num>>> summaries(double hz) async {
    // Engine frame timing batches can arrive after the UI has settled.
    final last = _frame;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!_timings.containsKey(last)) {
      expect(
        DateTime.now().isBefore(deadline),
        isTrue,
        reason: 'Missing engine frame timings',
      );
      await pause(100);
    }
    return {
      for (final MapEntry(key: name, value: ranges) in _ranges.entries)
        name: frameSummary(
          ranges,
          _timings,
          Duration.microsecondsPerSecond / hz,
        ),
    };
  }
}

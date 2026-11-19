import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:relay_flutter/workspace.dart';

Future<HttpServer> fixtureServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final app = {'id': 'fixture', 'name': 'Fixture', 'protocolVersion': 2};
  final messages = [
    for (var i = 0; i < 12; i++) ...[
      {'role': 'user', 'text': 'Compare item $i.'},
      {'role': 'assistant', 'text': '**Item $i** has two available options.'},
    ],
  ];
  server.listen((request) async {
    final response = request.response;
    if (request.uri.path == '/flutter-host.html') {
      response.headers.contentType = ContentType.html;
      response.write('''
        <!doctype html><meta charset="utf-8"><title>Fixture</title>
        <style>main { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px } article { padding: 12px; border: 1px solid }</style>
        <main>${List.generate(100, (i) => '<article>Fixture item $i with a wrapping description.</article>').join()}</main>
        <script>onload = () => RelayHost.postMessage(JSON.stringify({
          version: 2, type: 'relay.ready', token: new URL(location.href).searchParams.get('view')
        }));</script>''');
    } else {
      final data = switch (request.uri.path) {
        '/api/config' => {
          'apps': [app],
        },
        '/api/bots' => [],
        '/api/conversations/fixture' => {'messages': messages},
        '/api/apps/fixture/view' => {},
        _ => null,
      };
      response.statusCode = data == null ? 404 : 200;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(data));
    }
    await response.close();
  });
  return server;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Mac conversation panel frame timings', (tester) async {
    expect(
      Platform.isMacOS && kProfileMode,
      isTrue,
      reason: 'Run on macOS in profile mode.',
    );
    final server = await fixtureServer();
    addTearDown(() => server.close(force: true));
    final workspace = Workspace(
      api: RelayApi(Uri.http('127.0.0.1:${server.port}', '')),
      deviceId: 'benchmark',
      conversationId: 'fixture',
      pages: createWebPage,
      saveConversation: (_) async {},
    )..newTab();
    await workspace.start();
    expect(workspace.error, isNull);
    await tester.pumpWidget(
      RelayApp(workspace: workspace, saveDraft: (_) async {}),
    );
    final size = tester.getSize(find.byType(RelayShell));
    expect(size.width, greaterThanOrEqualTo(900));
    final panel = find.byKey(const ValueKey('conversation-panel'));
    final toggle = find.byTooltip('Toggle chat');
    expect(MediaQuery.disableAnimationsOf(tester.element(toggle)), isFalse);
    final dockedX = tester.getTopLeft(panel).dx;
    final dispatcher = binding.platformDispatcher;
    final timings = <FrameTiming>[];
    binding.addTimingsCallback(timings.addAll);
    addTearDown(() => binding.removeTimingsCallback(timings.addAll));
    final hz = tester.view.display.refreshRate;
    final frameBudgetUs = Duration.microsecondsPerSecond / hz;
    final report = <String, dynamic>{
      'window_width': size.width,
      'window_height': size.height,
      'display_hz': hz,
    };
    for (final surface in ['empty', 'webview']) {
      if (surface == 'webview') await workspace.openApp(workspace.apps.single);
      final ranges = <String, List<(int, int)>>{'open': [], 'close': []};
      for (var cycle = 0; cycle <= 6; cycle++) {
        for (final direction in ['close', 'open']) {
          final before = dispatcher.frameData.frameNumber;
          await tester.tap(toggle);
          final open = direction == 'open';
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
          if (cycle > 0) {
            ranges[direction]!.add((before, dispatcher.frameData.frameNumber));
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      // Engine frame timing batches can arrive after the UI has settled.
      final lastFrame = ranges['open']!.last.$2;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!timings.any((t) => t.frameNumber == lastFrame)) {
        expect(
          DateTime.now().isBefore(deadline),
          isTrue,
          reason: 'Missing engine frame timings',
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      for (final entry in ranges.entries) {
        final frames = <FrameTiming>[];
        final gaps = <int>[];
        for (final (before, last) in entry.value) {
          final slide = timings
              .where((t) => t.frameNumber > before && t.frameNumber <= last)
              .toList();
          expect(
            slide.length,
            greaterThan(1),
            reason: 'Transition had no measurable motion',
          );
          frames.addAll(slide);
          for (var i = 1; i < slide.length; i++) {
            gaps.add(
              slide[i].timestampInMicroseconds(FramePhase.vsyncStart) -
                  slide[i - 1].timestampInMicroseconds(FramePhase.vsyncStart),
            );
          }
        }
        gaps.sort();
        report['${surface}_${entry.key}'] = {
          'frames': frames.length,
          'frames_over_display_budget': frames
              .where(
                (frame) =>
                    frame.buildDuration.inMicroseconds > frameBudgetUs ||
                    frame.rasterDuration.inMicroseconds > frameBudgetUs,
              )
              .length,
          'build_us': frames
              .map((frame) => frame.buildDuration.inMicroseconds)
              .toList(),
          'raster_us': frames
              .map((frame) => frame.rasterDuration.inMicroseconds)
              .toList(),
          'slides': entry.value.length,
          'vsync_gaps_over_25ms': gaps.where((us) => us > 25000).length,
          'worst_vsync_gap_ms': gaps.last / 1000,
        };
      }
    }
    binding.reportData = report;
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 2)));
}

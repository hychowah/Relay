// Mac check that a redraw of Relay's window leaves a web page's hover where
// the mouse is (bug reports of 2026-11-24; see keepWebViewsAttached in
// MainFlutterWindow.swift). It puts the real pointer over one row of a page,
// redraws five times without moving it, and fails if the page hears of
// another row. Run it from WSL with
// `npm run test:mac -- hover_redraw_test.dart` on a Mac that is awake,
// unlocked and left alone for about half a minute: the app must come to the
// front, and the pointer moves.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:relay_flutter/window_capture.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a redraw leaves the hover under the still mouse', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'Run on macOS.');
    binding.shouldPropagateDevicePointerEvents = true;
    try {
      final page = createWebPage(
        PageSpec(
          id: 'hover-tab',
          appId: 'browser',
          name: 'Browser',
          sessionId: 'hover-check',
          relayOrigin: Uri.parse('http://127.0.0.1:9'),
        ),
        (_) {},
      );
      addTearDown(page.dispose);
      // The page sits inside the window, as under Relay's bars, so a wrong
      // reference point shows as another row.
      final shown = ValueNotifier(0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 900,
                height: 640,
                child: ValueListenableBuilder(
                  valueListenable: shown,
                  builder: (_, _, _) => PageSlot(page: page),
                ),
              ),
            ),
          ),
        ),
      );
      await page.ready.timeout(const Duration(seconds: 20));
      final controller = (page as dynamic).controller as WebViewController;
      const channel = MethodChannel('app.relay/browser');
      final rows = [
        for (var i = 0; i < 40; i++) '<div class="row" id="r$i">row $i</div>',
      ].join();
      await controller.loadHtmlString(
        '<!doctype html><title>Rows</title><style>body{margin:0}'
        '.row{height:20px}</style><body>$rows<script>window.hovered=[];'
        'addEventListener("mouseover",e=>hovered.push(e.target.id),true)'
        '</script>',
        baseUrl: 'https://example.com/',
      );
      for (var tries = 0; ; tries++) {
        final count = await controller.runJavaScriptReturningResult(
          'document.querySelectorAll(".row").length',
        );
        // WKWebView may return the number as 40.0.
        if (double.tryParse('$count') == 40) break;
        expect(tries, lessThan(100), reason: 'the page did not load');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }

      Future<List<String>> hovered() async {
        final raw = await controller.runJavaScriptReturningResult(
          'JSON.stringify(window.hovered.splice(0))',
        );
        var data = raw is String ? jsonDecode(raw) : raw;
        if (data is String) data = jsonDecode(data);
        return (data as List).cast<String>();
      }

      Future<void> move(Offset at) async {
        await channel.invokeMethod<Map>('mouse', {
          'type': 'moved',
          'x': at.dx,
          'y': at.dy,
        });
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }

      // The middle of row 15.
      final point =
          tester.getTopLeft(find.byType(PageSlot)) + const Offset(300, 310);
      await move(point - const Offset(0, 4));
      await move(point);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        (await hovered()).lastOrNull,
        'r15',
        reason: 'the moved pointer did not reach the page',
      );

      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        shown.value++;
        await tester.pump();
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(await hovered(), isEmpty, reason: 'a redraw moved the hover');
    } finally {
      binding.shouldPropagateDevicePointerEvents = false;
    }
  });
}

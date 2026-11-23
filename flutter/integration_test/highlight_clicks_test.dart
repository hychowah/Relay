// Mac check of the highlight menu with real mouse input: a debug build's
// runner queues AppKit mouse events, so a drag selects text in WKWebView or
// PDFKit and a click lands wherever the window sends it, as the user's own
// would. Run it from WSL with
// `npm run test:mac -- highlight_clicks_test.dart` on a Mac that is awake,
// unlocked and left alone for about half a minute: the app must come to
// the front. It opens
// one arXiv PDF, so the Mac needs the internet; the web page is the test's
// own. Highlights go to a loopback stand-in for the Relay server.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/highlight_menu.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:relay_flutter/window_capture.dart';
import 'package:webview_flutter/webview_flutter.dart';

const paper = 'https://arxiv.org/pdf/1301.3781v3';
const site = 'https://arxiv.org/abs/1301.3781v3';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real clicks highlight on a web page and a PDF', (tester) async {
    expect(Platform.isMacOS, isTrue, reason: 'Run on macOS.');
    // The test binding keeps the window's own mouse input from the app
    // unless told otherwise; the user's clicks are what is checked here.
    binding.shouldPropagateDevicePointerEvents = true;
    try {
      // The Relay server's highlight routes; every other call is accepted.
      final kept = <String, List<Json>>{};
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final path = request.uri.path;
        Object? reply;
        if (path == '/api/highlights' && request.method == 'GET') {
          reply = kept[request.uri.queryParameters['url']] ?? const <Json>[];
        } else if (path == '/api/highlights') {
          final body = jsonDecode(await utf8.decodeStream(request)) as Json;
          kept.putIfAbsent(body.remove('url') as String, () => []).add(body);
        } else if (path.startsWith('/api/highlights/')) {
          final id = path.split('/').last;
          final change = request.method == 'PATCH'
              ? jsonDecode(await utf8.decodeStream(request)) as Json
              : null;
          for (final list in kept.values) {
            if (change == null) list.removeWhere((item) => item['id'] == id);
            for (final item in list) {
              if (item['id'] == id) item.addAll(change ?? const {});
            }
          }
        }
        request.response.statusCode = reply == null ? 204 : 200;
        if (reply != null) request.response.write(jsonEncode(reply));
        await request.response.close();
      });
      List<Json> highlights(String url) => kept[url] ?? const [];

      final page = createWebPage(
        PageSpec(
          id: 'click-tab',
          appId: 'browser',
          name: 'Browser',
          sessionId: 'click-check',
          relayOrigin: Uri.parse('http://127.0.0.1:9'),
        ),
        (_) {},
        records: RelayApi(Uri.parse('http://127.0.0.1:${server.port}')),
      );
      addTearDown(page.dispose);
      // The page shows as the workspace shows it, rebuilt when it changes.
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
      final browser = page.browser!;
      final controller = (page as dynamic).controller as WebViewController;
      const channel = MethodChannel('app.relay/browser');

      Future<void> until(
        bool Function() done,
        String reason, {
        int seconds = 15,
      }) async {
        final deadline = DateTime.now().add(Duration(seconds: seconds));
        while (!done()) {
          expect(DateTime.now().isBefore(deadline), isTrue, reason: reason);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          shown.value++;
          await tester.pump();
        }
      }

      HighlightMenu? menu() => find
          .byType(HighlightMenu)
          .evaluate()
          .map((element) => element.widget as HighlightMenu)
          .firstOrNull;
      // Where AppKit sent each press and release, for a failure to report.
      final routed = <String>[];
      Future<void> mouse(String type, Offset at) async {
        final sent = await channel.invokeMethod<Map>('mouse', {
          'type': type,
          'x': at.dx,
          'y': at.dy,
        });
        if (type != 'dragged') {
          routed.add('$type ${at.dx.round()},${at.dy.round()} $sent');
        }
        await Future<void>.delayed(const Duration(milliseconds: 60));
        shown.value++;
        await tester.pump();
      }

      Future<void> drag(Offset from, Offset to) async {
        await mouse('down', from);
        for (var step = 1; step <= 8; step++) {
          await mouse('dragged', Offset.lerp(from, to, step / 8)!);
        }
        await mouse('up', to);
      }

      Future<void> click(Offset at) async {
        await mouse('down', at);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await mouse('up', at);
      }

      Offset button(String tooltip) =>
          tester.getCenter(find.byTooltip(tooltip));
      // What the web page has selected and painted, for a failure to report.
      Future<Object> pageState() => controller.runJavaScriptReturningResult(
        'JSON.stringify({selected: getSelection().toString(), '
        'focus: document.hasFocus(), painted: [...CSS.highlights.keys()]})',
      );
      final origin = tester.getTopLeft(find.byType(PageSlot));

      // A web page of the test's own, at a public address so it gets
      // highlights: drag over its words, then press a colour in the menu.
      await controller.loadHtmlString(
        '<!doctype html><title>Words</title>'
        '<p id="words" style="font:32px sans-serif;margin:60px">'
        'Gears turn slowly in the quiet workshop</p>',
        baseUrl: site,
      );
      // The page is ready once Relay has given it its highlight script.
      for (var tries = 0; ; tries++) {
        final ready = await controller.runJavaScriptReturningResult(
          'typeof window.__relayHighlights',
        );
        if ('$ready'.contains('object')) break;
        expect(
          tries,
          lessThan(100),
          reason: 'the page got no highlight script',
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
      final box = jsonDecode(
        '${await controller.runJavaScriptReturningResult("JSON.stringify((() => { const words = document.createRange(); words.selectNodeContents(document.getElementById('words')); return words.getClientRects()[0]; })())")}'
            .replaceAll(RegExp(r'^"|"$'), '')
            .replaceAll(r'\"', '"'),
      ) as Map;
      final pageBox = tester.getRect(find.byType(PageSlot));
      final line = origin.dy + (box['top'] as num) + (box['height'] as num) / 2;
      final start = Offset(origin.dx + (box['left'] as num) + 1, line);
      final end = Offset(origin.dx + (box['right'] as num) - 1, line);
      expect(
        pageBox.contains(start) && pageBox.contains(end),
        isTrue,
        reason: 'The text to drag over is not in view: $box',
      );
      await drag(start, end);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      printOnFailure('After the drag: $routed; ${await pageState()}');
      await until(() => menu() != null, 'no menu after a real drag on a page');
      routed.clear();
      await click(button('Highlight in green'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      printOnFailure(
        'After the menu click: $routed; menu still shown: ${menu() != null}; '
        '${await pageState()}',
      );
      await until(
        () => highlights(site).isNotEmpty,
        'a real click on the menu over a page highlighted nothing',
      );
      expect(highlights(site).single['color'], 'green');

      // A click on the highlight opens its menu: recolour, then remove.
      await click(Offset.lerp(start, end, .5)!);
      await until(() => menu()?.color == 'green', 'no menu on the highlight');
      await click(button('Change to blue'));
      await until(
        () => highlights(site).single['color'] == 'blue',
        'a real click did not recolour',
      );
      await click(Offset.lerp(start, end, .5)!);
      await until(() => menu()?.color == 'blue', 'no menu on the highlight');
      await click(button('Remove highlight'));
      await until(
        () => find.text('Remove').evaluate().isNotEmpty,
        'no confirm',
      );
      // The confirm button takes no click in its first 400 ms, against a
      // double click; it has also finished growing by then.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
      await click(tester.getCenter(find.text('Remove')));
      await until(
        () => highlights(site).isEmpty,
        'a real click did not remove',
      );

      // A PDF: a real drag over the first page's text, then the menu.
      await browser.navigate(paper);
      await until(() => browser.pdf, 'the viewer did not open', seconds: 60);
      await Future<void>.delayed(const Duration(seconds: 2));
      final size = tester.getSize(find.byType(PageSlot));
      routed.clear();
      await drag(
        origin + Offset(size.width * .2, size.height * .55),
        origin + Offset(size.width * .8, size.height * .58),
      );
      printOnFailure('After the PDF drag: $routed');
      await until(() => menu() != null, 'no menu after a real drag on a PDF');
      // PDFKit puts the selection on the nearest line, which the menu was
      // placed by: a click inside its top line lands on the highlight.
      final picked = menu()!.at;
      final onHighlight = origin + Offset(picked.center.dx, picked.top + 4);
      await click(button('Highlight in pink'));
      await until(
        () => highlights(paper).isNotEmpty,
        'a real click on the menu over a PDF highlighted nothing',
      );
      final marks = highlights(paper).single['marks'] as List;
      expect(marks, isNotEmpty);
      routed.clear();
      await click(onHighlight);
      printOnFailure('After the PDF highlight click: $routed');
      await until(
        () => menu()?.color == 'pink',
        'no menu on the PDF highlight',
      );
      await click(button('Change to blue'));
      await until(
        () => highlights(paper).single['color'] == 'blue',
        'a real click did not recolour in the PDF',
      );
      await click(onHighlight);
      await until(
        () => menu()?.color == 'blue',
        'no menu on the PDF highlight',
      );
      await click(button('Remove highlight'));
      await until(
        () => find.text('Remove').evaluate().isNotEmpty,
        'no confirm',
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
      await click(tester.getCenter(find.text('Remove')));
      await until(
        () => highlights(paper).isEmpty,
        'a real click did not remove in the PDF',
      );
      await tester.pumpWidget(const SizedBox());
    } finally {
      // The binding requires it back off before the test ends.
      binding.shouldPropagateDevicePointerEvents = false;
    }
  });
}

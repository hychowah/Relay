// Mac check of the Browser tab's PDF viewer and highlights against a real
// WKWebView and PDFKit. Run it from WSL with
// `npm run test:mac -- pdf_viewer_test.dart`, which builds under its own
// bundle id. A Browser tab refuses loopback fixtures, so it opens public
// pages (one arXiv paper, as a PDF and as a web page) and the Mac needs the
// internet. Highlights go to a loopback stand-in for the Relay server: no
// real server, no records.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:relay_flutter/highlight_menu.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

const installedBundleId = 'app.relay.flutterExperiment';
// A fixed version, so the pages stay as the checks expect. arXiv redirects
// the same address with `.pdf` added to this one.
const paper = 'https://arxiv.org/pdf/1301.3781v3';
const site = 'https://arxiv.org/abs/1301.3781v3';
const title = 'Efficient Estimation of Word Representations in Vector Space';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a Browser tab shows PDFs in the Mac viewer and keeps highlights', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'Run on macOS.');
    expect(
      (await PackageInfo.fromPlatform()).packageName,
      isNot(installedBundleId),
      reason: "Run through npm run test:mac so the installed app's data stays untouched.",
    );

    // The Relay server's highlight list and save; every other call is
    // accepted.
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
      }
      request.response.statusCode = reply == null ? 204 : 200;
      if (reply != null) request.response.write(jsonEncode(reply));
      await request.response.close();
    });
    List<Json> highlights(String url) => kept[url] ?? const [];

    final page = createWebPage(
      PageSpec(
        id: 'pdf-tab',
        appId: 'browser',
        name: 'Browser',
        sessionId: 'pdf-check',
        relayOrigin: Uri.parse('http://127.0.0.1:9'),
      ),
      (_) {},
      records: RelayApi(Uri.parse('http://127.0.0.1:${server.port}')),
    );
    addTearDown(page.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 900, height: 640, child: page.widget),
          ),
        ),
      ),
    );
    await page.ready.timeout(const Duration(seconds: 20));
    final browser = page.browser!;
    final controller = (page as dynamic).controller as WebViewController;
    final viewId =
        (controller.platform as WebKitWebViewController).webViewIdentifier;
    const channel = MethodChannel('app.relay/browser');
    // Debug builds can select the whole PDF; a test cannot drag over it.
    Future<void> selectAll() =>
        channel.invokeMethod<void>('pdf', {'view': viewId, 'do': 'selectAll'});

    Future<void> until(
      bool Function() done,
      String reason, {
      int seconds = 15,
    }) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (!done()) {
        expect(DateTime.now().isBefore(deadline), isTrue, reason: reason);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    }

    Future<void> wait(int seconds) async {
      await Future<void>.delayed(Duration(seconds: seconds));
      await tester.pump();
    }

    String selection() => page.context!['selection'] as String;
    HighlightMenu? menu() =>
        (page.widget as Stack).children.whereType<HighlightMenu>().firstOrNull;
    Future<void> openPaper() async {
      await browser.navigate(paper);
      await until(() => browser.pdf, 'the viewer did not open', seconds: 60);
    }

    // The viewer names the tab and gives the agent the PDF's text.
    await openPaper();
    expect(page.url, startsWith(paper));
    expect(page.title, isNot('Browser'));
    final read = await browser.read();
    expect(read['text'], contains('Word Representations'));
    expect(read['title'], page.title);
    expect((read['pdf'] as Map)['page'], 1);
    expect((read['pdf'] as Map)['pages'], greaterThan(5));
    expect(read['selection'], '');

    // Selected text reaches the page context as it is selected, and a read.
    await selectAll();
    await until(
      () => selection().contains('Word Representations'),
      'the selection did not reach Relay',
    );
    expect(
      (await browser.read())['selection'],
      contains('Word Representations'),
    );

    // A capture shows the viewer, not the page under it; zoom changes it.
    Future<Uint8List> shown() async {
      await wait(1);
      return page.snapshot();
    }

    final before = await shown();
    final frame = await (await ui.instantiateImageCodec(before)).getNextFrame();
    final pixels = (await frame.image.toByteData())!;
    final colours = <int>{
      for (var at = 0; at + 4 <= pixels.lengthInBytes; at += 4 * 97)
        pixels.getUint32(at),
    };
    expect(colours.length, greaterThan(8), reason: 'The capture shows no page');
    await browser.browserAction('zoomIn');
    expect(await shown(), isNot(before), reason: 'Zoom in changed nothing');
    await browser.browserAction('zoomOut');
    await browser.browserAction('zoomFit');

    // The menu shows by the selected text. A colour there marks the text,
    // clears the selection and keeps the highlight on the server with its
    // colour and where its lines are.
    final unmarked = await shown();
    await until(() => menu() != null, 'no menu by the selected text');
    menu()!.onColor('green');
    await until(() => selection().isEmpty, 'highlighting kept the selection');
    expect(menu(), isNull);
    expect(await shown(), isNot(unmarked), reason: 'No highlight showed');
    final saved = highlights(paper).single;
    expect(saved['text'], contains('Word Representations'));
    expect(saved['color'], 'green');
    expect(saved['marks'], isNotEmpty);

    // A load that starts and fails leaves the PDF and its viewer in place.
    unawaited(controller.loadRequest(Uri.parse('https://192.0.2.1/')));
    await wait(2);
    expect(browser.pdf, isTrue, reason: 'A load that only started closed it');
    expect((await browser.read())['pdf'], isNotNull);
    await controller.runJavaScript('window.stop()');

    // Opened again, the PDF has its highlight back: removing it changes
    // what shows. A click on it opens its menu, which a test cannot do on a
    // native view; the unit tests cover that menu.
    await openPaper();
    await wait(1);
    final marked = await shown();
    await channel.invokeMethod<void>('pdf', {
      'view': viewId,
      'do': 'remove',
      'id': saved['id'],
    });
    expect(
      await shown(),
      isNot(marked),
      reason: 'the kept highlight was not drawn again',
    );

    // A web page: the highlight quotes the selected text, is painted without
    // changing the page, and follows the page when it draws itself again.
    await browser.navigate(site);
    await until(() => page.title.contains(title), 'the site did not load');
    expect(browser.pdf, isFalse);
    Future<String> painted() async {
      final ranges = await controller.runJavaScriptReturningResult(
        "String([...(CSS.highlights.get('relay-highlight-yellow') ?? [])]"
        ".map((range) => range.startContainer.isConnected + ' ' + range.toString().replace(/\\s+/g, ' ').trim()))",
      );
      return '$ranges'.replaceAll('"', '');
    }

    Future<String> markup() async =>
        '${await controller.runJavaScriptReturningResult("document.querySelector('h1.title').outerHTML")}';
    await wait(1);
    final written = await markup();
    await controller.runJavaScript(
      "getSelection().selectAllChildren(document.querySelector('h1.title'))",
    );
    await until(() => selection().contains(title), 'nothing was selected');
    await until(() => menu() != null, 'no menu by the selected page text');
    await browser.browserAction('highlight');
    await until(() => selection().isEmpty, 'highlighting kept the selection');
    final quoted = highlights(site).single['text'] as String;
    expect(quoted, endsWith(title));
    expect(highlights(site).single.containsKey('marks'), isFalse);
    expect(await painted(), 'true $quoted');
    expect(await markup(), written, reason: 'The page itself was changed');
    await controller.runJavaScript(
      'document.body.innerHTML = document.body.innerHTML',
    );
    await wait(1);
    expect(await painted(), 'true $quoted', reason: 'Lost on a redraw');
    await browser.navigate(site);
    await wait(2);
    expect(await painted(), 'true $quoted', reason: 'Not shown again');

    // A new page takes the tab back from the viewer as soon as it begins,
    // here while one of its pictures never arrives.
    await openPaper();
    unawaited(
      controller.loadHtmlString(
        '<!doctype html><title>Slow</title><body>Slow page'
        '<img src="https://192.0.2.1/never.png">',
      ),
    );
    await until(() => !browser.pdf, 'the new page stayed under the viewer');
    await controller.runJavaScript('window.stop()');

    // The viewer's own fetch gives up when the address redirects: it could
    // lead somewhere the Browser's address rule would refuse. Last, because
    // it leaves the tab without its viewer.
    await openPaper();
    await controller.runJavaScript(
      "history.replaceState(null, '', location.pathname + '.pdf')",
    );
    expect(await controller.currentUrl(), '$paper.pdf');
    expect(
      await channel.invokeMethod<Object?>('pdf', {
        'view': viewId,
        'do': 'open',
      }),
      isNull,
      reason: 'The fetch followed a redirect',
    );
    await tester.pumpWidget(const SizedBox());
  });
}

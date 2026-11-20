// Mac check of the Browser tab's PDF viewer against a real WKWebView and
// PDFKit. Run it from WSL with `npm run test:mac -- pdf_viewer_test.dart`,
// which builds under its own bundle id. A Browser tab refuses loopback
// fixtures, so it opens one public PDF and the Mac needs the internet. It
// uses no Relay server and no records.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

const installedBundleId = 'app.relay.flutterExperiment';
// A fixed version, so the pages stay as the checks expect.
const paper = 'https://arxiv.org/pdf/2008.08324v1';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a PDF in a Browser tab opens in the Mac PDF viewer', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'Run on macOS.');
    expect(
      (await PackageInfo.fromPlatform()).packageName,
      isNot(installedBundleId),
      reason: "Run through npm run test:mac so the installed app's data stays untouched.",
    );

    final page = createWebPage(
      PageSpec(
        id: 'pdf-tab',
        appId: 'browser',
        name: 'Browser',
        sessionId: 'pdf-check',
        relayOrigin: Uri.parse('http://127.0.0.1:9'),
      ),
      (_) {},
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
    // Debug builds can select the whole PDF; a test cannot drag over it.
    Future<void> selectAll() => const MethodChannel(
      'app.relay/browser',
    ).invokeMethod<void>('pdf', {'view': viewId, 'do': 'selectAll'});

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

    String selection() => page.context!['selection'] as String;

    // The viewer names the tab and gives the agent the PDF's text.
    await browser.navigate(paper);
    await until(() => browser.pdf, 'the viewer did not open', seconds: 60);
    expect(page.url, startsWith(paper));
    expect(page.title, isNot('Browser'));
    final read = await browser.read();
    expect(read['text'], contains('FrankMocap'));
    expect(read['title'], page.title);
    expect((read['pdf'] as Map)['page'], 1);
    expect((read['pdf'] as Map)['pages'], greaterThan(5));
    expect(read['selection'], '');

    // Selected text reaches the page context as it is selected, and a read.
    await selectAll();
    await until(
      () => selection().contains('FrankMocap'),
      'the selection did not reach Relay',
    );
    expect((await browser.read())['selection'], contains('FrankMocap'));

    // A capture shows the viewer, not the page under it; zoom changes it.
    Future<Uint8List> shown() async {
      await Future<void>.delayed(const Duration(seconds: 1));
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

    // Highlighting marks the selected text and clears the selection; on
    // marked text it removes the marks. Nothing else differs between the two
    // captures.
    await browser.browserAction('highlight');
    await until(() => selection().isEmpty, 'highlighting kept the selection');
    final marked = await shown();
    await selectAll();
    await until(() => selection().isNotEmpty, 'nothing was selected');
    await browser.browserAction('highlight');
    await until(() => selection().isEmpty, 'removing kept the selection');
    expect(await shown(), isNot(marked), reason: 'No highlight showed');

    // Any other page takes the tab back from the viewer.
    await controller.loadHtmlString(
      '<!doctype html><title>Plain</title><body>Plain page',
    );
    await until(() => page.title == 'Plain', 'the web page did not load');
    expect(browser.pdf, isFalse);
    final plain = await browser.read();
    expect(plain['text'], contains('Plain page'));
    expect(plain.containsKey('pdf'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}

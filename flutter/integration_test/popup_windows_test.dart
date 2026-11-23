// Mac check of Browser popup windows against real WKWebViews. Run it from WSL
// with `npm run test:mac -- popup_windows_test.dart`, which builds under its
// own bundle id so it cannot read or write the installed app's settings and
// data. It uses only a loopback fixture server: no Relay server, no records.
import 'dart:io';

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a Browser popup is a real child window of its tab', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'Run on macOS.');
    expect(
      (await PackageInfo.fromPlatform()).packageName,
      isNot(installedBundleId),
      reason: "Run through npm run test:mac so the installed app's data stays untouched.",
    );

    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests.add(request.uri.path);
      request.response.headers.contentType = ContentType.html;
      // The popup reports its size, then on request says goodbye and closes.
      request.response.write(
        request.uri.path == '/popup'
            ? '''<!doctype html><title>Popup</title><body>Popup page<script>
                 opener.postMessage('ready ' + innerWidth + 'x' + innerHeight, '*');
                 addEventListener('message', (e) => {
                   if (e.data !== 'close') return;
                   opener.postMessage('bye', '*');
                   window.close();
                 });
               </script>'''
            : 'Unexpected page',
      );
      await request.response.close();
    });
    final fixture = 'http://127.0.0.1:${server.port}';
    // localhost is a loopback address too, so the real address rule refuses
    // it. Only the fixture's own popup address is let through.
    const channel = MethodChannel('app.relay/browser');
    Future<Object?> allow(MethodCall call) async =>
        call.method == 'allowPopupPage' &&
            (call.arguments as Map)['url'] == '$fixture/popup'
        ? true
        : browserChannelCall(call);

    final page = createWebPage(
      PageSpec(
        id: 'popup-tab',
        appId: 'browser',
        name: 'Browser',
        sessionId: 'popup-check',
        relayOrigin: Uri.parse('http://127.0.0.1:9'),
      ),
      (_) {},
    );
    var disposed = false;
    addTearDown(() => disposed ? null : page.dispose());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: page.widget)));
    await page.ready.timeout(const Duration(seconds: 20));
    channel.setMethodCallHandler(allow);
    final browser = page.browser!;
    // The test reaches the real tab's own WebKit controller.
    final controller = (page as dynamic).controller as WebViewController;
    final viewId =
        (controller.platform as WebKitWebViewController).webViewIdentifier;
    Future<int?> openPopups() => channel.invokeMethod<int>('popups', viewId);

    Future<void> until(
      Future<bool> Function() done,
      String reason, {
      int seconds = 15,
    }) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (!await done()) {
        expect(DateTime.now().isBefore(deadline), isTrue, reason: reason);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    }

    Future<void> title(String expected, String reason) => until(
      () async => page.title == expected,
      '$reason (title: ${page.title})',
    );

    // The opener is a local document, so the tab accepts it; the address
    // rule still decides every page a popup loads. The unsized new windows go
    // to a public documentation address (TEST-NET-1) that the tab's rule
    // accepts; its load only starts, which is enough to see where it went.
    const elsewhere = 'http://192.0.2.1';
    var loads = 0;
    Future<void> loadOpener() async {
      loads++;
      await controller.loadHtmlString('''<!doctype html><title>Opener</title>
      <body>Opener page <a id="tab-link" href="$elsewhere/tab-link" target="_blank">New tab</a><script>
        const auto = window.open('$fixture/auto');
        document.title = (auto ? 'auto opened' : 'auto blocked') + ' $loads';
        let popup, privatePopup;
        addEventListener('message', (e) => { document.title = 'message ' + e.data; });
        function openPopup() {
          popup = window.open('$fixture/popup', 'relay-popup', 'width=480,height=520');
          if (!popup) document.title = 'not opened';
        }
        function openPrivate() {
          privatePopup = window.open('http://localhost:${server.port}/private', '', 'width=400');
          document.title = privatePopup ? 'private opened' : 'private not opened';
        }
      </script>''');
      await title(
        'auto blocked $loads',
        'A popup opened without a user action must stay blocked',
      );
    }

    await loadOpener();

    // Scripts run by the app count as a user action in WebKit; if not, the
    // title reads 'not opened'.
    await controller.runJavaScript('openPopup()');
    await title(
      'message ready 480x520',
      'The popup must load beside its opener at the size it asked for, '
          'and reach it through window.opener',
    );
    expect(await openPopups(), 1);
    expect(page.url, 'about:blank', reason: 'The opener was replaced');
    expect((await browser.read())['text'], contains('Opener page'));

    // The opener's handle reaches the popup, which closes itself.
    await controller.runJavaScript("popup.postMessage('close', '*')");
    await title('message bye', 'The popup did not answer its opener');
    await until(
      () async => await openPopups() == 0,
      'window.close() must close the popup window',
    );
    expect(page.url, 'about:blank');

    // Page dialogs still reach Relay through the plugin's delegate.
    await controller.runJavaScript(
      "setTimeout(() => { document.title = confirm('Keep going?') ? 'confirmed' : 'declined' })",
    );
    await until(
      () async => find.text('Keep going?').evaluate().isNotEmpty,
      'The page confirm dialog did not reach Relay',
    );
    await tester.tap(find.text('OK'));
    await title('confirmed', 'The confirm dialog did not answer the page');

    // A popup to a private address is refused before any request.
    await controller.runJavaScript('openPrivate()');
    await title('private opened', 'WebKit did not create the private popup');
    await until(
      () async => await openPopups() == 0,
      'A popup refused by the address rule must close',
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(requests, ['/popup'], reason: 'Only the allowed popup may load');

    // A new window without a size is a new-tab request: it loads in the
    // opener's own tab through the tab's address rule, as before popups.
    for (final (script, path) in [
      ("document.getElementById('tab-link').click()", 'tab-link'),
      ("window.open('$elsewhere/unsized')", 'unsized'),
    ]) {
      await controller.runJavaScript(script);
      expect(await openPopups(), 0, reason: '$path must not open a popup');
      await until(
        () async => page.url == '$elsewhere/$path',
        '$path must load in the same tab (address: ${page.url})',
      );
      expect(await openPopups(), 0, reason: '$path must not open a popup');
      await loadOpener();
    }

    // Closing the tab closes its popups.
    await controller.runJavaScript('openPopup()');
    await title('message ready 480x520', 'The second popup did not load');
    expect(await openPopups(), 1);
    page.dispose();
    disposed = true;
    await until(
      () async => await openPopups() == 0,
      'Closing the tab must close its popups',
    );
  });
}

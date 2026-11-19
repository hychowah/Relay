// Mac check of page fullscreen in a Browser tab against a real WKWebView and
// the real window. Run it from WSL with
// `npm run test:mac -- video_fullscreen_test.dart`, which builds under its own
// bundle id. It loads only a local page: no Relay server, no records. The
// window goes into macOS fullscreen for a few seconds.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:webview_flutter/webview_flutter.dart';

const installedBundleId = 'app.relay.flutterExperiment';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a fullscreen video fills its pane, then the whole screen', (
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
        id: 'video-tab',
        appId: 'browser',
        name: 'Browser',
        sessionId: 'fullscreen-check',
        relayOrigin: Uri.parse('http://127.0.0.1:9'),
      ),
      (_) {},
    );
    addTearDown(page.dispose);
    // The tab's pane in a split.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 640, height: 360, child: page.widget),
          ),
        ),
      ),
    );
    await page.ready.timeout(const Duration(seconds: 20));
    final browser = page.browser!;
    final controller = (page as dynamic).controller as WebViewController;

    Future<void> until(bool Function() done, String reason) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!done()) {
        expect(DateTime.now().isBefore(deadline), isTrue, reason: reason);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    }

    Future<List<Object?>> measure() async {
      final raw = await controller.runJavaScriptReturningResult('''(() => {
        const r = document.getElementById('player').getBoundingClientRect();
        return JSON.stringify([innerWidth, innerHeight, r.x, r.y, r.width, r.height,
          document.elementFromPoint(20, 20)?.id ?? null, document.fullscreenElement?.id ?? null]);
      })()''');
      dynamic data = raw is String ? jsonDecode(raw) : raw;
      if (data is String) data = jsonDecode(data);
      return data as List<Object?>;
    }

    // A player in a transformed column below a fixed header, as on video
    // sites. The script that adds fullscreen runs before the page's own.
    await controller.loadHtmlString('''<!doctype html><title>Video</title>
      <style>body{margin:0}header{position:fixed;inset:0 0 auto;height:60px;z-index:9;background:#ddd}
      main{transform:translateX(0);margin:80px 0 0 30px;width:240px}</style>
      <header id="header">Header</header>
      <main><div id="player" style="height:135px;background:#246"></div></main>
      <script>
        document.title = document.fullscreenEnabled ? 'ready' : 'no fullscreen';
        // Without a click or key press, the page cannot take the screen.
        document.getElementById('player').requestFullscreen()
          .then(() => document.title = 'taken without a click', () => {});
      </script>''');
    await until(
      () => page.title == 'ready',
      'fullscreen is off (${page.title})',
    );
    expect(await measure(), [640, 360, 30, 80, 240, 135, 'header', null]);

    // A page's own message cannot take the screen: only the script's carry
    // the tab's key.
    await controller.runJavaScript(
      "RelayBrowser.postMessage('fullscreen:enter'); "
      "RelayBrowser.postMessage('fullscreen:enter:guess')",
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(browser.fullScreen, isFalse);

    // Scripts run by the app count as a user action in WebKit.
    await controller.runJavaScript(
      "document.getElementById('player').requestFullscreen()",
    );
    await until(() => browser.fullScreen, 'the page did not tell Relay');
    expect(await measure(), [640, 360, 0, 0, 640, 360, 'player', 'player']);

    // Shown on the whole screen, the window takes the screen. Escape ends
    // the page's fullscreen, and stopping returns the window.
    final view = tester.binding.platformDispatcher.views.first;
    final window = view.physicalSize;
    await browser.fillScreen(true);
    await until(
      () => view.physicalSize.width > window.width + 50,
      'the window did not go fullscreen',
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    await controller.runJavaScript(
      "dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape'}))",
    );
    await until(() => !browser.fullScreen, 'Escape did not end it');
    await browser.fillScreen(false);
    await until(
      () => view.physicalSize == window,
      'the window stayed fullscreen',
    );
    expect(await measure(), [640, 360, 30, 80, 240, 135, 'header', null]);

    // Starting used up the action: asking again at once stays out. An app
    // script is no click, so the page gets in only once WebKit's 5-second
    // activation has run out. Stopping the screen also ends it.
    Future<void> askAgain(String outcome) async {
      await controller.runJavaScript(
        "document.getElementById('player').requestFullscreen()"
        ".then(() => document.title = 'in', () => document.title = 'out')",
      );
      await until(() => page.title == outcome, 'asking again: ${page.title}');
    }

    await askAgain('out');
    expect(browser.fullScreen, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 5200));
    await askAgain('in');
    await until(() => browser.fullScreen, 'the page did not tell Relay again');
    await browser.fillScreen(false);
    expect(browser.fullScreen, isFalse);
    expect(await measure(), [640, 360, 30, 80, 240, 135, 'header', null]);
    await tester.pumpWidget(const SizedBox());
  });
}

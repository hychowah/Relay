// Windows check of page fullscreen in a Browser tab against a real WebView2
// and the real window. Run it on Windows from a copy of flutter/ on the
// Windows drive with
// `flutter test integration_test/windows_fullscreen_test.dart -d windows`.
// It loads only its own page into a temporary WebView2 data folder: no Relay
// server and none of the app's settings, records or sign-ins. The window
// covers the screen for a few seconds and gets a real Escape key press.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:relay_flutter/windows_web_view.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a fullscreen video fills its pane, then the whole screen', (
    tester,
  ) async {
    expect(Platform.isWindows, isTrue, reason: 'Run on Windows.');
    final data = await Directory.systemTemp.createTemp('relay-webview-test.');
    await registerWindowsWebView(data.path);

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
            child: SizedBox(
              key: const Key('pane'),
              width: 640,
              height: 360,
              child: page.widget,
            ),
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
          document.fullscreenElement?.id ?? null]);
      })()''');
      dynamic data = raw is String ? jsonDecode(raw) : raw;
      if (data is String) data = jsonDecode(data);
      return data as List<Object?>;
    }

    // A player whose button asks for fullscreen, as on video sites. Without
    // a click, the page cannot take the screen.
    await controller.loadHtmlString('''<!doctype html><title>Video</title>
      <style>body{margin:0}#player{margin:80px 0 0 30px;width:240px;height:135px;background:#246}</style>
      <div id="player" onclick="this.requestFullscreen()"></div>
      <script>
        document.title = 'ready';
        document.getElementById('player').requestFullscreen()
          .then(() => document.title = 'taken without a click', () => {});
      </script>''');
    await until(() => page.title == 'ready', 'the page did not load');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(browser.fullScreen, isFalse);
    expect(await measure(), [640, 360, 30, 80, 240, 135, null]);

    // A click on the player fills the pane.
    final player =
        tester.getTopLeft(find.byKey(const Key('pane'))) +
        const Offset(100, 120);
    Future<void> click() => tester.tapAt(player, kind: PointerDeviceKind.mouse);
    final view = tester.binding.platformDispatcher.views.first;
    final window = view.physicalSize;
    Future<void> fill() async {
      await browser.fillScreen(true);
      await until(
        () => view.physicalSize.width > window.width + 50,
        'the window did not cover the screen',
      );
    }

    Future<void> giveBack() async {
      await browser.fillScreen(false);
      await until(
        () => view.physicalSize == window,
        'the window stayed on the whole screen',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(await measure(), [640, 360, 30, 80, 240, 135, null]);
    }

    await click();
    await until(() => browser.fullScreen, 'the page did not tell Relay');
    expect(await measure(), [640, 360, 0, 0, 640, 360, 'player']);

    // Shown on the whole screen, the window covers it. Stopping, as when
    // another tab opens, ends the page's fullscreen and gives the window back.
    await fill();
    await giveBack();
    expect(browser.fullScreen, isFalse);

    // A real Escape ends it too.
    await Future<void>.delayed(const Duration(seconds: 1));
    await click();
    await until(() => browser.fullScreen, 'the page did not tell Relay again');
    await fill();
    await Future<void>.delayed(const Duration(seconds: 2));
    _pressEscape();
    await until(() => !browser.fullScreen, 'Escape did not end it');
    await giveBack();
    await tester.pumpWidget(const SizedBox());
  });
}

final _user32 = DynamicLibrary.open('user32.dll');

/// Presses Escape through Windows itself, so it reaches the focused page as a
/// person's key press would.
void _pressEscape() {
  final foreground = _user32.lookupFunction<IntPtr Function(), int Function()>(
    'GetForegroundWindow',
  );
  final owner = _user32
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');
  final memory = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<IntPtr Function(Uint32, IntPtr), int Function(int, int)>(
        'LocalAlloc',
      );
  // The key goes to whichever window is in front; never press it in another
  // program. The 4 bytes are not freed; the test ends soon after.
  final process = Pointer<Uint32>.fromAddress(memory(0x40, 4));
  owner(foreground(), process);
  expect(process.value, pid, reason: 'Another program is in front.');
  final press = _user32
      .lookupFunction<
        Void Function(Uint8, Uint8, Uint32, IntPtr),
        void Function(int, int, int, int)
      >('keybd_event');
  // WebView2 ignores a key without its scan code, which keyboards always send.
  const escape = 0x1B, scanCode = 0x01, keyUp = 0x0002;
  press(escape, scanCode, 0, 0);
  press(escape, scanCode, keyUp, 0);
}

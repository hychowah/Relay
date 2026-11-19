import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/browser_transcript.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class TestWebPlatform extends WebViewPlatform {
  late TestController controller;
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller = TestController(params);
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => TestNavigationDelegate(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => TestWebViewWidget(params);
}

class TestWebViewWidget extends PlatformWebViewWidget {
  TestWebViewWidget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class TestController extends PlatformWebViewController {
  TestController(super.params) : super.implementation();
  late JavaScriptChannelParams channel;
  late TestNavigationDelegate delegate;
  var location = 'https://youtube.test/', history = false;
  final loaded = Completer<void>();
  final scripts = <String>[];
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  late Future<void> Function(JavaScriptAlertDialogRequest) alert;
  late Future<bool> Function(JavaScriptConfirmDialogRequest) confirm;
  @override
  Future<void> setOnJavaScriptAlertDialog(
    Future<void> Function(JavaScriptAlertDialogRequest) callback,
  ) async => alert = callback;
  @override
  Future<void> setOnJavaScriptConfirmDialog(
    Future<bool> Function(JavaScriptConfirmDialogRequest) callback,
  ) async => confirm = callback;
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async => this.delegate = delegate as TestNavigationDelegate;
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    channel = params;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loaded.complete();
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {}
  @override
  Future<void> runJavaScript(String javaScript) async =>
      scripts.add(javaScript);
  Object playTime = -1;
  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async =>
      javaScript == youtubePlaybackTimeScript
      ? playTime
      : jsonEncode({'url': location, 'title': 'YouTube', 'selection': ''});
  @override
  Future<bool> canGoBack() async => history;
  @override
  Future<bool> canGoForward() async => false;

  void emit(Json data) =>
      channel.onMessageReceived(JavaScriptMessage(message: jsonEncode(data)));
}

class TestNavigationDelegate extends PlatformNavigationDelegate {
  TestNavigationDelegate(super.params) : super.implementation();
  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {}
  late PageEventCallback finished;
  late UrlChangeCallback urlChange;
  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {}
  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async =>
      finished = callback;
  @override
  Future<void> setOnUrlChange(UrlChangeCallback callback) async =>
      urlChange = callback;
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}
}

void main() {
  test('public browser identity follows the installed Safari and WebKit', () {
    const base =
        'Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko)';
    const expected = '$base Version/26.6 Safari/605.1.15';
    expect(safariUserAgent(base, '26.6.2'), expected);
    expect(safariUserAgent(base, null), isNull);
    expect(safariUserAgent(expected, '26.6.2'), isNull);
  });

  test('popup pages follow the Browser address rule', () async {
    Future<Object?> ask(String url) =>
        browserChannelCall(MethodCall('allowPopupPage', url));
    for (final url in [
      'http://127.0.0.1:8080/',
      'http://localhost/',
      'http://10.1.2.3/',
      'http://192.168.0.2/',
      'http://169.254.169.254/latest',
      'http://100.100.1.1/',
      'http://[::1]/',
      'https://user@8.8.8.8/',
      'file:///etc/hosts',
      'javascript:alert(1)',
      'data:text/html,hi',
    ]) {
      expect(await ask(url), isFalse, reason: url);
    }
    expect(await ask('about:blank'), isTrue);
    expect(await ask('https://8.8.8.8/sign-in'), isTrue);
    expect(
      () => browserChannelCall(const MethodCall('other')),
      throwsA(isA<MissingPluginException>()),
    );
  });

  test(
    'only matching native initialization avoids manual invalidation',
    () async {
      const source = {
        'appId': 'research',
        'resourceId': 'report',
        'revision': 'saved',
      };
      final platform = TestWebPlatform();
      WebViewPlatform.instance = platform;
      for (final scenario in [
        (native: false, source: source, initialManual: true),
        (native: true, source: source, initialManual: false),
        (
          native: true,
          source: {...source, 'revision': 'other'},
          initialManual: true,
        ),
        (native: true, source: null, initialManual: true),
      ]) {
        final changes = <bool>[];
        final page = createWebPage(
          PageSpec(
            id: 'frame',
            appId: 'research',
            name: 'Research',
            sessionId: 'session',
            relayOrigin: Uri.parse('http://relay.test'),
            appView: {'native': scenario.native, 'url': 'http://app.test/view'},
            report: {'source': source},
          ),
          changes.add,
        );
        addTearDown(page.dispose);
        await platform.controller.loaded.future;
        platform.controller.emit({'type': 'relay.ready', 'token': 'frame'});
        await page.ready;
        final context = <String, dynamic>{
          'type': 'relay.context',
          'token': 'frame',
          if (scenario.source != null) 'source': scenario.source,
          'selection': 'Selected evidence',
        };
        platform.controller.emit(context);
        expect(changes.last, scenario.initialManual);
        expect(page.context!['selection'], 'Selected evidence');
        platform.controller.emit(context);
        expect(changes.last, isTrue);
      }
    },
  );

  test(
    'a Browser address changed by the page is not a manual change',
    () async {
      final platform = TestWebPlatform();
      WebViewPlatform.instance = platform;
      final changes = <bool>[];
      final page = createWebPage(
        PageSpec(
          id: 'tab',
          appId: 'browser',
          name: 'Browser',
          sessionId: 'session',
          relayOrigin: Uri.parse('http://relay.test'),
        ),
        changes.add,
      );
      addTearDown(page.dispose);
      final controller = platform.controller;
      await pumpEventQueue();
      controller.delegate.finished(controller.location);
      await page.ready;
      final generation = page.context!['generation'];
      changes.clear();

      controller
        ..location = 'https://youtube.test/watch?v=1'
        ..history = true;
      controller.delegate.urlChange(UrlChange(url: controller.location));
      await pumpEventQueue();
      expect(page.url, 'https://youtube.test/watch?v=1');
      expect(page.browser!.canGoBack, isTrue);

      controller.channel.onMessageReceived(
        const JavaScriptMessage(message: 'title:A video'),
      );
      expect(page.title, 'A video');
      expect(page.context!['state'], {
        'sessionId': 'session',
        'tabId': 'tab',
        'url': 'https://youtube.test/watch?v=1',
        'title': 'A video',
      });
      expect(changes, [false, false]);
      expect(page.context!['generation'], generation);
    },
  );

  test('a Browser transcript arrives through the page channel', () async {
    final platform = TestWebPlatform();
    WebViewPlatform.instance = platform;
    final page = createWebPage(
      PageSpec(
        id: 'tab',
        appId: 'browser',
        name: 'Browser',
        sessionId: 'session',
        relayOrigin: Uri.parse('http://relay.test'),
      ),
      (_) {},
    );
    addTearDown(page.dispose);
    final controller = platform.controller;
    await pumpEventQueue();
    controller.delegate.finished(controller.location);
    await page.ready;

    Future<Json> answer(Json reply) async {
      final result = page.browser!.loadTranscript();
      await pumpEventQueue();
      final id = RegExp(r'id:"(\d+)"').firstMatch(controller.scripts.last)![1];
      controller.channel.onMessageReceived(
        JavaScriptMessage(
          message: 'transcript:${jsonEncode({'id': id, ...reply})}',
        ),
      );
      return result;
    }

    final transcript = await answer({
      'data': {
        'url': 'u',
        'title': 'Video',
        'language': 'English',
        'segments': [
          {'time': '0:01', 'text': 'Hello'},
          {'time': '0:04', 'text': 'there'},
        ],
      },
    });
    expect(transcript, {
      'url': 'u',
      'title': 'Video',
      'language': 'English',
      'text': '[0:01] Hello there',
    });

    await expectLater(
      answer({'error': 'This video has no captions.'}),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'This video has no captions.',
        ),
      ),
    );

    // The pane's play time; the page script answers -1 during an ad.
    controller.playTime = 83.5;
    expect(await page.browser!.playbackTime(), 83.5);
    controller.playTime = -1;
    expect(await page.browser!.playbackTime(), isNull);
  });

  testWidgets('page dialogs name the site and answer with the choice', (
    tester,
  ) async {
    final platform = TestWebPlatform();
    WebViewPlatform.instance = platform;
    final page = createWebPage(
      PageSpec(
        id: 'tab',
        appId: 'browser',
        name: 'Browser',
        sessionId: 'session',
        relayOrigin: Uri.parse('http://relay.test'),
      ),
      (_) {},
    );
    addTearDown(page.dispose);
    await tester.pumpWidget(MaterialApp(home: page.widget));
    final controller = platform.controller;
    const url = 'https://site.test/analyze';

    Future<T> answer<T>(Future<T> dialog, String button) async {
      await tester.pumpAndSettle();
      expect(find.text('site.test says'), findsOneWidget);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      return dialog;
    }

    const start = JavaScriptConfirmDialogRequest(message: 'Start?', url: url);
    expect(await answer(controller.confirm(start), 'OK'), isTrue);
    expect(await answer(controller.confirm(start), 'Cancel'), isFalse);

    await answer(
      controller.alert(
        const JavaScriptAlertDialogRequest(message: 'Done', url: url),
      ),
      'OK',
    );
    expect(find.byType(AlertDialog), findsNothing);
  });
}

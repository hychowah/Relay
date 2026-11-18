import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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
}

class TestController extends PlatformWebViewController {
  TestController(super.params) : super.implementation();
  late JavaScriptChannelParams channel;
  final loaded = Completer<void>();
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async {}
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    channel = params;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loaded.complete();
  }

  void emit(Json data) =>
      channel.onMessageReceived(JavaScriptMessage(message: jsonEncode(data)));
}

class TestNavigationDelegate extends PlatformNavigationDelegate {
  TestNavigationDelegate(super.params) : super.implementation();
  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {}
  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {}
  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {}
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
}

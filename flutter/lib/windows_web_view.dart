// Desktop only (Windows). The official webview_flutter plugin has no Windows
// implementation. webview_all_windows renders WebView2 into a Flutter texture,
// so Relay's own overlays draw over pages, and it can veto main-frame
// navigations, which the Browser's address rule needs. It implements a fork
// of webview_flutter's platform interface, so this file maps the calls Relay
// makes through webview_flutter onto it; the rest of the app is unchanged.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:webview_all_windows/webview_all_windows.dart' as win;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart'
    as all;

/// Makes webview_flutter use WebView2 on Windows, keeping its data (website
/// sign-ins, cookies, cache) in [dataFolder]. By default WebView2 keeps it
/// beside the program, which installing a new build replaces.
Future<void> registerWindowsWebView(String dataFolder) async {
  await win.WindowsWebViewController.ensureEnvironment(
    userDataPath: dataFolder,
  );
  WebViewPlatform.instance = _WindowsPlatform();
}

/// WebView2 loads [PlatformWebViewController.loadHtmlString] content as a
/// data: address; WKWebView and Android report it as about:blank, which is
/// what Relay's pages expect (the Browser's address rule allows only that).
/// Chromium blocks pages from opening a data: address in the main frame.
String _shown(String url) => url.startsWith('data:') ? 'about:blank' : url;

const _blockedPage =
    '<!doctype html><title>Blocked</title><body style="font:16px system-ui;'
    'padding:40px;color:#888">Relay blocked a private address in this tab.</body>';

T _same<T extends Enum>(List<T> values, Enum value, T fallback) {
  for (final candidate in values) {
    if (candidate.name == value.name) return candidate;
  }
  return fallback;
}

class _WindowsPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _Controller(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _NavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _Widget(params);
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();

  // Downloads would save files without asking; the Mac build has none.
  final inner = win.WindowsWebViewController(
    const win.WindowsWebViewControllerCreationParams(downloadsEnabled: false),
  );
  // Set by [loadHtmlString] until its page asks to load; see [_shown].
  bool _ownHtml = false;

  // The package lets the first load after Back, Forward or Reload through
  // without asking, and keeps that pass until a new document starts, which a
  // same-document move never does; a later load to any address can then use
  // it. So [_NavigationDelegate] asks the app's check again for every address
  // a page reaches. Page events and channel messages go through [_events] in
  // order, so nothing from a page reaches the app before its address passes;
  // while [_blocked], nothing reaches it at all. No step awaits the app's own
  // handlers, so a handler may wait for [_events] itself.
  Future<void> _events = Future.value();
  bool _blocked = false;
  // While blocked, later events of the same page are dropped without asking
  // again: an app page's check opens other sites in the system browser.
  String? _blockedUrl;

  void _then(FutureOr<void> Function() step) {
    _events = _events
        .then((_) => step())
        .catchError(
          (Object error, StackTrace stack) =>
              Zone.current.handleUncaughtError(error, stack),
        );
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) => inner.loadRequest(
    all.LoadRequestParams(
      uri: params.uri,
      method: _same(
        all.LoadRequestMethod.values,
        params.method,
        all.LoadRequestMethod.get,
      ),
      headers: params.headers,
      body: params.body,
    ),
  );

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) {
    _ownHtml = true;
    return inner.loadHtmlString(html, baseUrl: baseUrl);
  }

  @override
  Future<String?> currentUrl() => inner.currentUrl();
  @override
  Future<bool> canGoBack() => inner.canGoBack();
  @override
  Future<bool> canGoForward() => inner.canGoForward();
  @override
  Future<void> goBack() => inner.goBack();
  @override
  Future<void> goForward() => inner.goForward();
  @override
  Future<void> reload() => inner.reload();

  @override
  Future<void> runJavaScript(String javaScript) =>
      inner.runJavaScript(javaScript);
  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    await _events;
    if (_blocked) throw StateError('Relay blocked this page.');
    return inner.runJavaScriptReturningResult(javaScript);
  }

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) =>
      inner.addJavaScriptChannel(
        all.JavaScriptChannelParams(
          name: params.name,
          onMessageReceived: (message) => _then(() {
            if (_blocked) return;
            params.onMessageReceived(
              JavaScriptMessage(message: message.message),
            );
          }),
        ),
      );
  @override
  Future<void> removeJavaScriptChannel(String name) =>
      inner.removeJavaScriptChannel(name);

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) =>
      inner.setJavaScriptMode(
        _same(all.JavaScriptMode.values, mode, all.JavaScriptMode.unrestricted),
      );
  @override
  Future<void> setUserAgent(String? userAgent) => inner.setUserAgent(userAgent);
  @override
  Future<String?> getUserAgent() => inner.getUserAgent();

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) {
    final delegate = handler as _NavigationDelegate;
    delegate._controller = this;
    return inner.setPlatformNavigationDelegate(delegate.inner);
  }

  @override
  Future<void> setOnJavaScriptAlertDialog(
    Future<void> Function(JavaScriptAlertDialogRequest request)
    onJavaScriptAlertDialog,
  ) => inner.setOnJavaScriptAlertDialog(
    (request) => onJavaScriptAlertDialog(
      JavaScriptAlertDialogRequest(message: request.message, url: request.url),
    ),
  );

  @override
  Future<void> setOnJavaScriptConfirmDialog(
    Future<bool> Function(JavaScriptConfirmDialogRequest request)
    onJavaScriptConfirmDialog,
  ) => inner.setOnJavaScriptConfirmDialog(
    (request) => onJavaScriptConfirmDialog(
      JavaScriptConfirmDialogRequest(
        message: request.message,
        url: request.url,
      ),
    ),
  );
}

class _NavigationDelegate extends PlatformNavigationDelegate {
  _NavigationDelegate(super.params) : super.implementation();

  final inner = win.WindowsNavigationDelegate(
    const all.PlatformNavigationDelegateCreationParams(),
  );
  _Controller? _controller;
  NavigationRequestCallback? _check;
  PageEventCallback? _started, _finished;
  UrlChangeCallback? _urlChanged;
  bool _listening = false;

  /// Page events are always taken from the package, so that every address a
  /// page reaches is checked again (see [_Controller._events]); they are
  /// passed on only to the callbacks the app set.
  Future<void> _listen() {
    if (_listening) return Future.value();
    _listening = true;
    return Future.wait([
      inner.setOnPageStarted(
        (url) => _page(url, () => _started?.call(_shown(url))),
      ),
      inner.setOnPageFinished(
        (url) => _page(url, () => _finished?.call(_shown(url))),
      ),
      inner.setOnUrlChange((change) {
        final url = change.url;
        _page(url ?? '', () {
          _urlChanged?.call(UrlChange(url: url == null ? null : _shown(url)));
        });
      }),
    ]);
  }

  Future<bool> _allowed(String url) async {
    final check = _check;
    if (check == null ||
        url.isEmpty ||
        url == 'about:blank' ||
        url.startsWith('data:')) {
      return true;
    }
    final request = NavigationRequest(url: url, isMainFrame: true);
    return await check(request) == NavigationDecision.navigate;
  }

  void _page(String url, void Function() event) {
    final controller = _controller;
    if (controller == null) return event();
    controller._then(() async {
      if (controller._blocked && url == controller._blockedUrl) return;
      if (await _allowed(url)) {
        controller._blocked = false;
        event();
      } else {
        controller._blocked = true;
        controller._blockedUrl = url;
        unawaited(controller.loadHtmlString(_blockedPage));
      }
    });
  }

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) {
    _check = onNavigationRequest;
    // The package only turns its check on if this is set before the delegate
    // reaches the controller, which webview_flutter does without waiting.
    final check = inner.setOnNavigationRequest((request) async {
      // Only the page Relay itself asked for may load as a data: address.
      if (request.isMainFrame && request.url.startsWith('data:')) {
        final own = _controller?._ownHtml ?? false;
        _controller?._ownHtml = false;
        return own
            ? all.NavigationDecision.navigate
            : all.NavigationDecision.prevent;
      }
      // The package cancels the load and starts it again once allowed. Started
      // again at once, a server redirect (such as Google's sign-in link) is
      // dropped and the page stays as it was; 10 ms later it loads.
      final gap = Future<void>.delayed(const Duration(milliseconds: 50));
      final decision = await onNavigationRequest(
        NavigationRequest(url: request.url, isMainFrame: request.isMainFrame),
      );
      await gap;
      return _same(
        all.NavigationDecision.values,
        decision,
        all.NavigationDecision.prevent,
      );
    });
    return Future.wait([check, _listen()]);
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) {
    _started = onPageStarted;
    return _listen();
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) {
    _finished = onPageFinished;
    return _listen();
  }

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) =>
      inner.setOnProgress(onProgress);

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) => inner.setOnWebResourceError(
    (error) => onWebResourceError(
      WebResourceError(
        errorCode: error.errorCode,
        description: error.description,
        errorType: error.errorType == null
            ? null
            : _same(
                WebResourceErrorType.values,
                error.errorType!,
                WebResourceErrorType.unknown,
              ),
        isForMainFrame: error.isForMainFrame,
        url: error.url == null ? null : _shown(error.url!),
      ),
    ),
  );

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) {
    _urlChanged = onUrlChange;
    return _listen();
  }
}

class _Widget extends PlatformWebViewWidget {
  _Widget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => win.WindowsWebViewWidget(
    all.PlatformWebViewWidgetCreationParams(
      key: params.key,
      controller: (params.controller as _Controller).inner,
    ),
  ).build(context);
}

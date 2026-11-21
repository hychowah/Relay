// Desktop only (Windows). The official webview_flutter plugin has no Windows
// implementation. webview_all_windows renders WebView2 into a Flutter texture,
// so Relay's own overlays draw over pages, and it can veto main-frame
// navigations, which the Browser's address rule needs. It implements a fork
// of webview_flutter's platform interface, so this file maps the calls Relay
// makes through webview_flutter onto it; the rest of the app is unchanged.
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_all_windows/webview_all_windows.dart' as win;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart'
    as all;

/// Makes webview_flutter use WebView2 on Windows. WebView2 keeps its data,
/// such as website sign-ins, beside the program unless told otherwise, and
/// installing a new build replaces that folder.
Future<void> registerWindowsWebView() async {
  final support = await getApplicationSupportDirectory();
  await win.WindowsWebViewController.ensureEnvironment(
    userDataPath: '${support.path}\\WebView2',
  );
  WebViewPlatform.instance = _WindowsPlatform();
}

/// WebView2 loads [PlatformWebViewController.loadHtmlString] content as a
/// data: address; WKWebView and Android report it as about:blank, which is
/// what Relay's pages expect (the Browser's address rule allows only that).
/// Chromium blocks pages from opening a data: address in the main frame.
String _shown(String url) => url.startsWith('data:') ? 'about:blank' : url;

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

  final inner = win.WindowsWebViewController(
    const all.PlatformWebViewControllerCreationParams(),
  );
  // Set by [loadHtmlString] until its page asks to load; see [_shown].
  bool _ownHtml = false;

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
  Future<Object> runJavaScriptReturningResult(String javaScript) =>
      inner.runJavaScriptReturningResult(javaScript);

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) =>
      inner.addJavaScriptChannel(
        all.JavaScriptChannelParams(
          name: params.name,
          onMessageReceived: (message) => params.onMessageReceived(
            JavaScriptMessage(message: message.message),
          ),
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

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) => inner.setOnNavigationRequest((request) async {
    // Only the page Relay itself asked for may load as a data: address.
    if (request.isMainFrame && request.url.startsWith('data:')) {
      final own = _controller?._ownHtml ?? false;
      _controller?._ownHtml = false;
      return own
          ? all.NavigationDecision.navigate
          : all.NavigationDecision.prevent;
    }
    final decision = await onNavigationRequest(
      NavigationRequest(url: request.url, isMainFrame: request.isMainFrame),
    );
    return _same(
      all.NavigationDecision.values,
      decision,
      all.NavigationDecision.prevent,
    );
  });

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) =>
      inner.setOnPageStarted((url) => onPageStarted(_shown(url)));
  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) =>
      inner.setOnPageFinished((url) => onPageFinished(_shown(url)));
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
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) =>
      inner.setOnUrlChange(
        (change) => onUrlChange(
          UrlChange(url: change.url == null ? null : _shown(change.url!)),
        ),
      );
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

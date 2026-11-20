import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import 'browser_comment.dart';
import 'browser_transcript.dart';
import 'page_surface.dart';
import 'relay_api.dart';

const _readPage = '''JSON.stringify({url:location.href,title:document.title,
 selection:window.__relaySelection||window.getSelection()?.toString().slice(0,4000)||'',
 text:document.body?.innerText.slice(0,24000)||'',
 links:[...document.querySelectorAll('a[href]')].filter(a=>a.getClientRects().length).slice(0,60).map(a=>({text:a.innerText.slice(0,500),url:a.href.slice(0,2000)})),
 capturedAt:new Date().toISOString()})''';
const _observePage =
    '''(()=>{if(window.__relayObserved)return;window.__relayObserved=true;
 let timer;const notify=()=>{clearTimeout(timer);timer=setTimeout(()=>RelayBrowser.postMessage('interaction'),80)};
 const selection=()=>window.getSelection()?.toString().slice(0,4000)||'';
 document.addEventListener('selectionchange',()=>{
   const text=selection();
   if(text || document.hasFocus()) window.__relaySelection=text;
   RelayBrowser.postMessage('selection:'+(window.__relaySelection||''));
 },true);
 for(const type of ['pointerdown','keydown'])document.addEventListener(type,()=>{
   window.__relaySelection='';notify();
 },true);
 let title=document.title;
 new MutationObserver(()=>{if(document.title!==title){title=document.title;RelayBrowser.postMessage('title:'+title)}})
   .observe(document.head||document.documentElement,{childList:true,subtree:true,characterData:true});
})()''';

// Some sites serve a basic interface to WKWebView unless it identifies the
// Safari version. Preserve WebKit's own platform and engine tokens.
String? safariUserAgent(String? webKitAgent, String? safariVersion) {
  if (webKitAgent == null || webKitAgent.contains(' Safari/')) return null;
  final engine = RegExp(r'\bAppleWebKit/([\d.]+)\b').firstMatch(webKitAgent);
  final version = RegExp(r'^\d+(?:\.\d+)?').stringMatch(safariVersion ?? '');
  if (engine == null || version == null) return null;
  return '$webKitAgent Version/$version Safari/${engine[1]}';
}

// Main-frame navigation guard only. webview_flutter has no subresource
// interception, so this is not network isolation.
Future<Uri> browserUrl(String text) async {
  final value = text.trim();
  final uri = Uri.parse(
    value.contains('://')
        ? value
        : RegExp(
            r'^[\w.-]+\.[a-z]{2,}([/:?#]|$)',
            caseSensitive: false,
          ).hasMatch(value)
        ? 'https://$value'
        : 'https://www.google.com/search?q=${Uri.encodeQueryComponent(value)}',
  );
  if (!['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw Exception('Use a public HTTP or HTTPS website.');
  }
  final addresses = await InternetAddress.lookup(uri.host);
  bool privateAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }
    if (address.type == InternetAddressType.IPv4) {
      return b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          b[0] >= 224 ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
    }
    return b.every((n) => n == 0) ||
        (b[0] & 0xfe) == 0xfc ||
        (b.take(10).every((n) => n == 0) && b[10] == 255 && b[11] == 255);
  }

  if (addresses.isEmpty || addresses.any(privateAddress)) {
    throw Exception('Public browser tabs cannot open private addresses.');
  }
  return uri;
}

/// Whether a Browser tab or popup may load [url] in its main frame.
Future<bool> publicPageAllowed(String url) async {
  if (url == 'about:blank') return true;
  if (!['https', 'http'].contains(Uri.tryParse(url)?.scheme)) return false;
  try {
    await browserUrl(url);
    return true;
  } catch (_) {
    return false;
  }
}

const _browserChannel = MethodChannel('app.relay/browser');

/// The Browser page filling the screen (desktop only).
_BrowserPage? _onScreen;

/// The Browser pages whose PDF shows in the Mac's PDF viewer, by web view
/// (desktop only).
final _pdfPages = <int, _BrowserPage>{};

/// Answers the Mac runner's calls on the browser channel (desktop only):
/// a Browser popup window asks before each main-frame load, the window says
/// when the user left macOS fullscreen, and the PDF viewer reports the text
/// selected in it.
Future<Object?> browserChannelCall(MethodCall call) async {
  if (call.method == 'pdfSelection') {
    final event = call.arguments as Map;
    _pdfPages[event['view']]?._message('selection:${event['text']}');
    return null;
  }
  if (call.method == 'allowPopupPage') {
    return publicPageAllowed(call.arguments as String);
  }
  if (call.method == 'leftScreen') {
    final page = _onScreen;
    await page?.fillScreen(false);
    if (page != null && !page._disposed) page.changed(false);
    return null;
  }
  throw MissingPluginException(call.method);
}

/// Browser tabs keep the pages they show in the server's browsing history,
/// and the text highlighted on them, through [records] when it is given.
PageSurface createWebPage(
  PageSpec spec,
  void Function(bool) changed, {
  RelayApi? records,
}) {
  if (spec.report != null) return _ReportPage(spec, changed);
  if (spec.browser) return _BrowserPage(spec, changed, records);
  return _AppPage(spec, changed);
}

abstract class _WebPage extends PageSurface {
  _WebPage(this.spec, this.changed, [WebViewController? controller])
    : controller = controller ?? WebViewController();
  final PageSpec spec;
  final void Function(bool) changed;
  final WebViewController controller;
  final _ready = Completer<void>();
  bool _disposed = false;
  Json? _context;
  String? _nativeSelection;
  BuildContext? _dialogContext;

  @override
  Future<void> refreshSelection() async {
    if (!Platform.isMacOS || _disposed) return;
    final webKit = controller.platform as WebKitWebViewController;
    _nativeSelection = await _browserChannel.invokeMethod<String>(
      'selection',
      webKit.webViewIdentifier,
    );
  }

  // The Builder keeps a context for the page's JavaScript dialogs.
  @override
  Widget get widget => Builder(
    builder: (context) {
      _dialogContext = context;
      return WebViewWidget(key: ObjectKey(controller), controller: controller);
    },
  );
  @override
  String get title => spec.name;
  @override
  String get url => 'about:blank';
  @override
  Json? get context => _context == null || _nativeSelection == null
      ? _context
      : {..._context!, 'selection': _nativeSelection};
  @override
  Future<void> get ready => _ready.future;

  Future<void> _initialize() async {
    try {
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setOnJavaScriptAlertDialog(
        (request) => _pageDialog(request.url, request.message, cancel: false),
      );
      await controller.setOnJavaScriptConfirmDialog(
        (request) => _pageDialog(request.url, request.message),
      );
      await _load();
    } catch (error) {
      _fail(error);
    }
  }

  /// Shows a page's alert or confirm; true only when OK is chosen.
  /// The title names the page's host so a website cannot pose as Relay.
  Future<bool> _pageDialog(
    String url,
    String message, {
    bool cancel = true,
  }) async {
    final context = _dialogContext;
    if (_disposed || context == null || !context.mounted) return false;
    final host = Uri.tryParse(url)?.host ?? '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(host.isEmpty ? 'This page says' : '$host says'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(child: Text(message)),
        ),
        actions: [
          if (cancel)
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  bool get canCapture => Platform.isMacOS;

  @override
  Future<Uint8List> snapshot() async {
    final webKit = controller.platform as WebKitWebViewController;
    final bytes = await _browserChannel.invokeMethod<Uint8List>(
      'snapshot',
      webKit.webViewIdentifier,
    );
    if (bytes == null) throw StateError('The page could not be captured.');
    return bytes;
  }

  Future<void> _load();
  void _fail(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
  }

  void _resourceError(WebResourceError error) {
    // WebKit cancels superseded loads during redirects and replacement.
    if (Platform.isMacOS && error.errorCode == -999) return;
    if (error.isForMainFrame == true) _fail(Exception(error.description));
  }

  @override
  void dispose() {
    _disposed = true;
  }
}

class _BrowserPage extends _WebPage with BrowserSurface {
  // On macOS WebKit lets scripts open windows without a user action unless
  // told otherwise; Relay keeps WebKit's popup blocker on.
  _BrowserPage(PageSpec spec, void Function(bool) changed, this._records)
    : super(
        spec,
        changed,
        Platform.isMacOS
            ? WebViewController.fromPlatformCreationParams(
                WebKitWebViewControllerCreationParams(
                  javaScriptCanOpenWindowsAutomatically: false,
                ),
              )
            : null,
      ) {
    _initialize();
  }
  Completer<void>? _navigation;
  String _title = '', _url = 'about:blank';
  final RelayApi? _records;
  // The address this tab last counted as a visit. While a load is under way
  // its address may still pass through redirects; only the finished page counts.
  String? _visited;
  // The counted address still waiting for its one title; later title changes,
  // such as unread counts, are not sent.
  String? _untitled;
  // A restored tab's first page is not a new visit; counting it on every
  // launch would keep tabs left open at the top of the history.
  bool _restoring = false;
  bool _loading = false;
  int _generation = 0;
  String? _comment, _presentationId;
  int _transcriptRequests = 0;
  final _transcriptReplies = <String, Completer<Json>>{};
  // Desktop only. The Mac runner lays its PDF viewer over a page that is a
  // PDF. [_pdfOpening] ends once the viewer shows or the page keeps WebKit's
  // own PDF view. [_documents] counts the documents the tab has shown, so a
  // viewer or a highlights reply meant for an earlier one is dropped.
  @override
  bool pdf = false;
  Future<void>? _pdfOpening;
  int _documents = 0;
  // Desktop only for now: highlights need the server's records.
  @override
  bool get canHighlight => _records != null;
  // The address of the document whose highlights are loaded, as that
  // document reported it (see [_documentAddress]), and the ids of the
  // highlights kept for it.
  String? _highlightsAddress;
  String _highlightsSite = '';
  final _highlightIds = <String>{};
  static String? _highlightScript;

  @override
  Widget get widget => Stack(
    fit: StackFit.expand,
    children: [
      super.widget,
      if (_comment != null)
        BrowserComment(text: _comment!, onDismiss: _dismissComment),
    ],
  );

  void _dismissComment() {
    if (_comment == null) return;
    _comment = null;
    changed(false);
  }

  @override
  BrowserSurface get browser => this;
  @override
  bool canGoBack = false;
  @override
  bool canGoForward = false;
  @override
  String get title => _title.isEmpty ? spec.name : _title;
  @override
  String get url => _url;

  @override
  Future<void> _load() async {
    if (Platform.isMacOS) {
      final version = await _browserChannel.invokeMethod<String>(
        'safariVersion',
      );
      final agent = safariUserAgent(await controller.getUserAgent(), version);
      if (agent != null) await controller.setUserAgent(agent);
      // New windows open as popup windows, checked by the address rule.
      _browserChannel.setMethodCallHandler(browserChannelCall);
      await _browserChannel.invokeMethod<int>('popups', _webViewId);
      final script = await rootBundle.loadString('assets/page_fullscreen.js');
      await _browserChannel.invokeMethod<void>('documentStartScript', {
        'view': _webViewId,
        'source': script.replaceFirst('RELAY_KEY', jsonEncode(_fullScreenKey)),
      });
      // A new document in the tab says so: the page under the PDF viewer has
      // been replaced. A load that only starts, then fails, says nothing.
      await _browserChannel.invokeMethod<void>('documentStartScript', {
        'view': _webViewId,
        'source':
            "if (window === top && !window.opener) (window.webkit?.messageHandlers?.RelayBrowser ?? window.RelayBrowser)?.postMessage('document');",
      });
    }
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) async =>
            !request.isMainFrame || await publicPageAllowed(request.url)
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
        onPageStarted: (url) {
          _nativeSelection = null;
          _url = url;
          _loading = true;
          final wasFullScreen = fullScreen;
          fullScreen = false;
          if (_presentationId == null) {
            _comment = null;
            _generation++;
            changed(true);
          } else if (wasFullScreen) {
            changed(false);
          }
        },
        onPageFinished: (_) async {
          if (_disposed) return;
          try {
            await controller.runJavaScript(_observePage);
            // The page is ready without waiting for the PDF viewer or the
            // highlights. A viewer still open belonged to the page before.
            _newDocument();
            final opening = _pdfOpening = _openPdf();
            await _readDocument();
            unawaited(opening.then((_) => _showHighlights()));
            _loading = false;
            _visit(_title);
            canGoBack = await controller.canGoBack();
            canGoForward = await controller.canGoForward();
            if (!_ready.isCompleted) _ready.complete();
            if (_navigation?.isCompleted == false) _navigation!.complete();
            changed(false);
          } catch (error) {
            _fail(error);
          }
        },
        // An address a page changes in place only refreshes the address and
        // Back/Forward state. It is not a manual change: the user's own input
        // already reports through RelayBrowser, and sites also change their
        // address by themselves.
        onUrlChange: (change) async {
          final url = change.url;
          if (_disposed || url == null || url.isEmpty) return;
          // A page can only change its own address within its origin, so
          // another origin here is a redirect of a load still under way.
          final before = Uri.tryParse(_url), after = Uri.tryParse(url);
          final inPage =
              !_loading &&
              before?.scheme == after?.scheme &&
              before?.authority == after?.authority;
          _url = url;
          if (inPage) _visit();
          // A single-page app may have moved to another of its addresses.
          // The document itself says whether it did: this address is also
          // each redirect step of a load that has not replaced it yet.
          unawaited(_showHighlights());
          (_context?['state'] as Map?)?['url'] = url;
          canGoBack = await controller.canGoBack();
          canGoForward = await controller.canGoForward();
          if (!_disposed) changed(false);
        },
        onWebResourceError: _resourceError,
      ),
    );
    // Public pages can only invalidate context; they cannot issue app commands.
    await controller.addJavaScriptChannel(
      'RelayBrowser',
      onMessageReceived: (message) => _message(message.message),
    );
    // WebKit only knows the system appearance, not Relay's own setting.
    await controller.loadHtmlString(
      '<!doctype html><title>Browser</title><style>body{font:18px system-ui;padding:40px;color:#496452}'
      '@media(prefers-color-scheme:dark){body{background:#141917;color:#9cbdad}}</style>'
      '<body>Enter an address or search above.</body>',
    );
  }

  /// A message from the page's scripts, or from the Mac's PDF viewer about
  /// the PDF it shows in the page's place.
  void _message(String message) {
    if (_disposed) return;
    if (message.startsWith('transcript:')) {
      final reply = jsonDecode(message.substring(11)) as Map;
      final pending = _transcriptReplies.remove(reply['id']);
      if (reply['error'] != null) {
        pending?.completeError(StateError('${reply['error']}'));
      } else {
        pending?.complete(Map<String, dynamic>.from(reply['data'] as Map));
      }
      return;
    }
    if (message.startsWith('fullscreen:')) {
      final on = message == 'fullscreen:enter:$_fullScreenKey';
      if (!on && message != 'fullscreen:exit:$_fullScreenKey') return;
      if (on != fullScreen) {
        fullScreen = on;
        changed(false);
      }
      return;
    }
    if (message == 'document') {
      _newDocument();
      return;
    }
    if (message.startsWith('title:')) {
      _title = message.substring('title:'.length);
      (_context?['state'] as Map?)?['title'] = _title;
      final untitled = _untitled;
      if (untitled != null &&
          _title.isNotEmpty &&
          _historyAddress(_url) == untitled) {
        _untitled = null;
        _records?.browserTitle(untitled, _title);
      }
      changed(false);
      return;
    }
    if (message != 'interaction') {
      if (!message.startsWith('selection:')) return;
      final selection = message.substring('selection:'.length);
      if (selection.length > 4000 || _context?['selection'] == selection) {
        return;
      }
      _context?['selection'] = selection;
    }
    _nativeSelection = null;
    final presenting = _presentationId != null;
    _comment = null;
    _presentationId = null;
    _generation++;
    _context?['generation'] = _generation;
    changed(true);
    if (presenting && _navigation?.isCompleted == false) {
      unawaited(controller.runJavaScript('window.stop()'));
      _navigation!.completeError(
        StateError('Presentation interrupted by manual input.'),
      );
    }
  }

  Future<T?> _pdf<T>(String action, [Json more = const {}]) =>
      _browserChannel.invokeMethod<T>('pdf', {
        'view': _webViewId,
        'do': action,
        ...more,
      });

  // A new document shows in the tab: the viewer and the highlights belonged
  // to the one before.
  void _newDocument() {
    _documents++;
    _highlightsAddress = null;
    _highlightIds.clear();
    if (!Platform.isMacOS) return;
    final closing = pdf;
    pdf = false;
    _pdfOpening = null;
    _pdfPages.remove(_webViewId);
    unawaited(_pdf<void>('close'));
    // The PDF's buttons go with its viewer.
    if (closing) changed(false);
  }

  // WebKit shows a PDF in a page with no text, title or selection events.
  // The Mac runner fetches the PDF again and shows it in its own viewer.
  Future<void> _openPdf() async {
    if (!Platform.isMacOS) return;
    final load = _documents;
    try {
      final type = await controller.runJavaScriptReturningResult(
        'document.contentType',
      );
      if (!'$type'.contains('application/pdf')) return;
      final opened = await _pdf<Map>('open');
      if (opened == null || _disposed || load != _documents) return;
      pdf = true;
      _pdfPages[_webViewId] = this;
      _message('title:${opened['title']}');
    } catch (_) {
      // WebKit's own PDF view stays.
    }
  }

  // The document's address without its #fragment, as the document reports
  // it. Location's own properties and plain operators cannot be replaced by
  // a page's scripts.
  static const _documentSite =
      'location.origin + location.pathname + location.search';

  /// Where the document on screen is, asked of the document itself. The
  /// tab's address cannot say: while a load is under way it is already the
  /// next page's, through every redirect step, and a page can stop that load
  /// and stay. Highlights for an address go only to a document that is there.
  Future<({String? address, String site})> _documentAddress() async {
    final raw = await controller.runJavaScriptReturningResult(
      "location.href + '\\n' + $_documentSite",
    );
    final parts = '$raw'.split('\n');
    if (parts.length != 2) return (address: null, site: '');
    return (address: _historyAddress(parts[0]), site: parts[1]);
  }

  /// Shows the highlights kept for the page's address: in the Mac's viewer
  /// for a PDF, and through the page's highlight script for a web page.
  Future<void> _showHighlights() async {
    final records = _records;
    if (records == null) return;
    final document = _documents;
    try {
      final here = await _documentAddress();
      // Nothing to do while the document and its address are the same.
      if (_disposed ||
          document != _documents ||
          here.address == _highlightsAddress) {
        return;
      }
      final address = _highlightsAddress = here.address;
      _highlightsSite = here.site;
      _highlightIds.clear();
      if (address == null) return;
      final kept = await records.highlights(address);
      // The tab may show another document, or address, by now.
      if (_disposed ||
          document != _documents ||
          address != _highlightsAddress) {
        return;
      }
      _highlightIds.addAll(kept.map((highlight) => highlight['id'] as String));
      if (pdf) {
        await _pdf<void>('marks', {
          'highlights': [
            for (final highlight in kept)
              if (highlight['marks'] != null) highlight,
          ],
        });
        return;
      }
      _highlightScript ??= await rootBundle.loadString(
        'assets/page_highlights.js',
      );
      await controller.runJavaScript(_highlightScript!);
      await controller.runJavaScript(
        'if ($_documentSite === ${jsonEncode(here.site)}) '
        'window.__relayHighlights?.set(${jsonEncode([
          for (final highlight in kept)
            if (highlight['marks'] == null) highlight,
        ])})',
      );
    } catch (_) {
      // The page shows without its highlights.
    }
  }

  /// Highlights the selected text, or removes the highlights it touches, and
  /// keeps the change on the server.
  Future<void> _toggleHighlight() async {
    // The document on screen must be the one whose highlights are loaded.
    await _showHighlights();
    final here = await _documentAddress();
    if (here.address == null || here.address != _highlightsAddress) return;
    final id = const Uuid().v4();
    final viewer = pdf;
    Map? change;
    if (viewer) {
      change = await _pdf<Map>('highlight', {'id': id});
    } else {
      // The page's selection is gone with the highlight; the page observer
      // keeps the last one while the page is out of focus.
      final raw = await controller.runJavaScriptReturningResult(
        '(() => { const change = $_documentSite === ${jsonEncode(_highlightsSite)}'
        ' ? window.__relayHighlights?.toggle(${jsonEncode(id)}) ?? null : null;'
        " if (change) window.__relaySelection = ''; return JSON.stringify(change); })()",
      );
      dynamic data = raw is String ? jsonDecode(raw) : raw;
      if (data is String) data = jsonDecode(data);
      change = data as Map?;
      if (change != null) _message('selection:');
    }
    final records = _records, address = _highlightsAddress;
    if (change == null || records == null || address == null) return;
    // A web page's own scripts can answer in the highlight script's place, so
    // only its quoted text is taken from the answer: the address and id are
    // Relay's, and only highlights this page was given can be forgotten.
    final added = change['added'];
    if (added is Map && added['text'] is String) {
      _highlightIds.add(id);
      await records.saveHighlight(address, {
        'id': id,
        'text': added['text'],
        if (viewer)
          'marks': added['marks']
        else ...{
          'prefix': '${added['prefix'] ?? ''}',
          'suffix': '${added['suffix'] ?? ''}',
        },
      });
    }
    final removed = change['removed'];
    for (final gone in removed is List ? removed : const []) {
      if (_highlightIds.remove(gone)) {
        await records.forgetHighlight(gone as String);
      }
    }
  }

  @override
  void _fail(Object error) {
    super._fail(error);
    if (_navigation?.isCompleted == false) _navigation!.completeError(error);
  }

  // A reload or #fragment change of the page shown is not another visit.
  void _visit([String? title]) {
    final address = _historyAddress(_url);
    if (_records == null || address == null || address == _visited) return;
    final restored = _restoring;
    _visited = address;
    _restoring = false;
    _untitled = (restored || (title?.isNotEmpty ?? false)) ? null : address;
    if (!restored) _records.browserVisit(address, title);
  }

  int get _webViewId =>
      (controller.platform as WebKitWebViewController).webViewIdentifier;

  @override
  bool fullScreen = false;
  final _fullScreenKey = const Uuid().v4();

  @override
  Future<void> fillScreen(bool on) async {
    if (!Platform.isMacOS) return;
    if (on) {
      _onScreen = this;
    } else if (_onScreen == this) {
      _onScreen = null;
    }
    try {
      if (!on && fullScreen && !_disposed) {
        fullScreen = false;
        await controller.runJavaScript('window.__relayExitFullscreen?.()');
      }
      await _browserChannel.invokeMethod<void>('fillScreen', {
        'view': _webViewId,
        'on': on,
      });
    } catch (_) {
      // A closed tab has nothing left to show or end.
    }
  }

  @override
  void dispose() {
    super.dispose();
    _pdfPages.removeWhere((_, page) => page == this);
    // Closing the tab closes its popup windows and ends its PDF's fetch.
    if (Platform.isMacOS) {
      _pdf<void>('close').catchError((_) {});
      _browserChannel
          .invokeMethod<int>('closePopups', _webViewId)
          .catchError((_) => 0);
    }
  }

  @override
  Future<Json> read() async {
    // A PDF still being fetched is worth a short wait for its text: the
    // server allows a read 8 seconds.
    await _pdfOpening?.timeout(const Duration(seconds: 5), onTimeout: () {});
    final result = await _readDocument();
    final shown = pdf ? await _pdf<Map>('text') : null;
    if (shown != null) {
      // From the page in view onward, so `pdf` says where the text starts.
      result['text'] = shown['text'];
      result['pdf'] = {'page': shown['page'], 'pages': shown['pages']};
    }
    return result;
  }

  Future<Json> _readDocument() async {
    final raw = await controller
        .runJavaScriptReturningResult(_readPage)
        .timeout(const Duration(seconds: 20));
    dynamic data = raw is String ? jsonDecode(raw) : raw;
    if (data is String) data = jsonDecode(data);
    final result = Map<String, dynamic>.from(data as Map);
    await refreshSelection();
    if (_nativeSelection != null) result['selection'] = _nativeSelection;
    // WebKit's page for a PDF has no title; the viewer gave the PDF's own.
    if (pdf) result['title'] = _title;
    _url = result['url'] as String;
    _title = result['title'] as String;
    _context = {
      'viewId': 'browser',
      'generation': _generation,
      'state': {
        'sessionId': spec.sessionId,
        'tabId': spec.id,
        'url': _url,
        'title': _title,
      },
      'selection': result['selection'],
    };
    return result;
  }

  // Desktop only. Each call asks YouTube again for the video the tab shows.
  @override
  Future<Json> loadTranscript() async {
    final id = '${++_transcriptRequests}';
    final reply = _transcriptReplies[id] = Completer<Json>();
    try {
      await controller.runJavaScript(
        youtubeTranscriptScript.replaceFirst('REQUEST_ID', jsonEncode(id)),
      );
      final data = await reply.future.timeout(
        const Duration(seconds: 7),
        onTimeout: () => throw StateError('YouTube did not answer in time.'),
      );
      return transcriptFromSegments(data);
    } finally {
      _transcriptReplies.remove(id);
    }
  }

  // Desktop only. The transcript pane polls this while it is open.
  @override
  Future<double?> playbackTime() async {
    if (_disposed) return null;
    final result = await controller.runJavaScriptReturningResult(
      youtubePlaybackTimeScript,
    );
    final seconds = double.tryParse('$result');
    return seconds == null || seconds < 0 ? null : seconds;
  }

  @override
  Future<void> navigate(String text, {bool restoring = false}) async {
    final target = await browserUrl(text);
    _restoring = restoring;
    _navigation = Completer<void>();
    await controller.loadRequest(target);
    await _navigation!.future.timeout(const Duration(seconds: 30));
  }

  @override
  Future<void> browserAction(String action) async {
    if (action == 'back' && await controller.canGoBack()) {
      await controller.goBack();
    }
    if (action == 'forward' && await controller.canGoForward()) {
      await controller.goForward();
    }
    if (action == 'reload') await controller.reload();
    if (action == 'highlight') await _toggleHighlight();
    if (pdf && pdfZoomActions.contains(action)) await _pdf<void>(action);
  }

  @override
  Future<Json> present(Json command) async {
    await ready.timeout(const Duration(seconds: 20));
    final intent = Map<String, dynamic>.from(command['intent'] as Map);
    if (command['expectedGeneration'] != _generation) {
      return {'status': 'stale'};
    }
    final id = command['id'] as String;
    _presentationId = id;
    _dismissComment();
    try {
      if (intent['viewId'] != 'browser' ||
          (intent['targetIds'] as List?)?.isNotEmpty == true) {
        throw StateError('Unsupported browser presentation.');
      }
      final target = (intent['state'] as Map?)?['url'];
      if (target is String) await navigate(target);
      await read();
      if (_disposed || _presentationId != id) return {'status': 'stale'};
      final explanation = intent['explanation'] as String?;
      if (explanation != null) {
        _comment = explanation;
        changed(false);
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(seconds: 20),
        );
        if (_disposed || _presentationId != id) return {'status': 'stale'};
      }
      _generation++;
      _context!['generation'] = _generation;
      return {'status': 'applied', 'context': _context};
    } catch (_) {
      if (_presentationId == id && !_disposed) _dismissComment();
      rethrow;
    } finally {
      if (_presentationId == id) _presentationId = null;
    }
  }

  @override
  void cancel(String commandId) {
    if (_disposed || _presentationId != commandId) return;
    _presentationId = null;
    _dismissComment();
    unawaited(controller.runJavaScript('window.stop()'));
    if (_navigation?.isCompleted == false) {
      _navigation!.completeError(StateError('Presentation cancelled.'));
    }
  }
}

abstract class _HostedPage extends _WebPage {
  _HostedPage(super.spec, super.changed);
  Completer<Json>? _presentation;
  String? _presentationId;

  @override
  Future<void> _load() async {
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          if (!request.isMainFrame) return NavigationDecision.navigate;
          final target = Uri.tryParse(request.url);
          if (target != null && ['http', 'https'].contains(target.scheme)) {
            if (target.origin == spec.relayOrigin.origin) {
              return NavigationDecision.navigate;
            }
            unawaited(launchUrl(target, mode: LaunchMode.externalApplication));
          }
          return NavigationDecision.prevent;
        },
        onWebResourceError: _resourceError,
      ),
    );
    await controller.addJavaScriptChannel(
      'RelayHost',
      onMessageReceived: (message) {
        if (_disposed) return;
        final data = jsonDecode(message.message) as Json;
        if (data['token'] != spec.id || !_acceptsVersion(data)) return;
        final result = [
          'relay.presented',
          'relay.navigation',
        ].contains(data['type']);
        if (result && data['commandId'] != _presentationId) return;
        _nativeSelection = null;
        if (data['context'] is Map) {
          _context = Map<String, dynamic>.from(data['context'] as Map);
        }
        final manual = _updateContext(data);
        if (data['type'] == 'relay.ready' && !_ready.isCompleted) {
          _ready.complete();
        }
        if (result && _presentation?.isCompleted == false) {
          _presentation!.complete(data);
        }
        changed(manual);
      },
    );
    await controller.loadRequest(spec.hostUri);
  }

  bool _acceptsVersion(Json data);
  bool _updateContext(Json data);
  Json _bridgeCommand(Json command);

  @override
  Future<Json> present(Json command) async {
    await ready.timeout(const Duration(seconds: 20));
    final payload = _bridgeCommand(command);
    _presentation = Completer<Json>();
    _presentationId = command['id'] as String;
    await controller.runJavaScript(
      'window.relayPresent(${jsonEncode(payload)})',
    );
    return _presentation!.future.timeout(const Duration(seconds: 30));
  }

  @override
  void _fail(Object error) {
    super._fail(error);
    if (_presentation?.isCompleted == false) {
      _presentation!.completeError(error);
    }
  }

  @override
  void cancel(String commandId) {
    if (_disposed) return;
    unawaited(
      controller.runJavaScript(
        'window.relayPresent(${jsonEncode({'type': 'relay.cancel', 'commandId': commandId})})',
      ),
    );
  }
}

class _AppPage extends _HostedPage {
  _AppPage(super.spec, super.changed) {
    _initialize();
  }
  @override
  bool _acceptsVersion(Json data) => data['version'] == 2;
  @override
  bool _updateContext(Json data) => data['type'] == 'relay.context';
  @override
  Json _bridgeCommand(Json command) => {
    'type': 'relay.present',
    'commandId': command['id'],
    'intent': command['intent'],
    'expectedGeneration': command['expectedGeneration'],
  };
}

class _ReportPage extends _HostedPage {
  _ReportPage(super.spec, super.changed) {
    _context = {'legacy': true, 'source': spec.report!['source']};
    _initialize();
  }
  bool _receivedContext = false;
  @override
  bool _acceptsVersion(Json data) => true;
  @override
  bool _updateContext(Json data) {
    if ([
      'relay.ready',
      'relay.context',
      'relay.navigation',
    ].contains(data['type'])) {
      _context = {
        'legacy': true,
        'source': data.containsKey('source')
            ? data['source']
            : _context?['source'],
        'sectionId': data['sectionId'],
        'selection': data['selection'],
        'viewState': data['viewState'],
      };
    }
    if (data['type'] != 'relay.context') return false;
    final source = data['source'];
    final expected = spec.report?['source'];
    final initial =
        spec.appView?['native'] == true &&
        !_receivedContext &&
        source is Map &&
        expected is Map &&
        [
          'appId',
          'resourceId',
          'revision',
        ].every((key) => source[key] == expected[key]);
    _receivedContext = true;
    return !initial;
  }

  @override
  MessageContext? messageContext(
    String appId,
    String? token, {
    String? selection,
  }) {
    final context = {...this.context!, 'selection': ?selection};
    final source = context['source'] as Json?;
    return (
      fields: {
        'appContext': {
          'appId': appId,
          'viewToken': token,
          if (context['viewState'] != null) 'viewState': context['viewState'],
        },
        if (source != null)
          'context': {...context, 'viewToken': token}..remove('legacy'),
      },
      savedSource: source,
      anchorsView: source != null,
    );
  }

  @override
  Json _bridgeCommand(Json command) => {
    'type': 'relay.navigate',
    'commandId': command['id'],
    'source': command['source'],
    'sectionId': command['sectionId'],
    'highlightIds': command['highlightIds'] ?? [],
    'viewState': command['viewState'],
  };
}

/// The address history keeps for [url], without its #fragment, or null for
/// pages it skips: anything but an HTTP or HTTPS website.
String? _historyAddress(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !['http', 'https'].contains(uri.scheme)) return null;
  if (uri.host.isEmpty) return null;
  return uri.removeFragment().toString();
}

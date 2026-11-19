import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:url_launcher/url_launcher.dart';

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

PageSurface createWebPage(PageSpec spec, void Function(bool) changed) {
  if (spec.report != null) return _ReportPage(spec, changed);
  if (spec.browser) return _BrowserPage(spec, changed);
  return _AppPage(spec, changed);
}

abstract class _WebPage extends PageSurface {
  _WebPage(this.spec, this.changed);
  final PageSpec spec;
  final void Function(bool) changed;
  final controller = WebViewController();
  final _ready = Completer<void>();
  bool _disposed = false;
  Json? _context;
  String? _nativeSelection;
  BuildContext? _dialogContext;

  @override
  Future<void> refreshSelection() async {
    if (!Platform.isMacOS || _disposed) return;
    final webKit = controller.platform as WebKitWebViewController;
    _nativeSelection = await const MethodChannel('app.relay/browser')
        .invokeMethod<String>('selection', webKit.webViewIdentifier);
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
    final bytes = await const MethodChannel('app.relay/browser')
        .invokeMethod<Uint8List>('snapshot', webKit.webViewIdentifier);
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
  _BrowserPage(super.spec, super.changed) {
    _initialize();
  }
  Completer<void>? _navigation;
  String _title = '', _url = 'about:blank';
  int _generation = 0;
  String? _comment, _presentationId;
  int _transcriptRequests = 0;
  final _transcriptReplies = <String, Completer<Json>>{};

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
      final version = await const MethodChannel('app.relay/browser')
          .invokeMethod<String>('safariVersion');
      final agent = safariUserAgent(await controller.getUserAgent(), version);
      if (agent != null) await controller.setUserAgent(agent);
    }
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) async {
          if (!request.isMainFrame || request.url == 'about:blank') {
            return NavigationDecision.navigate;
          }
          try {
            if (!['https', 'http'].contains(Uri.parse(request.url).scheme)) {
              return NavigationDecision.prevent;
            }
            await browserUrl(request.url);
            return NavigationDecision.navigate;
          } catch (_) {
            return NavigationDecision.prevent;
          }
        },
        onPageStarted: (url) {
          _nativeSelection = null;
          _url = url;
          if (_presentationId == null) {
            _comment = null;
            _generation++;
            changed(true);
          }
        },
        onPageFinished: (_) async {
          if (_disposed) return;
          try {
            await controller.runJavaScript(_observePage);
            await read();
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
          _url = url;
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
      onMessageReceived: (message) {
        if (_disposed) return;
        if (message.message.startsWith('transcript:')) {
          final reply = jsonDecode(message.message.substring(11)) as Map;
          final pending = _transcriptReplies.remove(reply['id']);
          if (reply['error'] != null) {
            pending?.completeError(StateError('${reply['error']}'));
          } else {
            pending?.complete(Map<String, dynamic>.from(reply['data'] as Map));
          }
          return;
        }
        if (message.message.startsWith('title:')) {
          _title = message.message.substring('title:'.length);
          (_context?['state'] as Map?)?['title'] = _title;
          changed(false);
          return;
        }
        if (message.message != 'interaction') {
          if (!message.message.startsWith('selection:')) return;
          final selection = message.message.substring('selection:'.length);
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
      },
    );
    // WebKit only knows the system appearance, not Relay's own setting.
    await controller.loadHtmlString(
      '<!doctype html><title>Browser</title><style>body{font:18px system-ui;padding:40px;color:#496452}'
      '@media(prefers-color-scheme:dark){body{background:#141917;color:#9cbdad}}</style>'
      '<body>Enter an address or search above.</body>',
    );
  }

  @override
  void _fail(Object error) {
    super._fail(error);
    if (_navigation?.isCompleted == false) _navigation!.completeError(error);
  }

  @override
  Future<Json> read() async {
    final raw = await controller
        .runJavaScriptReturningResult(_readPage)
        .timeout(const Duration(seconds: 20));
    dynamic data = raw is String ? jsonDecode(raw) : raw;
    if (data is String) data = jsonDecode(data);
    final result = Map<String, dynamic>.from(data as Map);
    await refreshSelection();
    if (_nativeSelection != null) result['selection'] = _nativeSelection;
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
  Future<void> navigate(String text) async {
    final target = await browserUrl(text);
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

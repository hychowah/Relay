import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/browser_transcript.dart';
import 'package:relay_flutter/highlight_menu.dart';
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
    if (!loaded.isCompleted) loaded.complete();
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {}
  @override
  Future<void> runJavaScript(String javaScript) async =>
      scripts.add(javaScript);
  Object playTime = -1;
  // What the page's highlight script answers to Highlight.
  String highlighted = 'null';
  // The document on screen, when it is not the tab's address: a load that is
  // under way has moved the address on but not replaced the document.
  String? document;
  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async =>
      javaScript == youtubePlaybackTimeScript
      ? playTime
      : javaScript.startsWith('location.href')
      ? '${document ?? location}\n${(document ?? location).split('#').first}'
      : javaScript.contains('__relayHighlights?.add(')
      ? highlighted
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
    Future<Object?> ask(String url, {bool vpn = false}) => browserChannelCall(
      MethodCall('allowPopupPage', {'url': url, 'vpn': vpn}),
    );
    // A VPN tab's names are looked up in WSL, by the backend's proxy; a name
    // the Mac cannot resolve passes, but address literals are still checked.
    expect(await ask('https://vpn-only.invalid/', vpn: true), isTrue);
    expect(await ask('http://10.1.2.3/', vpn: true), isFalse);
    expect(await ask('http://localhost/', vpn: true), isFalse);
    expect(await ask('https://user@8.8.8.8/', vpn: true), isFalse);
    expect(await ask('file:///etc/hosts', vpn: true), isFalse);
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

  test(
    'a restored Browser page is not a visit, and each visit sends one title',
    () async {
      final platform = TestWebPlatform();
      WebViewPlatform.instance = platform;
      final sent = <String>[];
      final api = RelayApi(
        Uri.parse('http://relay.test'),
        client: MockClient((request) async {
          if (request.url.path.startsWith('/api/highlights')) {
            return http.Response('[]', 200);
          }
          sent.add('${request.url.pathSegments.last} ${request.body}');
          return http.Response('{}', 200);
        }),
      );
      final page = createWebPage(
        PageSpec(
          id: 'tab',
          appId: 'browser',
          name: 'Browser',
          sessionId: 'session',
          relayOrigin: api.origin,
        ),
        (_) {},
        records: api,
      );
      addTearDown(page.dispose);
      final controller = platform.controller;
      await pumpEventQueue();
      controller
        ..location = 'about:blank'
        ..delegate.finished('about:blank');
      await page.ready;

      Future<void> open(String url, {bool restoring = false}) async {
        final done = page.browser!.navigate(url, restoring: restoring);
        await pumpEventQueue();
        controller
          ..location = url
          ..delegate.finished(url);
        await done;
        await pumpEventQueue();
      }

      void title(String text) => controller.channel.onMessageReceived(
        JavaScriptMessage(message: 'title:$text'),
      );

      await open('https://8.8.8.8/saved', restoring: true);
      title('Saved');
      await pumpEventQueue();
      expect(sent, isEmpty);

      await open('https://8.8.8.8/next');
      title('(1) Next');
      await pumpEventQueue();
      expect(sent, ['visit {"url":"https://8.8.8.8/next","title":"YouTube"}']);

      // A page changing its own address is a visit whose title comes next.
      controller.location = 'https://8.8.8.8/next?v=2';
      controller.delegate.urlChange(UrlChange(url: controller.location));
      title('');
      title('Video');
      title('(1) Video');
      await pumpEventQueue();
      expect(sent.skip(1), [
        'visit {"url":"https://8.8.8.8/next?v=2"}',
        'title {"url":"https://8.8.8.8/next?v=2","title":"Video"}',
      ]);
    },
  );

  test(
    'a web page highlight is kept under the page address and shown again',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final platform = TestWebPlatform();
      WebViewPlatform.instance = platform;
      const kept = {
        'id': 'old',
        'text': 'an earlier passage',
        'prefix': 'before ',
        'suffix': ' after',
        'color': 'green',
      };
      final sent = <String>[];
      // How the server answers a change, or a list, for now; by default it
      // takes the change and lists what it keeps.
      Future<http.Response> Function()? answer, listing;
      final api = RelayApi(
        Uri.parse('http://relay.test'),
        client: MockClient((request) async {
          if (!request.url.path.startsWith('/api/highlights')) {
            return http.Response('{}', 200);
          }
          sent.add(
            '${request.method} ${request.url.path} '
                    '${request.url.queryParameters['url'] ?? request.body}'
                .trim(),
          );
          if (request.method == 'GET') {
            if (listing != null) return listing();
            final url = request.url.queryParameters['url'];
            final list = url == 'https://8.8.8.8/article' ? [kept] : [];
            return http.Response(jsonEncode(list), 200);
          }
          return answer?.call() ?? http.Response('', 204);
        }),
      );
      final page = createWebPage(
        PageSpec(
          id: 'tab',
          appId: 'browser',
          name: 'Browser',
          sessionId: 'session',
          relayOrigin: api.origin,
        ),
        (_) {},
        records: api,
      );
      addTearDown(page.dispose);
      final controller = platform.controller;
      await pumpEventQueue();
      controller
        ..location = 'about:blank'
        ..delegate.finished('about:blank');
      await page.ready;
      sent.clear();
      final done = page.browser!.navigate('https://8.8.8.8/article#part');
      await pumpEventQueue();
      controller
        ..location = 'https://8.8.8.8/article#part'
        ..delegate.finished(controller.location);
      await done;
      await pumpEventQueue();

      // The page gets its script, then the highlights kept for its address.
      expect(sent, ['GET /api/highlights https://8.8.8.8/article']);
      expect(controller.scripts.last, contains('.set([${jsonEncode(kept)}])'));
      expect(
        controller.scripts[controller.scripts.length - 2],
        contains('window.__relayHighlights ='),
      );

      // The page's script says where its menu goes: by selected text, or
      // by a highlight this page was given.
      HighlightMenu? menu() => (page.widget as Stack).children
          .whereType<HighlightMenu>()
          .firstOrNull;
      void say(String message) => controller.channel.onMessageReceived(
        JavaScriptMessage(message: message),
      );
      const rect = {'left': 10, 'top': 40, 'right': 90, 'bottom': 56};
      say('menu:${jsonEncode({'rect': rect})}');
      expect(menu()!.at, const Rect.fromLTRB(10, 40, 90, 56));
      expect(menu()!.color, isNull);
      expect(menu()!.onRemove, isNull);

      // A colour saves what the page's script quoted, in that colour.
      controller.highlighted = jsonEncode({
        'added': {'text': 'a passage', 'prefix': 'the ', 'suffix': ' ends'},
      });
      menu()!.onColor('blue');
      await pumpEventQueue();
      expect(menu(), isNull);
      final saved = jsonDecode(sent.last.split(' ').skip(2).join(' ')) as Map;
      expect(sent.last, startsWith('POST /api/highlights '));
      expect(saved['id'], hasLength(36));
      expect(saved..remove('id'), {
        'url': 'https://8.8.8.8/article',
        'text': 'a passage',
        'color': 'blue',
        'prefix': 'the ',
        'suffix': ' ends',
      });

      // A clicked highlight's menu changes its colour or removes it, on the
      // page and on the server. An id the page was not given opens nothing.
      say('menu:${jsonEncode({'rect': rect, 'id': 'elsewhere'})}');
      expect(menu(), isNull);
      say('menu:${jsonEncode({'rect': rect, 'id': 'old'})}');
      expect(menu()!.color, 'green');

      // A change the server refuses, or cannot be reached for, shows the
      // highlight as the server keeps it again, and its menu still opens.
      String drawn() => controller.scripts.last;
      answer = () async => http.Response('{"error":"Down."}', 500);
      menu()!.onColor('purple');
      await pumpEventQueue();
      expect(sent.last, 'PATCH /api/highlights/old {"color":"purple"}');
      expect(drawn(), contains('.set([${jsonEncode(kept)},'));
      answer = null;
      say('menu:${jsonEncode({'rect': rect, 'id': 'old'})}');
      expect(menu()!.color, 'green');

      menu()!.onColor('pink');
      await pumpEventQueue();
      expect(drawn(), endsWith('.recolor("old", "pink")'));
      expect(sent.last, 'PATCH /api/highlights/old {"color":"pink"}');
      say('menu:${jsonEncode({'rect': rect, 'id': 'old'})}');
      expect(menu()!.color, 'pink');
      answer = () => throw http.ClientException('Unreachable.');
      menu()!.onRemove!();
      await pumpEventQueue();
      expect(sent.last, 'DELETE /api/highlights/old');
      expect(drawn(), contains('{"id":"old","text":"an earlier passage"'));
      answer = null;
      say('menu:${jsonEncode({'rect': rect, 'id': 'old'})}');
      expect(menu()!.color, 'pink');
      menu()!.onRemove!();
      await pumpEventQueue();
      expect(drawn(), endsWith('.remove("old", null)'));
      expect(sent.last, 'DELETE /api/highlights/old');
      say('menu:${jsonEncode({'rect': rect, 'id': 'old'})}');
      expect(menu(), isNull, reason: 'the highlight is gone');

      // The toolbar's Highlight with nothing selected saves nothing.
      controller.highlighted = 'null';
      await page.browser!.browserAction('highlight');
      expect(sent, hasLength(6), reason: 'nothing was selected');

      // A page that moves to another of its addresses shows that one's. A
      // change still on its way fails there: it touches neither that
      // address's highlights nor its page.
      final added = jsonDecode(sent[1].split(' ').skip(2).join(' '))['id'];
      final hold = Completer<http.Response>();
      answer = () => hold.future;
      say('menu:${jsonEncode({'rect': rect, 'id': added})}');
      menu()!.onColor('yellow');
      await pumpEventQueue();
      expect(sent.last, 'PATCH /api/highlights/$added {"color":"yellow"}');
      controller.location = 'https://8.8.8.8/other';
      controller.delegate.urlChange(UrlChange(url: controller.location));
      await pumpEventQueue();
      expect(sent.last, 'GET /api/highlights https://8.8.8.8/other');
      final given = controller.scripts.length;
      hold.complete(http.Response('{"error":"Down."}', 500));
      await pumpEventQueue();
      answer = null;
      expect(controller.scripts, hasLength(given));
      say('menu:${jsonEncode({'rect': rect, 'id': added})}');
      expect(menu(), isNull);

      // A new #fragment is the same address.
      controller.location = 'https://8.8.8.8/other#part';
      controller.delegate.urlChange(UrlChange(url: controller.location));
      await pumpEventQueue();
      expect(sent, hasLength(8));

      // A highlight made while the address's list is on its way stays when
      // the list arrives.
      final list = Completer<http.Response>();
      listing = () => list.future;
      controller.location = 'https://8.8.8.8/third';
      controller.delegate.urlChange(UrlChange(url: controller.location));
      await pumpEventQueue();
      expect(sent.last, 'GET /api/highlights https://8.8.8.8/third');
      controller.highlighted = jsonEncode({
        'added': {'text': 'made early', 'prefix': '', 'suffix': ''},
      });
      say('menu:${jsonEncode({'rect': rect})}');
      menu()!.onColor('green');
      await pumpEventQueue();
      final early = jsonDecode(sent.last.split(' ').skip(2).join(' '))['id'];
      list.complete(http.Response(jsonEncode([kept]), 200));
      listing = null;
      await pumpEventQueue();
      expect(drawn(), allOf(contains('"id":"old"'), contains('"id":"$early"')));

      // Two quick colour changes the server refuses go out in the order
      // made, and end with one redraw in the colour the server keeps.
      answer = () async => http.Response('{"error":"Down."}', 500);
      final before = controller.scripts.length;
      for (final color in ['purple', 'pink']) {
        say('menu:${jsonEncode({'rect': rect, 'id': early})}');
        menu()!.onColor(color);
      }
      await pumpEventQueue();
      answer = null;
      expect(sent.sublist(sent.length - 2), [
        'PATCH /api/highlights/$early {"color":"purple"}',
        'PATCH /api/highlights/$early {"color":"pink"}',
      ]);
      final redrawn = controller.scripts.sublist(before);
      expect(
        redrawn.where((script) => script.contains('__relayHighlights?.set(')),
        hasLength(1),
      );
      expect(
        redrawn.last,
        contains('{"id":"$early","text":"made early","color":"green"'),
      );

      // A load under way moves the tab's address through each redirect
      // step, here back through the page's own address and on to another
      // site, while the page stays on screen. That site's highlights are not
      // asked for or given to this page, and Highlight still saves here.
      controller.document = 'https://8.8.8.8/third';
      final asked = sent.length, shown = controller.scripts.length;
      for (final step in [
        'https://8.8.8.8/redirect',
        'https://8.8.8.8/third',
        'https://8.8.4.4/victim',
        'https://8.8.4.4/victim/',
      ]) {
        controller.location = step;
        controller.delegate.urlChange(UrlChange(url: step));
        await pumpEventQueue();
      }
      expect(sent, hasLength(asked));
      expect(controller.scripts, hasLength(shown));
      controller.highlighted = jsonEncode({
        'added': {'text': 'kept here', 'prefix': '', 'suffix': ''},
      });
      await page.browser!.browserAction('highlight');
      expect(
        sent.last,
        allOf(
          startsWith('POST /api/highlights '),
          contains('"url":"https://8.8.8.8/third"'),
        ),
      );
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

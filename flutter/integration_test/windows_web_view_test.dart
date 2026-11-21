// Windows check of the Browser address rule and downloads against a real
// WebView2, through lib/windows_web_view.dart. Run it on Windows from a copy
// of flutter/ on the Windows drive with
// `flutter test integration_test/windows_web_view_test.dart -d windows`.
// It uses only a loopback fixture server and a temporary WebView2 data folder:
// no Relay server and none of the app's settings, records or sign-ins.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/windows_web_view.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a page cannot reach a refused address, and nothing downloads', (
    tester,
  ) async {
    expect(Platform.isWindows, isTrue, reason: 'Run on Windows.');
    final data = await Directory.systemTemp.createTemp('relay-webview-test.');
    await registerWindowsWebView(data.path);

    final served = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final download = 'relay-download-test-${server.port}';
    server.listen((request) async {
      final path = request.uri.path, response = request.response;
      served.add(path);
      if (path == '/redirect') {
        await response.redirect(Uri.parse('/private'));
        return;
      }
      if (path == '/download') {
        response.headers.set(
          'content-disposition',
          'attachment; filename=$download.txt',
        );
        response.write('download');
      } else {
        response.headers.contentType = ContentType.html;
        response.write(
          path == '/private'
              ? '<title>Private</title>PRIVATE PAGE'
              : '''<!doctype html><title>Public</title>
                 <a id="link" href="/private">private link</a>
                 <script>addEventListener('popstate', () => {
                   if (location.search === '?script') location = '/private';
                 });</script>''',
        );
      }
      await response.close();
    });
    final origin = 'http://127.0.0.1:${server.port}';

    // The fixture stands in for the Browser's rule: /private is refused,
    // except for the loads [letThrough] lets pass as an unasked load would.
    var letThrough = 0;
    final asked = <String>[], seen = <String>[];
    var finished = 0;
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          if (request.isMainFrame) asked.add(request.url);
          if (!request.url.contains('/private')) {
            return NavigationDecision.navigate;
          }
          if (letThrough == 0) return NavigationDecision.prevent;
          letThrough--;
          return NavigationDecision.navigate;
        },
        onPageFinished: (url) {
          seen.add(url);
          finished++;
        },
        onUrlChange: (change) => seen.add(change.url ?? ''),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WebViewWidget(controller: controller)),
      ),
    );

    Future<void> wait(Duration time) async {
      final end = DateTime.now().add(time);
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    }

    Future<void> load(String path) async {
      final before = finished;
      await controller.loadRequest(Uri.parse('$origin$path'));
      final end = DateTime.now().add(const Duration(seconds: 15));
      while (finished == before) {
        expect(DateTime.now().isBefore(end), isTrue, reason: 'loads $path');
        await wait(const Duration(milliseconds: 100));
      }
    }

    Future<String> text() async {
      try {
        return '${await controller.runJavaScriptReturningResult('document.body.innerText')}';
      } on StateError {
        return 'blocked';
      }
    }

    // A link and a server redirect are refused. WebView2 sends the request
    // even when its start is cancelled; the page never shows.
    await load('/public');
    await controller.runJavaScript("document.getElementById('link').click()");
    await wait(const Duration(seconds: 2));
    await controller.loadRequest(Uri.parse('$origin/redirect'));
    await wait(const Duration(seconds: 3));
    expect(served, contains('/redirect'));
    expect(asked.where((url) => url.contains('/private')), hasLength(2));
    expect(seen.where((url) => url.contains('/private')), isEmpty);
    expect(await text(), isNot(contains('PRIVATE')));

    // After Back over a same-document entry the package lets the next load
    // through without asking; Relay's own check must still refuse it.
    for (final how in ['script', 'link']) {
      await load('/public?$how');
      served.clear();
      asked.clear();
      seen.clear();
      await controller.runJavaScript("history.pushState({}, '', '#moved')");
      await wait(const Duration(seconds: 1));
      await controller.goBack();
      await wait(const Duration(seconds: 1));
      if (how == 'link') {
        await controller.runJavaScript(
          "document.getElementById('link').click()",
        );
      }
      await wait(const Duration(seconds: 3));
      expect(seen.where((url) => url.contains('/private')), isEmpty);
      expect(await text(), isNot(contains('PRIVATE')));
    }

    // A load the package lets through is still checked when it starts, and
    // a refused page is replaced before the app can see or read it.
    await load('/public');
    seen.clear();
    letThrough = 1;
    await controller.runJavaScript("document.getElementById('link').click()");
    await wait(const Duration(seconds: 3));
    expect(seen.where((url) => url.contains('/private')), isEmpty);
    expect(await text(), contains('Relay blocked a private address'));

    // An attachment saves nothing.
    final downloads = Directory(
      '${Platform.environment['USERPROFILE']}\\Downloads',
    );
    await controller.loadRequest(Uri.parse('$origin/download'));
    await wait(const Duration(seconds: 3));
    expect(served, contains('/download'));
    expect(
      downloads.listSync().where((file) => file.path.contains(download)),
      isEmpty,
    );

    await tester.pumpWidget(const SizedBox());
    try {
      await data.delete(recursive: true);
    } on FileSystemException {
      // WebView2 may hold its files until the test app exits.
    }
  });
}

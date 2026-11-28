// Mac check of Browser downloads against real WKWebViews. Run it from WSL
// with `npm run test:mac -- browser_downloads_test.dart`, which builds under
// its own bundle id so it cannot read or write the installed app's settings
// and data. Files go to a temporary folder, never the Mac's Downloads. It
// downloads public files from httpbin.org, so it needs the internet on the
// Mac; a loopback fixture stands in for a private address.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:relay_flutter/browser_downloads.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:webview_flutter/webview_flutter.dart';

const installedBundleId = 'app.relay.flutterExperiment';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a Browser tab saves its downloads to the Downloads folder', (
    tester,
  ) async {
    expect(Platform.isMacOS, isTrue, reason: 'Run on macOS.');
    expect(
      (await PackageInfo.fromPlatform()).packageName,
      isNot(installedBundleId),
      reason: "Run through npm run test:mac so the installed app's data stays untouched.",
    );

    final folder = await Directory.systemTemp.createTemp('relay-downloads-');
    addTearDown(() => folder.delete(recursive: true));
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests.add(request.uri.path);
      request.response.write('Unexpected');
      await request.response.close();
    });
    final fixture = 'http://127.0.0.1:${server.port}';

    final messenger = GlobalKey<ScaffoldMessengerState>();
    final downloads = BrowserDownloads(messenger, folder: () async => folder);
    // The test hears the Mac's download calls first, to report them, and
    // passes them on as BrowserDownloads' own handler does.
    const channel = MethodChannel('app.relay/downloads');
    final calls = <String>[];
    channel.setMethodCallHandler((call) async {
      final arguments = call.arguments as Map;
      calls.add('${call.method} $arguments');
      if (call.method == 'ended') {
        downloads.ended(
          arguments['path'] as String,
          saved: arguments['saved'] == true,
        );
        return null;
      }
      return downloads.start(
        arguments['url'] as String,
        arguments['name'] as String,
        vpn: arguments['vpn'] == true,
      );
    });

    final page = createWebPage(
      PageSpec(
        id: 'downloads-tab',
        appId: 'browser',
        name: 'Browser',
        sessionId: 'downloads-check',
        relayOrigin: Uri.parse('http://127.0.0.1:9'),
      ),
      (_) {},
      downloads: downloads,
    );
    var disposed = false;
    addTearDown(() => disposed ? null : page.dispose());
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: messenger,
        home: Scaffold(body: page.widget),
      ),
    );
    await page.ready.timeout(const Duration(seconds: 20));
    final controller = (page as dynamic).controller as WebViewController;

    List<String> files() =>
        folder.listSync().map((f) => f.path.split('/').last).toList()..sort();
    // Each step that fails is noted with what the page, the fixture and the
    // downloads channel saw, and the rest still run, so one run shows all.
    final problems = <String>[];
    void note(String reason) => problems.add(
      '$reason\n  files: ${files()}\n  requests: $requests\n'
      '  calls: $calls\n  tab: ${page.url} "${page.title}"',
    );
    Future<void> until(
      bool Function() done,
      String reason, {
      int seconds = 15,
    }) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (!done()) {
        if (DateTime.now().isAfter(deadline)) return note(reason);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    }

    Future<void> saved(List<String> expected, String reason) =>
        until(() => expected.every(files().contains), reason);

    await controller.loadHtmlString('''<!doctype html><title>Links</title>
      <body><a id="blob" download="x.txt">Blob</a>
      <a id="private" download href="$fixture/private">Private</a>
      <script>
        document.getElementById('blob').href =
          URL.createObjectURL(new Blob(['made here'], {type: 'text/plain'}));
      </script>''');
    await until(() => page.title == 'Links', 'The link page did not load');

    // A link the page made, twice: the second gets the next free name.
    await controller.runJavaScript("document.getElementById('blob').click()");
    await saved(['x.txt'], 'A blob download link must save its file');
    await until(
      () => find.text('Saved x.txt').evaluate().isNotEmpty,
      'The saved notice must name the file',
    );
    expect(find.widgetWithText(SnackBarAction, 'Show'), findsOneWidget);
    await controller.runJavaScript("document.getElementById('blob').click()");
    await saved([
      'x (1).txt',
      'x.txt',
    ], 'A second download must not replace the first');
    expect(File('${folder.path}/x.txt').readAsStringSync(), 'made here');

    // A download link to a private address passes the address rule first.
    await controller.runJavaScript(
      "document.getElementById('private').click()",
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(requests, isNot(contains('/private')));

    // Opened from the address bar, an attachment and a file the tab cannot
    // show download, and the tab keeps the page it showed. WebKit reports
    // such a load as interrupted (102).
    Future<void> open(String url, String reason) async {
      try {
        await page.browser!.navigate(url);
      } catch (error) {
        note('$reason: opening it must return, not $error');
      }
    }

    await open(
      'https://httpbin.org/response-headers'
          '?Content-Disposition=attachment%3B%20filename%3Dreport.txt',
      'An attachment',
    );
    await saved(['report.txt'], 'An attachment must save under its own name');
    var before = files().length;
    await open('https://httpbin.org/bytes/16', 'A file the tab cannot show');
    await until(
      () => files().length == before + 1,
      'A file the tab cannot show must download',
    );
    if (page.url != 'about:blank' || page.title != 'Links') {
      note('The tab must keep its page');
    }

    // WebKit marks every saved file as downloaded, so macOS asks before the
    // first open, as for Safari's downloads.
    for (final file in folder.listSync()) {
      final mark = await Process.run('xattr', [
        '-p',
        'com.apple.quarantine',
        file.path,
      ]);
      if (mark.exitCode != 0) note('${file.path} has no quarantine mark');
    }

    // A download continues after its tab closes. httpbin sends this file's
    // 8 bytes over 4 seconds.
    before = files().length;
    await open(
      'https://httpbin.org/drip?duration=4&numbytes=8&delay=0',
      'A slow file',
    );
    await until(
      () => find.textContaining('Downloading ').evaluate().isNotEmpty,
      'The downloading notice must show while the file arrives',
    );
    page.dispose();
    disposed = true;
    await tester.pumpWidget(
      MaterialApp(scaffoldMessengerKey: messenger, home: const Scaffold()),
    );
    await until(
      () => find.textContaining('Saved ').evaluate().isNotEmpty,
      'Closing the tab must not stop its download',
      seconds: 20,
    );
    final added = files().length == before + 1
        ? folder.listSync().whereType<File>().map((f) => f.lengthSync())
        : const <int>[];
    if (!added.contains(8)) note('The slow download must hold all 8 bytes');
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}

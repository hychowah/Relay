// Mac check of tab memory readings, a hidden tab's hover-card picture and
// the playing-sound check against real
// WKWebViews. Run it from WSL with `npm run test:mac -- tab_memory_test.dart`,
// which builds under its own bundle id so it cannot read or write the
// installed app's settings and data. Its pages are local documents: no
// server, no records.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:webview_flutter/webview_flutter.dart';

const installedBundleId = 'app.relay.flutterExperiment';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('each tab reads its own process memory, cheaply', (tester) async {
    expect(Platform.isMacOS, isTrue, reason: 'Run on macOS.');
    expect(
      (await PackageInfo.fromPlatform()).packageName,
      isNot(installedBundleId),
      reason: "Run through npm run test:mac so the installed app's data stays untouched.",
    );
    PageSurface open(String id) => createWebPage(
      PageSpec(
        id: id,
        appId: 'browser',
        name: 'Browser',
        sessionId: 'memory-check',
        relayOrigin: Uri.parse('http://127.0.0.1:9'),
      ),
      (_) {},
    );
    final light = open('light'), heavy = open('heavy');
    addTearDown(light.dispose);
    addTearDown(heavy.dispose);
    // Hidden like a tab off screen: Flutter takes its view out of the window.
    Future<void> show({bool heavyHidden = false}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: light.widget),
              Expanded(
                child: Offstage(offstage: heavyHidden, child: heavy.widget),
              ),
            ],
          ),
        ),
      ),
    );
    await show();
    await light.ready.timeout(const Duration(seconds: 20));
    await heavy.ready.timeout(const Duration(seconds: 20));
    WebViewController controller(PageSurface page) =>
        (page as dynamic).controller as WebViewController;

    Future<void> until(Future<bool> Function() done, String reason) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!await done()) {
        expect(DateTime.now().isBefore(deadline), isTrue, reason: reason);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    }

    // The heavy page keeps 200 MB that it has written to, so it is resident.
    await controller(light)
        .loadHtmlString('<!doctype html><title>Light</title>Light page');
    await controller(heavy).loadHtmlString(
      '<!doctype html><title>Heavy</title><script>'
      'window.kept = new Uint8Array(200 << 20).fill(1);'
      "document.title = 'Heavy ready';</script>",
    );
    await until(
      () async => await controller(heavy).getTitle() == 'Heavy ready',
      'The heavy page must fill its memory',
    );

    final reading = await readMemory([light, heavy]);
    final (lightUse, heavyUse) = (reading.pages[light]!, reading.pages[heavy]!);
    expect(lightUse.process, isNot(heavyUse.process));
    expect(
      heavyUse.bytes - lightUse.bytes,
      greaterThan(150 << 20),
      reason: 'Each tab must read its own web process.',
    );
    expect(reading.app, greaterThan(0));

    // What the probe itself costs: each reading is one channel call.
    const reads = 200;
    final watch = Stopwatch()..start();
    for (var i = 0; i < reads; i++) {
      await readMemory([light, heavy]);
    }
    final micros = watch.elapsedMicroseconds / reads;
    binding.reportData = {
      'readingMicroseconds': micros,
      'lightMb': lightUse.bytes >> 20,
      'heavyMb': heavyUse.bytes >> 20,
      'appMb': reading.app >> 20,
    };
    // ignore: avoid_print
    print(
      'TAB MEMORY one reading of 2 tabs: ${micros.round()} µs; '
      'light ${lightUse.bytes >> 20} MB, heavy ${heavyUse.bytes >> 20} MB, '
      'app ${reading.app >> 20} MB',
    );
    expect(micros, lessThan(5000), reason: 'A reading must stay cheap.');

    // A hidden tab's hover-card picture: small, and of the page itself.
    await controller(heavy).runJavaScript(
      "document.documentElement.style.background = 'rgb(200, 0, 0)'",
    );
    await show(heavyHidden: true);
    await tester.pump(const Duration(milliseconds: 300));
    final bytes = await heavy.preview();
    expect(bytes, isNotNull, reason: 'A hidden tab must give a picture.');
    final picture = (await (await ui.instantiateImageCodec(
      bytes!,
    )).getNextFrame()).image;
    final pixels = (await picture.toByteData())!;
    final middle =
        4 * (picture.width * (picture.height ~/ 2) + picture.width ~/ 2);
    final (red, green) = (pixels.getUint8(middle), pixels.getUint8(middle + 1));
    // ignore: avoid_print
    print(
      'TAB PREVIEW hidden tab: ${picture.width}x${picture.height}, '
      '${bytes.length ~/ 1024} KB, middle red $red green $green',
    );
    expect(picture.width, inInclusiveRange(240, 480));
    expect((red > 150, green < 80), (true, true), reason: 'The page is red.');

    // Silent looping audio counts as playing sound, so its tab stays loaded.
    // It is never added to the page, which only WebKit's own flag can see.
    expect(await light.browser!.playing(), isFalse);
    await controller(light).runJavaScript('''
      const wav = new Uint8Array(44 + 8000);
      const view = new DataView(wav.buffer);
      const text = (at, s) => [...s].forEach((c, i) => wav[at + i] = c.charCodeAt(0));
      text(0, 'RIFF'); view.setUint32(4, 36 + 8000, true); text(8, 'WAVEfmt ');
      view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
      view.setUint32(24, 8000, true); view.setUint32(28, 8000, true);
      view.setUint16(32, 1, true); view.setUint16(34, 8, true);
      text(36, 'data'); view.setUint32(40, 8000, true); wav.fill(128, 44);
      const audio = new Audio(URL.createObjectURL(new Blob([wav], {type: 'audio/wav'})));
      audio.loop = true;
      audio.play();
    ''');
    await until(
      () => light.browser!.playing(),
      'A page playing audio must count as playing sound',
    );
  });
}

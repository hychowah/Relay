// Mac check of Browser VPN tabs against real WKWebViews and the Relay
// backend's tunnel. The Mac must be on the tailnet, with the backend deployed
// and NordVPN connected in WSL. Run it from WSL with
// `npm run test:mac -- browser_vpn_test.dart`, which builds under its own
// bundle id and passes the app's Relay origin (`relay.appUrl`) as RELAY_URL.
// Addresses are compared, never printed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:webview_flutter/webview_flutter.dart';

const installedBundleId = 'app.relay.flutterExperiment';
const relayUrl = String.fromEnvironment('RELAY_URL');
const ipCheck = 'https://api.ipify.org';

// Whether WebRTC is there, in the page or, as a page could take it, in a
// fresh frame.
const webrtcScript = '''(() => {
  const frame = document.createElement('iframe');
  document.documentElement.appendChild(frame);
  return [window, frame.contentWindow].some(
    (w) => typeof (w.RTCPeerConnection || w.webkitRTCPeerConnection) === 'function');
})()''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a VPN tab leaves through WSL, WebRTC included', (tester) async {
    expect(Platform.isMacOS, isTrue, reason: 'Run on macOS.');
    expect(
      (await PackageInfo.fromPlatform()).packageName,
      isNot(installedBundleId),
      reason: "Run through npm run test:mac so the installed app's data stays untouched.",
    );
    expect(
      relayUrl,
      isNotEmpty,
      reason: 'npm run test:mac passes relay.appUrl as RELAY_URL.',
    );

    final pages = <PageSurface>[];
    Future<PageSurface> open(String id, {required bool vpn}) async {
      final page = createWebPage(
        PageSpec(
          id: id,
          appId: 'browser',
          name: 'Browser',
          sessionId: 'vpn-check',
          relayOrigin: Uri.parse(relayUrl),
          vpn: vpn,
        ),
        (_) {},
      );
      pages.add(page);
      addTearDown(page.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                for (final page in pages) Expanded(child: page.widget),
              ],
            ),
          ),
        ),
      );
      await page.ready.timeout(const Duration(seconds: 20));
      return page;
    }

    Future<String> address(PageSurface page) async {
      await page.browser!.navigate(ipCheck);
      final text = ((await page.browser!.read())['text'] as String).trim();
      expect(
        InternetAddress.tryParse(text),
        isNotNull,
        reason: 'The IP check page did not show an address.',
      );
      return text;
    }

    final vpn = await open('vpn', vpn: true);
    final normal = await open('normal', vpn: false);
    final home = await address(normal);
    final wsl = await address(vpn);
    expect(
      wsl != home,
      isTrue,
      reason: "The VPN tab showed the Mac's own address.",
    );

    // The tunnel carries only TCP, so WebRTC, whose UDP would show the Mac's
    // address, is off in VPN tabs and on in normal ones.
    Future<bool> webrtc(PageSurface page) async {
      final controller = (page as dynamic).controller as WebViewController;
      final result = await controller.runJavaScriptReturningResult(webrtcScript);
      return ['true', '1'].contains('$result');
    }

    expect(await webrtc(normal), isTrue, reason: 'A normal tab lost WebRTC.');
    expect(await webrtc(vpn), isFalse, reason: 'The VPN tab still has WebRTC.');
  });
}

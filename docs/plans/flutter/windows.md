# Flutter Windows test build

The user asked for a Windows version to try on 2026-11-21. Step 1 is a test
build with chat, tabs, app pages and Browser tabs. It changes R01's deferral
of a Flutter Windows build; the React page stays the Windows fallback until the
user decides otherwise.

## Decisions

- **WebView.** `webview_flutter` has no Windows implementation.
  `webview_all_windows` 1.5.2 (exact pin) renders WebView2 into a Flutter
  texture, so Relay's dialogs and overlays draw over pages, and it cancels
  every main-frame navigation until Dart allows it, which keeps the Browser's
  private-address rule. `lib/windows_web_view.dart` maps the `webview_flutter`
  calls Relay makes onto it, so `web_page.dart` and the Mac path are unchanged.
  The package's native code was scanned for network endpoints (only the NuGet
  download of the WebView2 SDK at build time), not fully reviewed.
  Rejected: `webview_win_floating` (a native window over Flutter hides Relay's
  overlays), `webview_flutter_windows` (no navigation veto), moving all
  platforms to `webview_all` (would replace the Mac's WKWebView plugin that the
  Swift runner depends on).
- **Own HTML page.** WebView2 loads `loadHtmlString` content as a `data:`
  address, which the Browser's rule refused, so its start page never finished.
  The adapter reports it as `about:blank`, as WKWebView and Android do, and
  allows a `data:` main-frame load only right after Relay's own call.
- **Popups** open in the same view (the package default), so they pass the
  same navigation check.
- **Data.** WebView2 keeps its data in the app's data folder, not beside the
  program, so a reinstall keeps website sign-ins.
- **Build.** `tools/build-windows` builds in a temporary copy on the Windows
  drive and installs to `relay.windowsApp`; machine paths live in local git
  config.

## Off on Windows

Everything behind `Platform.isMacOS`: the PDF viewer and highlights, popup
windows, page fullscreen, native selection, page capture, Browser history,
the Safari user agent and in-app updates. WebView2 offers most of these
(`takeScreenshot`, document-start scripts, popup and fullscreen events); each
is a later step if the trial goes well.

## Evidence

- WSL: `flutter analyze` clean; 76 Flutter tests pass (they use fake pages).
- Windows: `flutter doctor` passes for Windows (Flutter 3.50.0, Visual Studio
  2022 17.9, Windows SDK 10.0.22621). Both Relay addresses answer from Windows.
- Windows release build (about 200 s) installed and run against the live
  backend on 2026-11-21, driven by window messages: the app list loaded;
  Research Web opened and sent its context to chat; a Browser tab showed its
  start page with an empty address bar, loaded example.com with its title and
  address, came back after a restart, and refused `192.168.0.1` through the
  address bar check.
- The same build steps were run by hand; `tools/build-windows` itself waits
  for its two git config values and has not run end to end.
- Unverified: a website link or redirect to a private address (the
  navigation check), page dialogs, typing in pages, sign-ins surviving a
  reinstall, and sending a chat message.

## Next

1. User trial on Windows: chat, each app, a Browser sign-in, a page confirm
   dialog, and the unverified items above.
2. Port the Mac-only features the user wants, starting with page capture.
   Before repeated rebuilds, keep one build folder on the Windows drive so
   builds are incremental.

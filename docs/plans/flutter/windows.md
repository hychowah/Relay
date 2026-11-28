# Flutter Windows test build

The user asked for a Windows version to try on 2026-11-21. Step 1 is a test
build with chat, tabs, app pages and Browser tabs. It changes R01's deferral
of a Flutter Windows build; the React page stays the Windows fallback until the
user decides otherwise.

## Decisions

- **WebView.** `webview_flutter` has no Windows implementation.
  `webview_all_windows` 1.5.2 (exact pin) renders WebView2 into a Flutter
  texture, so Relay's dialogs and overlays draw over pages, and it cancels
  every main-frame navigation until Dart allows it.
  `lib/windows_web_view.dart` maps the `webview_flutter` calls Relay makes
  onto it, so `web_page.dart` and the Mac path are unchanged. The package's
  native code was scanned for network endpoints (only the NuGet download of
  the WebView2 SDK at build time), not fully reviewed. Rejected:
  `webview_win_floating` (a native window over Flutter hides Relay's
  overlays), `webview_flutter_windows` (no navigation veto), moving all
  platforms to `webview_all` (would replace the Mac's WKWebView plugin that
  the Swift runner depends on).
- **Own HTML page.** WebView2 loads `loadHtmlString` content as a `data:`
  address, which the Browser's rule refused, so its start page never finished.
  The adapter reports it as `about:blank`, as WKWebView and Android do, and
  allows a `data:` main-frame load only right after Relay's own call.
- **Address rule checked twice.** The package lets the first load after Back,
  Forward or Reload through unasked, and a same-document move leaves that pass
  for any later load. So the adapter also asks the app's own check for every
  address a page starts or moves to, holds page events and channel messages
  until it passes, and replaces a refused page with a blank one that the app
  cannot read. In the Windows test the package asked every time (Back after
  `pushState` by script and by link, a back/forward cache Back, Reload), so
  this second check is tested only with a simulated unasked load.
- **Downloads** are on only for Browser pages, which save them through
  `browser_downloads.dart` as on the Mac; app and report pages save nothing.
  WebView2 marks saved files with Zone.Identifier (ZoneId=3); opening a
  download from the address bar keeps the tab's page (one probe on
  2026-11-28; the Windows test does not check either).
- **Popups** open in the same view (the package default), so they pass the
  same navigation check.
- **Data.** WebView2 keeps its data (sign-ins, cookies, cache) in
  `%APPDATA%\Relay\Relay Flutter\WebView2`, not beside the program, so a
  reinstall keeps it. App pages and Browser tabs share it.
- **Build.** `tools/build-windows` builds in a temporary copy on the Windows
  drive and installs to `relay.windowsApp`; machine paths live in local git
  config.

## Off on Windows

Everything behind `Platform.isMacOS`: the PDF viewer and its highlights,
popup windows, page fullscreen, VPN tabs, native selection, page capture, the
Safari user agent and in-app updates. Browser history and web page highlights are on
for Windows, from the same server records as the Mac; neither is checked on
Windows yet. WebView2 offers most of these
(`takeScreenshot`, document-start scripts, popup and fullscreen events); each
is a later step if the trial goes well.

## Package limits

Measured on Windows with a loopback probe:

- WebView2 sends a page request even when its start is cancelled, so a
  refused private page is requested though never shown or read. The Mac rule
  never covered subresources either.
- The package cancels every allowed load and starts it again as a plain
  address. A link request reaches the server twice: first with its Referer,
  then without. A form POST arrives as a GET without its body, so sign-in
  forms that post fail.
- Restarted at once, an allowed server redirect is dropped and the page stays
  as it was; 10 ms later it loads (25 of 25 on a loopback probe). Google's
  sign-in link is one, so YouTube's **Sign in** did nothing (bug report of
  2026-11-28). The adapter answers the check no sooner than 50 ms.

From the package's code, not measured: 307/308 redirects lose their body; a
cross-site link carries Strict same-site cookies like a typed address; a
page's own `history.back()` across documents adds a history entry.

## Evidence

- WSL: `flutter analyze` clean; 80 Flutter tests pass (they use fake pages).
- Windows: `flutter doctor` passes for Windows (Flutter 3.50.0, Visual Studio
  2022 17.9, Windows SDK 10.0.22621). Both Relay addresses answer from Windows.
- Windows release build (about 200 s) installed and run against the live
  backend on 2026-11-21, driven by window messages: the app list loaded;
  Research Web opened and sent its context to chat; a Browser tab showed its
  start page with an empty address bar, loaded example.com with its title and
  address, came back after a restart, and refused `192.168.0.1` through the
  address bar check.
- `tools/build-windows` ran end to end on 2026-11-28 from `main` at `0563896`,
  with its two git config values set: it built in 138 s, replaced the
  earlier install and left no build folder. The app started, stayed up for
  two minutes with its window responding, and closed on a close signal.
  Nothing inside it was tried: the build holds the shell refactor, tab
  squeezing and reordering, the split pane controls and site icons, none of
  which has run on Windows. The user then used it and reported the YouTube
  sign-in bug; it was rebuilt the same day from `379c6b2`, which has the fix,
  and the user opened that build.
- `integration_test/windows_web_view_test.dart` passes on Windows: a link,
  a server redirect and loads after Back are refused and never shown, a
  simulated unasked load is replaced by the blocked page, an allowed redirect
  loads (fails without the 50 ms answer), and an attachment saves nothing.
  On 2026-11-28 a probe through the adapter and the Browser's rule reached
  Google's sign-in page from YouTube's **Sign in**; finishing a sign-in is
  not checked.
- Unverified: page dialogs, typing in pages, sign-ins surviving a reinstall,
  and sending a chat message.
- Cross-device chat and tabs: source only. 107 server and 80 Flutter tests
  pass. The backend was deployed and Stable 0.0.17 published with them on
  2026-11-23; no run across both devices has been made.

## Next

On 2026-11-23 the user said they are not testing Windows for now; items 1
and 3 wait for that.

1. With Stable 0.0.22 on the Mac and the Windows app built on 2026-11-28
   (`379c6b2`), check on the Mac and Windows: the
   chat opened last on one device opens on the other when it comes to the
   front, a new unsaved chat is not pulled back, and **Open Mac's tabs here**
   copies the Mac's tabs once. Also check Browser history and highlights on
   Windows.
2. Ask the user how old device cards go away: a device that reinstalls gets a
   new id, and its old tabs stay on the server, outside Stored data.
3. User trial on Windows: chat, each app, a page confirm dialog, a Browser
   tab unloading after 30 minutes off screen and the unverified items above. Form sign-ins that post fail while the adapter sets
   the package's check. Without it the package does not restart loads, so posts
   should work, and only the second check would guard addresses; then a refused
   page would load and might show until it is replaced. Neither is measured.
4. Port the Mac-only features the user wants, starting with page capture.
   Before repeated rebuilds, keep one build folder on the Windows drive so
   builds are incremental.

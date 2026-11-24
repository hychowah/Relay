# Relay Flutter client

Flutter is the main client on the Mac. Windows uses the React browser fallback;
see also the [Windows test build](#windows-test-build).
Flutter owns tabs, chat and address input; system WebViews render existing apps
and public websites. The WSL backend owns all model calls and credentials.

Uses Flutter 3.50.0 / Dart 3.14.0; dependency versions are pinned in pubspec.lock.
Use a Flutter SDK of that version; this machine's SDK location is in the local machine notes.

`packages/webview_flutter_wkwebview` is a copy of that package's 3.27.2
release with two additions (pubspec.yaml overrides the package with it):
`websiteDataStoreIdentifier` on `WebKitWebViewControllerCreationParams`, a
named, persistent WebKit profile, which VPN tabs use; and, on macOS, a file
chooser for `<input type="file">` in `UIDelegateProxyAPIDelegate.swift`,
without which WebKit ignores the click. The package's bridge
files are generated: change `pigeons/web_kit.dart`, then in that folder run
`flutter pub get` and `dart run pigeon --input pigeons/web_kit.dart` (pigeon
is pinned so the output matches the committed files), and format the output
with `dart format --page-width 100` and Xcode's `swift-format`. On a package
upgrade, reapply the additions, or drop the copy if the package gains them.

```sh
flutter pub get
flutter analyze
flutter test
```

Start the Flutter backend from the repository root:

```sh
npm ci --ignore-scripts
npm rebuild @opencode/cli
node --import tsx tools/flutter-experiment.ts
```

With the backend running, run the HTML bridge check in another terminal. It starts
its own temporary Room Layout fixture:

```sh
node tests/flutter-host.smoke.mjs
```

The backend listens on 3250, with its own `runtime/flutter/` data.
Default mode is scripted. To use the saved DeepSeek connection,
set `RELAY_PROVIDER_DIR` to import the existing private provider settings once;
subsequent provider changes belong to this deployment.
Keys remain in WSL and existing provider VPN checks apply. No keys go in Dart defines.
If the connection uses a key file, also set `DEEPSEEK_API_KEY_FILE` on the backend.

`RELAY_APPS_FILE` optionally adds existing HTTP integrations beside Browser,
using Relay's usual registration format. For example:

```json
[{"id":"my-app","name":"My app","serverUrl":"http://127.0.0.1:4000","browserUrl":"http://<device-reachable-host>:4000","trustedNative":true}]
```

Each app must allow the Flutter Relay origin in its own launcher. Preserve its
existing origins when adding one. Set `trustedNative` only for an app you trust.
The backend applies changes to that file without a restart; the app picker,
App library and Bots dialog show them when they open. See
[Registration](../docs/integration.md#registration).

`RELAY_SERVERS_FILE` optionally names the app servers the App servers screen
controls; see [Manage app servers](../README.md#manage-app-servers).

The Mac app needs macOS 14 or later.
A Mac build needs full Xcode and Flutter's macOS plugin toolchain. Android needs
its SDK/device. The official WebView plugin does not support Linux, so WSL tests
use fake page surfaces and separately exercise the real HTML app bridge.

For remote devices, forward the WSL port through the private tailnet and set
`FLUTTER_RELAY_ORIGIN` to its device-reachable origin when starting the
backend. Give the app the same origin once in WSL:

```sh
git config --local relay.appUrl http://<device-reachable-host>:<relay-port>
```

The app has no built-in server address. `tools/publish-flutter` builds every
published app with this value as `RELAY_URL`. A build without it talks to
`127.0.0.1` and cannot reach its backend or its update feed.

`Relay Flutter.app` uses the private `/flutter-updates/` release channel.

On a configured Mac, run the native WebView check with
`flutter test integration_test/workflow_test.dart -d macos`. Add
`--dart-define=LIVE_AGENT=true` to exercise the configured DeepSeek backend too;
this sends one real request and verifies browser reading and Research presentation.
A fixture deployment that explicitly registers Room uses that example by default.
The native check also exercises conversation creation, search, Trash and restore
against the Flutter deployment's records without making a model request for those actions.

Chat supports history/Trash, provider/model selection, conversation thinking effort,
bots with app scopes, memory editing, forwarding, Markdown, saved sources and activity.
Devices share one server. The conversation last opened on any device opens on
each device when it starts or comes back to the front, unless that device chose
or sent in a chat meanwhile. A new chat is not saved until its first message, so
it stays open on its device but a restart opens the last saved one. Each device
keeps its own tabs and saves them on the server; the new tab page lists the
other devices, and **Open ⟨device⟩'s tabs here** opens a copy beside the tabs
already open. Nothing follows live afterwards. Saved tabs, like the browsing
history, are not given to the agent.
Desktop chat width is saved; phones use an overlay with a compact progress/Stop bar.
**Workspace menu → Appearance** sets Relay's own screens to System (the default),
Light or Dark, saved per device. System follows the device's appearance as it
changes. Pages from apps and websites keep their own look, and the Mac title bar
follows macOS. **Newest tab first**, in the same menu, off by default and saved per device,
slides each tab you click or open, or the agent opens, to the left end of the strip.
App tabs retain their views until closed. On desktop, a Browser tab off screen
for 30 minutes unloads to free its memory, unless its page plays sound; its time
off screen counts from when it falls silent. It keeps its address and title, and
loads again, without a new history visit, when shown or when the agent reads it.
If that load fails, as when the network is not back after waking, the tab stays
unloaded with the error; clicking it, Reload, Go or the agent showing a view in
it tries again. A VPN tab loads again on the VPN. On the Mac WebKit says
whether a page plays sound; on Windows only the page's own audio and video
elements are seen. The agent's first read of an unloaded tab waits for the page,
so a slow page can run past the read's time limit; reading again works. On
2026-11-23 the user accepted that unloading loses text typed in the page but not
sent, and closes the tab's popup windows. Every start, including an
update restart, reopens the previous tabs and their views, the conversation, the
draft and the chat panel as it was left; the Mac window keeps its size and position.
The last active tab shows first, and the other tabs load together in the background.
A tab that cannot be restored is reported; **Reconnect** retries it during that run.
A VPN tab stays open with the error instead, though possibly without its address.
All pages except VPN tabs share WebKit's persistent website data, which keeps cookies between starts.
On desktop only, drag a tab onto a page to split it. A new split tab opens in
the tab strip. The page's edge nearest the pointer (left, right, top or bottom)
is where the tab goes, and the highlighted half shows it. Drop more tabs onto
any pane to split it again, side by side or stacked; dropping a tab that is
already in the split moves it. The split tab has an accent outline and a small
map of its panes, with the last selected pane filled. Click a pane to select it.
Each Browser pane has its own address bar, so selecting a pane never resizes a
page; a bar narrower than 480 pixels leaves out **Go**, the PDF zoom buttons
(Enter and a pinch do the same) and the VPN button's label. Only the selected
pane's bar takes clicks and the keyboard. Drag a divider to resize its two
sides, or double-click it to return to half and half. Click an app's own tab
to show it full screen, and the split tab to return to the split. Closing the
split tab ends the split and keeps every app open. Drag a tab from the split
back onto the tab strip to take it out; closing an app's tab takes it out of
every split. Narrow windows show only the selected tab.

On macOS only, a page in a Browser tab that opens a sized window on a user
action (`window.open` with a width or height), as **Continue with Google**
does, gets its own popup window titled with the site's host, beside its tab.
The page and its popup can talk to each other and share sign-in. The popup
closes when its page closes it, when the user closes it, or when its tab or the
main window closes. Popup pages follow the Browser's address rule, and windows
that pages open without a user action stay blocked. Any other new window, such
as a link that opens a new tab, loads in the same tab as before, so a sign-in
that opens an unsized window loses its opener.
App views keep sending a new window's address to the default browser. A page
dialog raised inside a popup window is not shown.

On macOS only, **VPN** beside Reload sends a Browser tab's pages, its popups
and the PDFs it shows through the Relay backend, which tunnels them (HTTP
CONNECT on the backend's existing port) out of WSL through NordVPN. New tabs
start with it off; the setting is saved with the tab. While on, the switch is
a filled "VPN" button and the tab's chip shows a lock in place of the globe.
Switching reopens the tab's address in a new web view, without its back
history. Nothing falls back to the Mac's network: if the route fails, for
example while NordVPN in WSL is off, the page does not load and says so, and a
VPN tab that could not be set up loads nothing. VPN tabs share one WebKit
profile of their own, so their sign-ins persist and stay apart from normal
tabs. The backend applies the Browser's address rule to them, looking names up
through NordVPN. WebRTC is off in VPN tabs, through a private WebKit setting that also covers frames
(popups take the opener's settings), so video calls do not work there: the
tunnel carries only TCP, and WebRTC's UDP would show the Mac's own address. A
macOS without that setting does not load VPN tabs. The Windows client ignores
the setting.

A click that focuses the Browser address bar selects the whole address, as in
other browsers; a further click places the caret.

On the desktop (Windows not yet checked), the Browser address bar suggests
pages visited before once you
type in it, best first by how often and how recently each was visited; an
address opened from the address bar counts more than a followed link, and
pages the agent opens in a Browser tab count as visits too. As in Chrome, the
best suggestion's address fills in after what you type when it starts with it,
with the filled-in part selected; Backspace or Esc removes it, and a paste
fills nothing in. Arrow keys and Enter, or a click, open a suggestion. With
none highlighted, Enter opens the suggested page while its address is filled
in, and otherwise what was typed. The history is kept on the Relay server, one
entry per address, so every desktop using that server shares it. The agent and app
integrations never get it, and history requests are left out of bug recordings
(the addresses you type are still recorded as navigation). Pages not visited
for 90 days drop out unless **Stored data** says otherwise.

**Workspace menu → Stored data** lists what the Relay server keeps as you
work, for every device that uses it: browsing history and highlights now, and
any kind the server adds later. Each kind shows how many items it holds and
their size, and has a clear button. **Auto-clean** forgets a kind's items once
they are older than the number of days you set; turned off, they are kept
until you clear them. Browsing history starts at 90 days and highlights start
with auto-clean off. A period is saved with **Save**; when it would delete
items now, the button first says how many and a second click agrees. The
server cleans at start, every hour and when a period is saved.

On the desktop (Windows not yet checked), select text on a page or PDF in a
Browser tab: once the mouse is released, a menu of colours shows beside it,
and a colour marks the text. Click marked text for the same menu, with its
colour ticked, to change the colour or remove the mark (a second click on
**Remove** confirms). The menu hides while the page scrolls or a PDF zooms.
**Highlight** beside the address bar marks the selected text in yellow.
Highlights are kept on the Relay server for the page's address (without its
#fragment), so they return on the next visit and on every desktop. A web page's highlight is the quoted text and a little of the text
around it, not a place in the page: it shows wherever that text is on a page
with that address, and only while it is there. A page that redraws itself, or
changes its content under one address as single-page apps do, keeps its
highlights on the right text, and a view without that text shows none.
Highlights are painted without changing the page's own elements. Text inside a
frame, such as an embedded document, cannot be highlighted. Like browsing
history, highlights are never given to the agent or to app integrations, and
their requests are left out of bug recordings. A page's own scripts can read
the highlights kept for that page's address, since they are shown in the page;
they never get another address's.

On macOS only, a video's fullscreen button works in a Browser tab, also for a
player embedded from another site that allows fullscreen. In split view the
video fills its own pane, address bar included. A tab shown alone takes the
whole screen: the tab strip, address bar and chat hide and the window enters
macOS fullscreen.
Escape, the player's own button, or leaving macOS fullscreen ends it, and so
does another tab opening, or the player leaving the page. As in a browser, only
a click or key press can start it, and each one starts it once. A video in a
popup window fills only that window.

On macOS only, a PDF opened in a Browser tab shows in the Mac's own PDF viewer
(PDFKit, as in Preview) in place of WebKit's. **Zoom out**, **Zoom in** and
**Fit to width** appear beside an address bar at least 480 pixels wide, and a
pinch zooms too.
**Highlight** works as on web pages; a PDF's highlight also keeps where its
lines are drawn, so a PDF that changes under the same address can show old
highlights in the wrong place. Text selected in the PDF shows in the chat's
page context at once and goes with the next question. The agent's
`browser.read` gets the PDF's text from the page in view onward, with that
page's number and the page count. A link in the PDF opens in the tab, under
the Browser's address rule.
Relay fetches the PDF a second time for this viewer, with the tab's cookies
and only from the address the tab shows: a redirect is not followed. If the
fetch fails, or the PDF needs a password, WebKit's own view stays, without
these features. A PDF embedded inside a web page keeps the page's own viewer.
The viewer reads the PDF in Relay's own process, which is not sandboxed, where
WebKit reads it in its sandboxed web process.

On macOS, select page or PDF text and ask a question with page context enabled.
With a YouTube video open in a Browser tab, ask about the video: the agent reads
its full transcript page by page through the page itself (`browser.transcript`,
desktop only). Videos without captions have no transcript. **Transcript** above
the conversation opens the same transcript; text selected there is sent as the
question's selection in place of the page's, until newer text is selected on
the page or the pane is clicked or closed. While the video plays, the pane
highlights the paragraph being spoken and scrolls to it, except during ads.
Scrolling or selecting in the pane stops the scrolling until **Follow video**.
Use **Capture an area** beside the model picker, then drag over the active tab
itself; chat stays open on desktop. Releasing the drag flashes the area like a
camera, and the picture flies into the composer, attached for the next question.
With Reduce Motion it attaches at once. Escape or **Cancel** leaves the tab unchanged.
Image input works with Claude and OpenAI. The service keeps a sent screenshot with its
message, so reopening the chat shows it again; Trash hides it and the 24-hour
Trash cleanup deletes it with the conversation.

### Mac checks

`npm run test:mac -- <name>_test.dart`, from the repository root on WSL, runs
one self-contained integration test on the Mac against real WKWebViews:
`popup_windows_test.dart` (with its own loopback fixture),
`tab_memory_test.dart` (about three minutes), which checks each tab's memory
figure, reports what a reading costs, pictures a tab hidden for two minutes and
plays silent audio to check the playing-sound rule,
`video_fullscreen_test.dart`, which puts the test window into macOS fullscreen
for a few seconds, `pdf_viewer_test.dart`, which opens one arXiv paper as
a PDF and as a web page and so needs the internet on the Mac, or
`highlight_clicks_test.dart`. That one drags and clicks with real mouse
events (a debug build's runner queues them), so the Mac must be awake,
unlocked and left alone for about half a minute: with its lid closed, or
another app in front, the app cannot come forward and no click arrives.
Queued events never hold the mouse button down, so a PDF press always ends
at once there; by hand, drag-select and click a highlight in a PDF, click
elsewhere after dragging the PDF's scroll bar, and highlight on a few real
sites, one a single-page app; and hold a press on the menu, and on
**Highlight** beside the address bar, for a second before releasing. Like the
smoothness suite below, it builds a temporary copy under its own bundle id,
`app.relay.flutterTest`, and removes the copy and the test app's data
afterwards. It refuses `workflow_test.dart`,
which uses the Flutter deployment's records.
`browser_vpn_test.dart` checks that a VPN tab's address, over https and plain
http, differs from a normal tab's; that WebRTC is gone from it, even in a
fresh frame, but not from a normal tab; that a closed page stops at once; and
that a VPN tab whose setup failed loads nothing. It needs the Mac on the
tailnet, the deployed backend and NordVPN in WSL; the tool passes
`relay.appUrl` to it as `RELAY_URL`.

### Measure performance

Run these from the repository root on WSL now and then; they have no pass or
fail. `npm run perf:ui` measures smoothness. For about three minutes a test
window shows on the Mac: leave the Mac unused, with the window visible and
Reduce Motion off. The test app has its own bundle id, `app.relay.flutterPerf`,
and the run removes its data afterwards. Scenarios: the chat panel, typing, tab
switching, the transcript pane, scrolling a 2,000-message conversation and a
streaming reply. Results go to `tmp/perf/ui-*.json` and are compared with the
last run. They cover only Flutter's part of each frame.

`npm run perf:stress` uses the same test app for about five minutes. It repeats
opening and closing ten web tabs, switching through 20 conversations and
opening the transcript pane, and reports memory growth per cycle after warm-up.
It then streams a long reply into a 10,000-message conversation with 15 tabs
open while scrolling and switching tabs, and reports smoothness and memory.
Results go to `tmp/perf/stress-*.json`.

`npm run perf:mem` reads the memory of the installed app and its WebKit
processes, adds it to `tmp/perf/mem.jsonl` and shows recent readings; run it
during a day of use to see growth. It only reads the process list and memory
figures. Memory is the physical footprint that Activity Monitor shows. WebKit
processes count for the app whose launchd domain started them, so other apps'
pages are excluded; WebKit's shared GPU and networking processes count in full.

On macOS, **Show tab memory** in the Workspace menu puts each tab's memory on its
chip while it is on, the same physical footprint. Every two seconds one native
call reads all tabs; nothing is read while it is off or Relay is not the active
app, and the strip redraws only when a shown figure changes. A tab's process
comes from WebKit's private `_webProcessIdentifier`, so a WebKit update can make
the figures disappear.

Also on macOS, resting the pointer on an app's or a website's tab for half a
second shows its card: the title, a small picture of the page when the tab is
off screen (none for a PDF in Relay's viewer), and the memory of its web process
(whole, when tabs share one), of all pages and of Relay itself. An unloaded tab's
card says so, or that it is loading again, or why loading failed. The card
captures the picture, 240 points wide, and reads the memory once as it opens.
The picture is kept only in the card's memory, never saved or sent, and is gone
when the card closes.

## Mac updates

The app checks the update feed at startup, every minute and when its window
comes to the front, and downloads a new build in the background. A check that
finds the same feed entry as the last one does nothing more; a download that
failed is tried again after an hour, or at once with Refresh. A dot on the
Workspace menu button and its Updates item marks a downloaded update ready to
install. Workspace menu → Updates shows progress;
**Install and restart** remains manual and waits for this window's agent work.
The package is checked against the release hash, bundle signature, identity and
version before replacement. The previous app is kept only until the new version
starts; that version then removes it, with older launch receipts on the Mac.
Downloads are removed once a check finds the installed build current. Every
published Stable package stays in the served release directory on WSL for
recovery. The app uses ad-hoc signing outside the App Store. It is not
sandboxed so it can replace its own bundle; WebKit still owns web-content processes.

Updates download only changed files. Publishing stores each file of the app once
in the release directory's `files/` folder, compressed and named by the SHA-256
of its content, with a list of the build's files, symlinks and executable flags
that the manifest's `fileList` names. The app reuses its own unchanged files and
downloads the rest, usually the compiled Dart code and the app binary: about
7 MB instead of the 20 MB ZIP. Finished files are kept if the connection drops.
Install builds the app beside the current one from these files, checking each
against the list, then runs the same signature and identity checks. A release
without a list, or an app with an older updater, uses the ZIP. Publishing and
worktree removal delete stored files that neither `latest.json` nor a listed
test build uses; ZIPs are not touched.

Set the served release directory once in WSL. Linked worktrees share this Git setting.

```sh
git config --local relay.flutterReleases /absolute/path/to/served/runtime/flutter/releases
```

Publish Stable from a checkout whose Flutter changes are committed, after
increasing `pubspec.yaml`'s version:

```sh
tools/publish-flutter --stable
```

The command builds on the Mac in a temporary folder and removes it, so no build
tree stays there. It records the commit in `latest.json` and removes from Updates
the test builds that Stable contains: those built from a clean tree at a commit
in Stable's history. The initial updater-enabled package must be installed once
manually. Later downloads use the private Tailscale service and never require
model credentials on the Mac.

### Publish a worktree test build

From a worktree on a branch, containing the preview-capable updater, run:

```sh
tools/publish-flutter search-input
```

Choose a short, distinct name for each experiment. Reuse it to publish the next
iteration. The command builds the current Flutter source on the Mac, including
local edits, and records the branch, commit, dirty flag and build time. Each name has its own
entry. The ZIP is addressed by SHA-256, so a download keeps the exact build selected.
Previews can use the same app version as each other and Stable.

**Workspace → Updates** shows when the installed app and each test build were
built, such as "24 min ago, 2026-11-23 14:05"; a build with no recorded time
shows none. Choose a test build, then **Install and restart**.
From a preview, **Stable** switches back even at the same or a lower version. Background checks
follow the installed build's feed. Drafts and tabs go through the usual restart flow.

From another Relay checkout, run `tools/remove-worktree <path>` to retire a
feature worktree. After Git removes it, its branch’s listed previews disappear
from Updates and their unshared ZIPs are deleted. Older unlisted ZIPs stay on
disk. Merging alone keeps previews available until Stable contains them. If a
build started with the older publisher, let it finish before removing its worktree.

Publishing needs an SSH wrapper. Configure it once in WSL:

```sh
git config --local relay.macSSH /absolute/path/to/ssh-mac
```

The SSH wrapper runs a supplied command on the build Mac and passes stdin/stdout
through. The build Mac needs the Flutter SDK at the path `tools/publish-flutter` uses. Client-only
previews use the usual backend. For a server change, run its test backend with
separate data and set `RELAY_URL` when publishing.
The update feed stays at its usual private origin. Set `RELAY_UPDATE_URL` only
to change the feed itself. Worktrees based on an older client must bring in the
picker before publishing so their users can return to Stable.

Public tabs check top-level navigation to private addresses. See the
[Flutter plan](../docs/plans/flutter/master-plan.md) for WebView limits, native
verification and deferred platform work.

## Windows test build

Desktop only. On Windows, `lib/windows_web_view.dart` puts WebView2 (through
`webview_all_windows`) behind the same `webview_flutter` interface, so the
rest of the client is unchanged. The [Windows record](../docs/plans/flutter/windows.md)
lists the Mac-only features that are off there.

The build PC needs Flutter 3.50.0 for Windows, Visual Studio 2022 with
**Desktop development with C++**, the WebView2 runtime and Windows
**Developer Mode**, which Flutter needs for plugin symlinks. Configure once in WSL:

```sh
git config --local relay.windowsFlutter 'C:\path\to\flutter'
git config --local relay.windowsApp 'C:\path\to\Relay Flutter'
```

Then run `tools/build-windows`. It builds in a temporary folder on the Windows
drive with the same `relay.appUrl` as Mac builds,
replaces the program in `relay.windowsApp` and removes the temporary folder.
Settings and website data (sign-ins, cookies, cache, shared by app pages and
Browser tabs) stay in `%APPDATA%\Relay\Relay Flutter`. Close the app before
rebuilding.

`integration_test/windows_web_view_test.dart` checks the Browser's address rule
and that nothing downloads, against a real WebView2 with a loopback fixture and
a temporary data folder. Run it with `flutter test
integration_test/windows_web_view_test.dart -d windows` from a copy of
`flutter/` on the Windows drive.

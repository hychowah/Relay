# Developing Relay

How to build, test, measure and publish Relay. Read [AGENTS.md](../AGENTS.md)
and the [master plan](plans/prototype/master-plan.md) first. Paths, addresses
and other details of one machine stay in the local machine notes that AGENTS.md
names, outside the repository.

## Before a change is merged

Run from the repository root:

```sh
npm test
npm run build
python3 tools/check_records.py
```

For a change to the Flutter client, also run its [checks](#flutter-client).

## Bug reports and requests

In the Flutter app, press the record button at the top right, reproduce the
problem or show the screen in question, then press the red record button
again. Choose **Bug**, **Feature request** (something new) or **Update
request** (a change to something that exists) and describe it. The recording
holds your actions, each server request and reply (a repeated poll reply is
kept once; Browser history and highlight requests are left out, though
addresses typed in the address bar are still recorded as navigation), error
messages, the open tabs and a screenshot of the whole window, at most 2,000
pixels on its longest side, with each shown page's own snapshot in place (a
page that cannot be captured shows as a grey area marked "Page not
captured"). Pixels are not redacted, so the picture shows whatever was on
screen.

On the desktop the recording also holds a trace of each loaded Browser tab,
which Relay cannot otherwise see inside: the link or item under the mouse each
time it changes or the mouse leaves the page, the mouse position about five
times a second and every jump over 40 pixels, scrolling with the content's
height, wheel input, the page's focus, size and visibility, and each time the
page's own code scrolls or focuses an element (at most every 100 ms per
element), with the value and where in its code the call came from. Elements
are named by tag, id, role, label (`aria-label`) or first 40 characters of
text. Key presses are not recorded, nor text inside input fields, text areas
and editable elements, but a name can still hold text the page shows
elsewhere: an editor drawn from plain elements, a preview, a suggestion or a
sent message. The trace's first note keeps the page's full address, query
included, and stack lines keep the addresses of the page's scripts; the
service's redaction goes by field name, so tokens in an address stay. A
page's own scripts can send notes too: Relay takes only the trace's kinds of
note with short plain fields, at most 1,000 a recording, and the report counts
the rest as refused. A **stop pressed** action marks the end of the
reproduction. A recording keeps its latest 2,000 events, a few minutes with
the mouse moving over a page; the report counts any older ones it dropped.

The service saves it as `bug-reports/<time>-<id>.json` (with a `.png`)
in `RELAY_DATA_DIR`, adds its own record of the conversation and replaces API
keys and other secret fields with `[redacted]`. Reports contain conversation
text, so they stay with the runtime data, outside the repository. Choose
**Reports** in the workspace menu to read them: each shows its description,
screenshot (click it to open it full size) and a timeline of events that
expand to their full details.

The chips above the list show all reports or one category; the chip under a
report's description moves it to another category. Mark a report solved with
the circle beside it (click again to reopen it); the header counts open and
solved reports. The bin button deletes the report and its screenshot. The
report file saves `status` (`open` or `solved`) and `category` (`bug`,
`feature` or `update`; older reports without one are bugs).

## Measure the service's performance

Run `npm run perf` on Linux (WSL) from time to time to see how speed changes
as the project grows. It is not a test and has no pass or fail. In about 10–45
seconds, depending on machine load, and with no network or API keys, it seeds
a temporary database with synthetic conversations, memories and a
2,000-message conversation. It then measures server startup, the median time
and response size of the main HTTP reads (including the conversation list,
its search, and `GET /api/conversations/:id`, which the Flutter client polls
every second), the median message round trip with the scripted provider,
server peak memory, and the web build's JS and CSS sizes. The round trip moves
in roughly 400 ms steps because the server polls the agent harness, so it
shows only large slowdowns. Add `-- --skip-build` to leave out the web build.

Each run is saved in `tmp/perf/` and the table shows the change from the
previous run. Sizes and memory more than 20% larger are marked; timings are
not, because they vary by tens of percent between runs. The numbers depend on
the machine, so compare runs from the same machine. Each run also records the
machine load and warns when it was busy; repeat such a run on a quiet machine.
For the Flutter client, see [Measure the client's
performance](#measure-the-clients-performance).

## Flutter client

The client's features are in its [README](../flutter/README.md). Flutter owns
tabs, chat and address input; system WebViews render existing apps and public
websites. The WSL backend owns all model calls and credentials.

### Toolchain and checks

The client uses Flutter 3.50.0 / Dart 3.14.0; dependency versions are pinned in
`pubspec.lock`. Use a Flutter SDK of that version. In `flutter/`:

```sh
flutter pub get
flutter analyze
flutter test
```

The official WebView plugin does not support Linux, so WSL tests use fake page
surfaces and separately exercise the real HTML app bridge. A Mac build needs
macOS 14 or later, full Xcode and Flutter's macOS plugin toolchain. Android
needs its SDK and a device.

`flutter/packages/webview_flutter_wkwebview` is a copy of that package's
3.27.2 release with two additions (`pubspec.yaml` overrides the package with
it): `websiteDataStoreIdentifier` on `WebKitWebViewControllerCreationParams`, a
named, persistent WebKit profile, which VPN tabs use; and, on macOS, a file
chooser for `<input type="file">` in `UIDelegateProxyAPIDelegate.swift`,
without which WebKit ignores the click (shown only on a visible web view). The
package's bridge files are generated: change `pigeons/web_kit.dart`, then in
that folder run `flutter pub get` and `dart run pigeon --input
pigeons/web_kit.dart` (pigeon is pinned so the output matches the committed
files), and format the output with `dart format --page-width 100` and Xcode's
`swift-format`. On a package upgrade, reapply the additions, or drop the copy
if the package gains them.

### Run the Flutter backend

Start it from the repository root:

```sh
npm ci --ignore-scripts
npm rebuild @opencode/cli
node --import tsx tools/flutter-experiment.ts
```

With the backend running, run the HTML bridge check in another terminal. It
starts its own temporary Room Layout fixture:

```sh
node tests/flutter-host.smoke.mjs
```

The backend listens on 3250, with its own `runtime/flutter/` data. Default mode
is scripted. To use the saved DeepSeek connection, set `RELAY_PROVIDER_DIR` to
import the existing private provider settings once; subsequent provider changes
belong to this deployment. Keys remain in WSL and existing provider VPN checks
apply. No keys go in Dart defines. If the connection uses a key file, also set
`DEEPSEEK_API_KEY_FILE` on the backend.

`RELAY_APPS_FILE` optionally adds existing HTTP integrations beside Browser,
using Relay's usual registration format. For example:

```json
[{"id":"my-app","name":"My app","serverUrl":"http://127.0.0.1:4000","browserUrl":"http://<device-reachable-host>:4000","trustedNative":true}]
```

Each app must allow the Flutter Relay origin in its own launcher. Preserve its
existing origins when adding one. Set `trustedNative` only for an app you trust.
The backend applies changes to that file without a restart; the app picker,
App library and Bots dialog show them when they open. See
[Registration](integration.md#registration).

`RELAY_SERVERS_FILE` optionally names the app servers the App servers screen
controls; see [Manage app servers](../README.md#manage-app-servers).

For remote devices, forward the WSL port through the private tailnet and set
`FLUTTER_RELAY_ORIGIN` to its device-reachable origin when starting the
backend. Give the app the same origin once in WSL:

```sh
git config --local relay.appUrl http://<device-reachable-host>:<relay-port>
```

The app has no built-in server address. `tools/publish-flutter` builds every
published app with this value as `RELAY_URL`. A build without it talks to
`127.0.0.1` and cannot reach its backend or its update feed.

### Checks on the Mac

On a configured Mac, run the native WebView check with
`flutter test integration_test/workflow_test.dart -d macos`. Add
`--dart-define=LIVE_AGENT=true` to exercise the configured DeepSeek backend
too; this sends one real request and verifies browser reading and Research
presentation. A fixture deployment that explicitly registers Room uses that
example by default. The native check also exercises conversation creation,
search, Trash and restore against the Flutter deployment's records without
making a model request for those actions.

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

### Measure the client's performance

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

**Show tab memory** reads all tabs in one native call every two seconds while
it is on and Relay is the active app, and the strip redraws only when a shown
figure changes. A tab's process comes from WebKit's private
`_webProcessIdentifier`, so a WebKit update can make the figures disappear.

### How some features work

- VPN tabs use HTTP CONNECT on the Relay backend's existing port; the backend
  looks names up through NordVPN and applies the Browser's address rule.
  WebRTC is turned off with a private WebKit setting that also covers frames
  (popups take the opener's settings); a macOS without that setting does not
  load VPN tabs.
  The Windows client ignores the VPN setting.
- The PDF viewer is the Mac's PDFKit. Relay fetches the PDF a second time for
  it, with the tab's cookies and only from the address the tab shows; a
  redirect is not followed. The viewer reads the PDF in Relay's own process,
  which is not sandboxed, where WebKit reads it in its sandboxed web process.
- Highlights are painted without changing the page's own elements.
- The agent reads a YouTube transcript with `browser.transcript` and a PDF's
  text with `browser.read`.
- Address-bar suggestions and highlights are not yet checked on Windows.

## Publish the Flutter app

`Relay Flutter.app` uses the private `/flutter-updates/` release channel. The
app checks the feed at startup, every minute and when its window comes to the
front, and downloads a new build in the background. A check that finds the
same feed entry as the last one does nothing more; a download that failed is
tried again after an hour, or at once with Refresh. The package is checked
against the release hash, bundle signature, identity and version before
replacement. The previous app is kept only until the new version starts; that
version then removes it, with older launch receipts on the Mac. Downloads are
removed once a check finds the installed build current. Every published Stable
package stays in the served release directory on WSL for recovery. The app
uses ad-hoc signing outside the App Store. It is not sandboxed so it can
replace its own bundle; WebKit still owns web-content processes.

Updates download only changed files. Publishing stores each file of the app
once in the release directory's `files/` folder, compressed and named by the
SHA-256 of its content, with a list of the build's files, symlinks and
executable flags that the manifest's `fileList` names. The app reuses its own
unchanged files and downloads the rest, usually the compiled Dart code and the
app binary: about 7 MB instead of the 20 MB ZIP. Finished files are kept if the
connection drops. Install builds the app beside the current one from these
files, checking each against the list, then runs the same signature and
identity checks. A release without a list, or an app with an older updater,
uses the ZIP. Publishing and worktree removal delete stored files that neither
`latest.json` nor a listed test build uses; ZIPs are not touched.

Set the served release directory once in WSL. Linked worktrees share this Git
setting.

```sh
git config --local relay.flutterReleases /absolute/path/to/served/runtime/flutter/releases
```

Publishing needs an SSH wrapper. Configure it once in WSL:

```sh
git config --local relay.macSSH /absolute/path/to/ssh-mac
```

The SSH wrapper runs a supplied command on the build Mac and passes
stdin/stdout through. The build Mac needs the Flutter SDK at the path
`tools/publish-flutter` uses.

### Stable

Publish Stable from a checkout whose Flutter changes are committed, after
increasing `pubspec.yaml`'s version:

```sh
tools/publish-flutter --stable
```

The command builds on the Mac in a temporary folder and removes it, so no build
tree stays there. It records the commit in `latest.json` and removes from
Updates the test builds that Stable contains: those built from a clean tree at
a commit in Stable's history. The initial updater-enabled package must be
installed once manually. Later downloads use the private Tailscale service and
never require model credentials on the Mac.

### Publish a worktree test build

From a worktree on a branch, containing the preview-capable updater, run:

```sh
tools/publish-flutter search-input
```

Choose a short, distinct name for each experiment. Reuse it to publish the
next iteration. The command builds the current Flutter source on the Mac,
including local edits, and records the branch, commit, dirty flag and build
time. Each name has its own entry. The ZIP is addressed by SHA-256, so a
download keeps the exact build selected. Previews can use the same app version
as each other and Stable.

**Workspace → Updates** shows when the installed app and each test build were
built, such as "24 min ago, 2026-11-23 14:05"; a build with no recorded time
shows none. Choose a test build, then **Install and restart**. From a preview,
**Stable** switches back even at the same or a lower version. Background checks
follow the installed build's feed. Drafts and tabs go through the usual restart
flow.

From another Relay checkout, run `tools/remove-worktree <path>` to retire a
feature worktree. After Git removes it, its branch's listed previews disappear
from Updates and their unshared ZIPs are deleted. Older unlisted ZIPs stay on
disk. Merging alone keeps previews available until Stable contains them. If a
build started with the older publisher, let it finish before removing its
worktree.

Client-only previews use the usual backend. For a server change, run its test
backend with separate data and set `RELAY_URL` when publishing. The update feed
stays at its usual private origin. Set `RELAY_UPDATE_URL` only to change the
feed itself. Worktrees based on an older client must bring in the picker before
publishing so their users can return to Stable.

See the [Flutter plan](plans/flutter/master-plan.md) for WebView limits,
native verification and deferred platform work.

## Windows test build

Desktop only. On Windows, `flutter/lib/windows_web_view.dart` puts WebView2
(through `webview_all_windows`) behind the same `webview_flutter` interface, so
the rest of the client is unchanged. The [Windows record](plans/flutter/windows.md)
lists the Mac-only features that are off there.

The build PC needs Flutter 3.50.0 for Windows, Visual Studio 2022 with
**Desktop development with C++**, the WebView2 runtime and Windows
**Developer Mode**, which Flutter needs for plugin symlinks. Configure once in
WSL:

```sh
git config --local relay.windowsFlutter 'C:\path\to\flutter'
git config --local relay.windowsApp 'C:\path\to\Relay Flutter'
```

Then run `tools/build-windows`. It builds in a temporary folder on the Windows
drive with the same `relay.appUrl` as Mac builds, replaces the program in
`relay.windowsApp` and removes the temporary folder. Settings and website data
(sign-ins, cookies, cache, shared by app pages and Browser tabs) stay in
`%APPDATA%\Relay\Relay Flutter`. Close the app before rebuilding.

`integration_test/windows_web_view_test.dart` checks the Browser's address rule
and that nothing downloads, against a real WebView2 with a loopback fixture and
a temporary data folder. Run it with `flutter test
integration_test/windows_web_view_test.dart -d windows` from a copy of
`flutter/` on the Windows drive.

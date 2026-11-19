# Relay Flutter client

Flutter is the main client on the Mac. Windows uses the React browser fallback.
Flutter owns tabs, chat and address input; system WebViews render existing apps
and public websites. The WSL backend owns all model calls and credentials.

Uses Flutter 3.50.0 / Dart 3.14.0; dependency versions are pinned in pubspec.lock.
Use a Flutter SDK of that version; this machine's SDK location is in the local machine notes.

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

The backend listens on 3250 (Relay) and 3251 (Browser broker), with its own
`runtime/flutter/` data. Default mode is scripted. To use the saved DeepSeek connection,
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

A Mac build needs full Xcode and Flutter's macOS plugin toolchain. Android needs
its SDK/device. The official WebView plugin does not support Linux, so WSL tests
use fake page surfaces and separately exercise the real HTML app bridge.

For remote devices, forward both WSL ports through the private tailnet and
set `FLUTTER_RELAY_ORIGIN` and `FLUTTER_BROWSER_ORIGIN` when
starting the backend to their device-reachable origins. Give the app the same
origins once in WSL:

```sh
git config --local relay.appUrl http://<device-reachable-host>:<relay-port>
git config --local relay.browserUrl http://<device-reachable-host>:<browser-port>
```

The app has no built-in server address. `tools/publish-flutter` builds every
published app with these two values as `RELAY_URL` and `BROWSER_URL`. A build
without them talks to `127.0.0.1` and cannot reach its backend or its update feed.

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
Desktop chat width is saved; phones use an overlay with a compact progress/Stop bar.
**Workspace menu → Appearance** sets Relay's own screens to System (the default),
Light or Dark, saved per device. System follows the device's appearance as it
changes. Pages from apps and websites keep their own look, and the Mac title bar
follows macOS. **Newest tab first**, in the same menu, off by default and saved per device,
slides each tab you or the agent open, new or already open, to the left end of the
strip. Clicking a tab only switches to it.
Browser and app tabs retain their views until closed. Every start, including an
update restart, reopens the previous tabs and their views, the conversation, the
draft and the chat panel as it was left; the Mac window keeps its size and position.
The last active tab shows first, and the other tabs load together in the background.
A tab that cannot be restored is reported; **Reconnect** retries it during that run.
All pages share WebKit's persistent website data, which keeps cookies between starts.
On desktop only, drag a tab onto the left or right half of the page to show two
tabs side by side; click a pane to select it. Drag the divider between them to
resize the panes, or double-click it to return to half and half. Click the
button in the middle of the divider, drag a split tab back onto the tab strip,
or close one, to end the split. Narrow windows show only the selected tab.

On macOS only, a page in a Browser tab that opens a new window on a user action,
such as **Continue with Google**, gets its own popup window titled with the
site's host, beside its tab. The page and its popup can talk to each other and
share sign-in. The popup closes when its page closes it, when the user closes
it, or when its tab or the main window closes. Popup pages follow the Browser's
address rule, and windows that pages open without a user action stay blocked.
App views keep sending a new window's address to the default browser. A page
dialog raised inside a popup window is not shown.

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
Image input currently uses Claude. The service keeps a sent screenshot with its
message, so reopening the chat shows it again; Trash hides it and the 24-hour
Trash cleanup deletes it with the conversation.

### Mac checks

`npm run test:mac -- popup_windows_test.dart`, from the repository root on WSL,
runs that self-contained integration test on the Mac against real WKWebViews,
with its own loopback fixture. Like the smoothness suite below, it builds a
temporary copy under its own bundle id, `app.relay.flutterTest`, and removes
the copy and the test app's data afterwards. It refuses `workflow_test.dart`,
which uses the Flutter deployment's records.

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

## Mac updates

Downloads run at startup and hourly. Workspace menu → Updates shows progress;
**Install and restart** remains manual and waits for this window's agent work.
The package is checked against the release hash, bundle signature, identity and
version before replacement. The previous app is kept only until the new version
starts; that version then removes it, with older downloads and launch receipts
on the Mac. Every published Stable package stays in the served release directory
on WSL for recovery. The app uses ad-hoc signing outside the App Store. It is not
sandboxed so it can replace its own bundle; WebKit still owns web-content processes.

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
local edits, and records the branch, commit and dirty flag. Each name has its own
entry. The ZIP is addressed by SHA-256, so a download keeps the exact build selected.
Previews can use the same app version as each other and Stable.

In **Workspace → Updates**, choose a test build, then **Install and restart**.
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
separate data and set `RELAY_URL` and, if needed, `BROWSER_URL` when publishing.
The update feed stays at its usual private origin. Set `RELAY_UPDATE_URL` only
to change the feed itself. Worktrees based on an older client must bring in the
picker before publishing so their users can return to Stable.

Public tabs check top-level navigation to private addresses. See the
[Flutter plan](../docs/plans/flutter/master-plan.md) for WebView limits, native
verification and deferred platform work.

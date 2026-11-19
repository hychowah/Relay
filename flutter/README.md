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
Restart the Flutter backend and reopen Flutter after changing registrations.

A Mac build needs full Xcode and Flutter's macOS plugin toolchain. Android needs
its SDK/device. The official WebView plugin does not support Linux, so WSL tests
use fake page surfaces and separately exercise the real HTML app bridge.

For remote devices, forward both WSL ports through the private tailnet and
set `FLUTTER_RELAY_ORIGIN` and `FLUTTER_BROWSER_ORIGIN` when
starting the backend to their device-reachable origins. Then build on the Mac:

```sh
flutter build macos --release \
  --dart-define=RELAY_URL=http://<device-reachable-host>:<relay-port> \
  --dart-define=BROWSER_URL=http://<device-reachable-host>:<browser-port>
```

The app has no built-in server address. A build without these two values talks
to `127.0.0.1` and cannot reach its backend or its update feed.
`tools/publish-preview` reads them from `git config --local relay.appUrl` and
`relay.browserUrl`.

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
Browser and app tabs retain their views until closed. Update restart restores tabs
and the draft; ordinary restarts retain the conversation and draft.

On macOS, select page or PDF text and ask a question with page context enabled.
Use **Capture an area** beside the model picker, then drag over the active tab
itself; chat stays open on desktop. Releasing the drag attaches the area to the
composer for the next question, and Escape or **Cancel** leaves the tab unchanged.
Image input currently uses Claude.

## Mac updates

Downloads run at startup and hourly. Workspace menu → Updates shows progress;
**Install and restart** remains manual and waits for this window's agent work.
The package is checked against the release hash, bundle signature, identity and
version before replacement; the previous bundle stays beside the install staging
folder for recovery. The app uses ad-hoc signing outside the App Store. It is not
sandboxed so it can replace its own bundle; WebKit still owns web-content processes.
The first sandboxed prototype's preferences are copied on first launch.

Set the served release directory once in WSL. Linked worktrees share this Git setting.

```sh
git config --local relay.flutterReleases /absolute/path/to/served/runtime/flutter/releases
```

Build on the Mac, archive the app, then publish from the WSL checkout:

```sh
# Mac, from flutter/
flutter build macos --release
ditto -c -k --sequesterRsrc --keepParent \
  'build/macos/Build/Products/Release/Relay Flutter.app' RelayFlutter.zip
# WSL, from repo root, after transferring that archive
releases=$(git config --get relay.flutterReleases) &&
  node tools/publish-flutter.mjs path/to/RelayFlutter.zip "$releases"
```

Increase `pubspec.yaml`'s version before publishing another Stable build. The initial
updater-enabled package must be installed once manually. Later downloads use the
private Tailscale service and never require model credentials on the Mac.

### Publish a worktree test build

From a worktree containing the preview-capable updater, run:

```sh
tools/publish-preview search-input
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
disk. Merging alone keeps previews available. If a build started with the
older publisher, let it finish before removing its worktree.

The preview builder also needs an SSH wrapper. Configure it once in WSL:

```sh
git config --local relay.macSSH /absolute/path/to/ssh-mac
```

The SSH wrapper runs a supplied command on the build Mac and passes stdin/stdout
through. The build Mac needs the Flutter SDK at the path `tools/publish-preview` uses. Client-only
previews use the usual backend. For a server change, run its test backend with
separate data and set `RELAY_URL` and, if needed, `BROWSER_URL` when publishing.
The update feed stays at its usual private origin. Set `RELAY_UPDATE_URL` only
to change the feed itself. Worktrees based on an older client must bring in the
picker before publishing so their users can return to Stable.

Public tabs check top-level navigation to private addresses. See the
[Flutter plan](../docs/plans/flutter/master-plan.md) for WebView limits, native
verification and deferred platform work.

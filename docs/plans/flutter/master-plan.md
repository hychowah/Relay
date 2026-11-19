# Flutter main client
Status: active

## Scope and authority

Develop new client features in Flutter for the MacBook. Its baseline is merged
into local `main`. The [client platform decision](../prototype/phases/phase-01/decisions/0002-client-platform.md)
records the Windows fallback, Android goal and scope of future platform trials.

Keep model credentials, provider switching, VPN checks, conversations and tools
on WSL. Browser websites use the Mac network. Research's agent operations are
read-only. Bounded DeepSeek checks use the previously authorized connection.

## Implementation

Flutter owns tabs and chat; official system WebViews render apps and public pages.
`PageSurface` separates native view lifetime from workspace/context policy.
The existing v2 bridge runs in an app-owned iframe; saved reports use the existing
v1 bridge. Preserve device/window/view-token/generation checks and manual
interruption. Browser connects to its existing broker via an outbound WebSocket.
The client registers its app-control channel on hosted app views. Tabs retain views until closed.

The implemented workflows include the following.

- Conversation creation, search, bot filtering, switching, Trash and restore.
- Provider/model discovery and settings, with conversation thinking effort.
- Bots and app scopes, shared/bot memories, source conversations and forwarding.
- Markdown, citations, saved revisions/highlights, activity, checkpoints and app search.
- Browser back/forward/reload, context inclusion, desktop width persistence,
  phone progress/Stop controls and chat-only mode.
- Background update downloads with progress, verified caches and manual
  install/restart. Flutter has its own release channel.
- Every start restores the previous tabs and views, the draft, the chat panel
  state and the Mac window frame. Tabs are saved as they change.
- Development bug recording: actions, server exchanges, errors, tabs and a page
  screenshot are saved on the service as a report and read in the Bug reports
  viewer (see the root README).

`server/runtime.ts` shares the existing harness/provider lifecycle between the
web and Flutter deployments. Provider settings are imported once into Flutter's
private runtime. Subsequent changes apply only to that deployment.

The Mac updater uses an ad-hoc-signed, outside-App-Store bundle. The host is no
longer App Sandbox restricted so it can replace its own bundle. Download
verification and native replacement remain separate; replacement keeps the
previous bundle until the new version starts.

The workspace uses compact tabs and grouped menus. Chat keeps model, thinking
and page context controls in the composer, with history and new chat in the
header. Replies group activity, Markdown and saved sources by turn.

## Running environment

Flutter 3.50.0 / Dart 3.14.0, pinned dependencies. Bundle identity:
`app.relay.flutterExperiment`. Building a package does not replace the installed
app. The backend entry is `tools/flutter-experiment.ts`; it listens on 3250
(Relay) and 3251 (Browser). Research is registered at its own server with
`trustedNative: true` for PDF embedding, and its launcher allows the Flutter
origin. SDK locations, the Mac build setup, services and addresses are in the
local machine notes named in AGENTS.md. The Flutter README holds build, test
and publication commands.

## Evidence and remaining checks

Baseline native checks passed tab retention, Browser reads, Room and Research
navigation/highlights, and real DeepSeek Browser→Research comparison. The user
confirmed the original prototype works. Conversation history/Trash passed on Mac.

After the 2026-11-18 cleanup, 25 Flutter tests, analysis, 80 backend tests
and the web build pass.
Chromium checks pass v2 presentation and v1 Research source reopening/highlights.
The Mac replacement helper passed against an isolated signed fixture app,
including relaunch, receipt, previous-bundle retention and a preserved draft.

Native verification found and fixed nested URL decoding that corrupted Research
`#/...` resource IDs in saved views. A focused regression test preserves the
encoded document route and bridge token. The full native rerun passed with a real
DeepSeek Browser→Research comparison, retained tabs, history/Trash and saved-source
highlighting. The test explicitly renders frames when an SSH-launched window is
occluded; this changes only the test harness.

The real-agent check also exposed failed-presentation retry state. Both clients
now acknowledge the actual returned context on failure, allowing a corrected
retry while retaining failed status. Backend/client regressions verify that stale
manual actions do not advance this state and question context remains unchanged.
The full 78-test backend suite passed after the fix.

The actual Dart installer passed on an isolated Mac bundle: verified background
download, signature/identity/version checks, preparation, process exit, replacement,
relaunch and preserved draft. It did not replace the installed user app.
The first sandboxed prototype's device, conversation and draft preferences were
copied to the current app on the Mac; that one-time copy has since been removed.

Stable 0.0.8 (build 8) is published on the private feed with the workspace
transitions, text selection and region capture, and no built-in server address.
Before publication the native Mac workflow passed on this source against the
deployed backend, with one real DeepSeek request: Browser read through the
built-in Browser service, Research reads, an applied Research presentation,
retained tabs, the conversation lifecycle and a saved-source presentation. Its
first run found that a message sent during a poll left the workspace idle for
up to a second; `send` now waits for that poll, with a regression test.
In an isolated Mac install, two worktrees published separate 0.0.6 previews;
installing the first and returning to equal-version Stable preserved a synthetic
draft. Source tests also cover returning to a lower Stable version, keeping a
verified download during a feed outage and checking backend activity before
restart. For setup and publishing, see [Mac updates](../../../flutter/README.md#mac-updates).

Public-page guards cover top-level navigation. webview_flutter 4.14.1 lacks
subresource interception, a download API and separate data stores. JavaScript
channel access from sandboxed subframes, PDF rendering in WKWebView and behavior
on physical Android devices remain unverified. The [platform decision](../prototype/phases/phase-01/decisions/0002-client-platform.md)
records supported platforms and the Windows constraint.

Pre-commit review fixed update-session loss when the backend is unavailable:
Reconnect retries unfinished tabs and clears the saved session only on success.
It also fixed the first snapshot interaction being mistaken for native initial
context. Focused regressions cover both; they are included in release 0.0.4.
Native interaction tests were not rerun for this packaging pass.

The motion and comment changes passed analysis, 27 Flutter tests,
nine bridge tests and five Browser tests. An isolated Mac test exercised chat
toggling, tab creation/removal and menu opening with a retained WKWebView. The
Browser comment rendered, dismissed and stayed out of page reads. The window
was occluded, so this did not measure perceived smoothness. Chromium verified
Room comment placement and dismissal at desktop and compact sizes, including
reduced motion.

Everyday restoration passed analysis and 32 Flutter tests on WSL. They cover
saving tabs as they change, an offline start, a failed tab retried by Reconnect,
an unused Browser tab and the chat panel state. The Mac release build compiles
with the window frame change. The user installed the `restore-state` preview of
this source on the Mac and confirmed that it works. The separate cases were not
reported one by one: a tab whose app is stopped and a website sign-in surviving
a restart remain unconfirmed. The installed app's cookie file and WebKit website
data exist on disk.

The updater's leftover removal passed analysis and 37 Flutter tests on WSL,
including one for replaced apps, old receipts and old downloads. On the Mac,
bash 3.2 kept a copy of the helper's wait loop running after its folder was
deleted, and it exited normally when the receipt appeared. No installed build
has run the removal yet.

`tools/publish-flutter` now publishes test builds and Stable from a temporary
folder on the Mac, in place of the hand-run Stable build. A test with a stand-in
for the Mac covers a test build, Stable's recorded commit, the refusals and
Stable retiring the test builds it contains. A real Stable build through the
tool, into a throwaway release folder, compiled on the Mac without the settings
copy, recorded its commit, refused a second run and left no folder on the Mac.

Stable 0.0.9 (build 9) is published from `main` with that tool. Beyond 0.0.8 it
carries everyday restoration, the updater's leftover removal, inline region
capture, saved screenshots, bug reports and draft conversations. Analysis, 38
Flutter tests and 82 backend tests passed on its commit. The feed serves the
release with its commit, the download matches its hash, and publishing retired
the one listed test build that Stable contains. The native Mac workflow was not
rerun for 0.0.9, and it has not been installed or reviewed on the Mac.

Three profile runs on the MacBook Neo (60 Hz, 1280 × 739 logical pixels)
measured 18 opens and 18 closes per surface with 24 synthetic messages, on the
source of 2026-11-18, before Stable 0.0.9.
Opening exceeded the 16.7 ms build budget on 3/269 empty-tab frames and
3/270 loaded-WKWebView frames. Closing stayed within budget on all 540 frames.
The longest interval between Flutter frames was 33.3 ms on an empty-tab open.
The [benchmark](../../../flutter/README.md#measure-the-conversation-panel-animation)
covers the Flutter shell. Final screen presentation and real pages remain unmeasured.

## Next

1. Install Stable 0.0.9 on the Mac. Check that tabs, the chat panel and the
   window come back after a restart, and that its first start removes the
   update folders beside the app and the older downloads.
2. Deploy the backend at `main`. The live service predates draft conversations,
   so a thinking effort chosen before a new conversation's first message is not
   applied there.
3. Republishing a test build's name leaves its earlier ZIP in the release
   folder on WSL. Remove it at publish time if that folder grows.
4. Review Stable 0.0.9 on the Mac: the panel, tab and menu transitions and text selection. Compare any reported panel hitch with a fresh run of the fixture benchmark, whose recorded numbers predate 0.0.9, including native presentation timing if it appears only over web content. The Mac PDF probe recovered selected text after focus moved to chat. A real Claude image reply, a Research PDF on the device and Stop during a presentation are unverified.
5. Region capture selecting inside the active tab, and sent screenshots shown again in reopened chats, are in Stable 0.0.9. Widget and service tests cover the crop, Escape, chat staying docked, the saved image and its Trash lifecycle; dragging over a live WKWebView and loading a saved screenshot on the Mac are unverified.
6. Try the toolbar record button and **Bug reports**, both in Stable 0.0.9, on the Mac. Source tests cover recording,
   saving and viewing; native screenshots and the live service's report folder are unverified.
7. The native workflow's Browser step loads a public shop page that sometimes answers slowly or with 429. Point it at a steadier page if that recurs.
8. Check on the Mac that opening a YouTube video updates the Browser address, tab title and Back button; only a faked web view tests this.

Browser isolation and PDF checks remain open. The Android device trial, Windows Flutter build and phone work each await a separate request.

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
interruption. Browser connects to Relay via an outbound WebSocket.
The client registers its app-control channel on hosted app views. Tabs retain views until closed.

The [Flutter README](../../../flutter/README.md) describes what the client does.

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
app. The backend entry is `tools/flutter-experiment.ts`; it listens on 3250.
Research is registered at its own server with
`trustedNative: true` for PDF embedding, and its launcher allows the Flutter
origin. SDK locations, the Mac build setup, services and addresses are in the
local machine notes named in AGENTS.md. The [development guide](../../development.md) holds build, test
and publication commands.

## Evidence and remaining checks

Baseline native checks passed tab retention, Browser reads, Room and Research
navigation/highlights, and real DeepSeek Browser→Research comparison. The user
confirmed the original prototype works. Conversation history/Trash passed on Mac.

Chromium checks pass v2 presentation and v1 Research source reopening/highlights.
The Mac replacement helper passed against an isolated signed fixture app,
including relaunch, receipt, previous-bundle retention and a preserved draft.

Native verification found and fixed nested URL decoding that corrupted Research
`#/...` resource IDs in saved views, with a regression test; the full native
rerun then passed. The test renders frames itself when an SSH-launched window is
occluded.

The actual Dart installer passed on an isolated Mac bundle: verified background
download, signature/identity/version checks, preparation, process exit, replacement,
relaunch and preserved draft. It did not replace the installed user app.

Before Stable 0.0.8 (no built-in server address), the native Mac workflow
passed against the deployed backend with one real DeepSeek request: Browser
read, Research reads and presentations, retained tabs and the conversation
lifecycle. It found a send during a poll idling up to a second; fixed, with a test.
In an isolated Mac install, two worktrees published separate 0.0.6 previews;
installing the first and returning to equal-version Stable preserved a synthetic
draft. Source tests also cover returning to a lower Stable version, keeping a
verified download during a feed outage and checking backend activity before
restart. For setup and publishing, see [Publish the Flutter app](../../development.md#publish-the-flutter-app).

Public-page guards cover top-level navigation. webview_flutter 4.14.1 lacks
subresource interception, a download API and separate data stores. JavaScript
channel access from sandboxed subframes, PDF rendering in WKWebView and behavior
on physical Android devices remain unverified. The [platform decision](../prototype/phases/phase-01/decisions/0002-client-platform.md)
records supported platforms and the Windows constraint.

The motion and comment changes passed an isolated Mac test of chat toggling,
tabs and menus with a retained WKWebView, where the Browser comment stayed out of
page reads; the window was occluded, so smoothness was not judged. Chromium
verified Room comments at desktop and compact sizes, including reduced motion.

Everyday restoration has WSL tests (saving tabs as they change, an offline
start, Reconnect, the chat panel), and the user confirmed the `restore-state`
preview on the Mac. A tab whose app is stopped and a website sign-in surviving
a restart remain unconfirmed.

The updater's leftover removal has a WSL test for replaced apps, old receipts
and old downloads. On the Mac, the helper's bash 3.2 wait loop survived its
folder's deletion and exited when the receipt appeared. No installed build has
run the removal yet.

`tools/publish-flutter` publishes test builds and Stable from a temporary Mac
folder. A test with a stand-in Mac covers test builds, Stable's recorded commit,
the refusals and retiring contained test builds. A real Stable build through it,
into a throwaway release folder, recorded its commit and left nothing on the Mac.

Updates download only changed files, about 7.3 MB instead of the 20.4 MB ZIP.
On 2026-11-19 the Mac updated one `small-updates` build to the next through its
file list: it passed the signature check, restarted and left no downloads.

On 2026-11-19 the [UI smoothness suite](../../development.md#measure-the-clients-performance)
held 57–60 fps on the MacBook Neo (60 Hz), with waits up to 117 ms on tab
switches; WebKit presentation is unmeasured. After the transcript pane fix, its
median frame build fell from 3.15 to 0.88 ms (one run before and one after).
Stress runs the same day found no Relay leak (closed tabs release their web
processes; conversation and transcript cycles stay level), but with 10,000
messages nearly every one-second poll causes a visible frame wait. The installed
app reached about 3.3 GB after 1.2 h, about 90% in WebKit with one page at
1.5 GB, on an 8 GB Mac already using 6–7 GB of swap.

Restoring tabs adds every saved tab and shows the last active one at once, then
loads all pages together without selecting them. A tab the user picks meanwhile
stays selected, and the conversation loads without waiting for the tabs.
Analysis and 40 Flutter tests passed on WSL, including one that holds every page
unready. Reading the code shows that each WKWebView starts loading when its page
is created, before it is shown; the user's restart check of 2026-11-26 is
below.

Stable 0.0.17 and 0.0.18 were published from `main` on 2026-11-23, 0.0.19 and
0.0.20 on 2026-11-24 and 0.0.21 on 2026-11-26; the commit history has what
each adds. 0.0.21 (`2040f8c`) holds the [shell
refactor](../shell-refactor/master-plan.md): nothing new to see, except that
an unloaded Browser tab shows its address. Analysis, 168 Flutter tests, 143
backend tests and the type check passed on its commit. The user asked for it
("release. a stable version") after a hand check of test build
`shell-closeout` (`545dad6`); of the client code merged after that build,
`981387c`, only WSL tests ran. No test build is listed now. The backend and
the web page service run `92f7bc5` since 2026-11-26. Each now answers only
requests that name its own address (`FLUTTER_RELAY_ORIGIN`, `RELAY_ORIGIN`),
and the host page frames only app pages. The backend also has the Files
hardening, the agent's form instructions, and the closing of VPN-tab
connections when NordVPN drops (a real drop is untested). Checked with curl
from WSL and from Windows through both tailnet forwards: 200 at each service's
own addresses, 403 for a foreign Host. Stable 0.0.21 on the Mac has since run
against it. Of
earlier builds the user said 0.0.19's test build all works well, without
testing unloading, and wrote "confirm file picker is working" (2026-11-24;
build not recorded), read as a report that it works; which checks below they
made is not recorded. Nothing in 0.0.20 or 0.0.21 has run through the native
Mac workflow.

On 2026-11-26 the user reported testing Stable 0.0.21 on the Mac, with no
problems reported: quitting and reopening with a Browser tab and two or more
app tabs brought back the window, tabs and chat panel, the last active tab
first and the chat history without waiting; chat and app tabs loaded under
the Host check; the split tab, night mode, the YouTube transcript pane and
Reports. Which detailed cases they tried is not recorded.

Browser popups (desktop only): webview_flutter_wkwebview 3.27.2 loaded a
page's new window into its opener, which broke sign-in popups. A forwarding UI
delegate in the Mac runner now opens sized new windows as child popups; others
load in the tab. `npm run test:mac -- popup_windows_test.dart` checks this with
real WKWebViews.
`video_fullscreen_test.dart` checks video fullscreen with a real WKWebView.

## Next

1. Check on the Mac that Stable 0.0.21's first start removed the update
   folders beside the app and the older downloads. Ask the user whether their
   pass of 2026-11-26 covered these details, which it did not name: hidden tabs
   finishing within the 20 s limit; the transcript pane's following, seeking,
   pausing and ads; split-tab dividers and per-pane address bars; night mode
   following a live macOS switch; and Reports' whole-window screenshot.
2. Republishing a test build's name leaves its earlier ZIP in the release
   folder on WSL. Remove it at publish time if that folder grows.
3. Review Stable 0.0.21 on the Mac: the panel, tab and menu transitions and text selection. Compare any reported hitch with a fresh `npm run perf:ui`. The suite's longest waits, on tab switches, are candidates for a smoothness fix. A real Claude image reply, a Research PDF on the device and Stop during a presentation are unverified.
4. Region capture selecting inside the active tab, and sent screenshots shown again in reopened chats, are in Stable since 0.0.9. Widget and service tests cover the crop, Escape, chat staying docked, the saved image and its Trash lifecycle; dragging over a live WKWebView and loading a saved screenshot on the Mac are unverified. The capture animation is in Stable 0.0.17: on the Mac, check that the flash and the flight to the composer run smoothly over a real page, and that the thumbnail takes over without a jump.
5. On the Mac, check that a hidden tab's page cannot open the file chooser and
   that the chooser names the asking site.
6. Re-run `hover_redraw_test.dart` on the MacBook Neo after each Flutter
   upgrade. It passed there on 2026-11-26 (main 0dbccc3 plus a fix for
   WKWebView returning the row count as 40.0). It guards the fix in 111e7ca
   (Stable 0.0.20): the runner skips re-adding a web view to its own parent,
   which made a page's hover jump on each redraw.
7. The native workflow's Browser step loads a public shop page that sometimes answers slowly or with 429. Point it at a steadier page if that recurs.
8. Check on the Mac that opening a YouTube video updates the Browser address, tab title and Back button; only a faked web view tests this.
9. Check on the Mac that an app added to the live apps file appears in the app picker without Reconnect, and that a removed one leaves its open tab in place. Service and widget tests cover this, and the live backend applied a file edit without a restart; the Mac is unverified.
10. Ask the real agent about a short and an hour-long YouTube video on the Mac,
   and note how long `browser.transcript` takes in WKWebView against its
   7-second limit. Its page script passed against live YouTube only in
   headless Chromium with a Safari user agent.
11. Check on the Mac that Analysis Web, registered as trusted, shows the
   confirm dialog of **Start analysis**, titled with the page's host, and that OK starts the analysis and
   Cancel does not. Page alert and confirm dialogs are tested only with a faked
   web view.
12. Try **Newest tab first** on the Mac with real pages open: clicking a tab,
   a new tab, an app opening and an agent opening a tab should each slide that
   tab smoothly to the left end while the others move right, also when the
   strip is scrolled. Only widget tests cover the order and the slide.
13. In Stable 0.0.14, sign in to figma.com with **Continue with
   Google**: the popup shows its host, closes itself and leaves Figma signed in.
   Close a tab, and the main window, with a popup open. New-tab links stay in the tab.
14. Next smoothness work: an unchanged poll is no longer decoded or redrawn
   (the user confirmed the idle hover stopped jumping), but a changed one still decodes the whole conversation on the UI thread.
   Decode large bodies off the UI isolate. Check with `npm run perf:ui` and
   `npm run perf:stress`.
15. On 2026-11-23 a hidden Figma tab held 1.1 GB. The user chose to unload
   Browser tabs after 30 silent minutes off screen (a model may choose later)
   and accepted that this loses unsent typed text and closes the tab's popups.
   Check on the Mac: a hidden page unloads, its process exits (`npm run
   perf:mem`), and it reloads at its address; tab hover cards show the page
   and its memory.
16. On the Mac, try YouTube fullscreen alone, in a split pane and embedded in
   another site, then leave macOS fullscreen by hand: the tab strip and chat
   must return. A video in a sign-in popup must fill only the popup; a popup
   opened with `noopener` has no opener, so it would still reach the tab's
   fullscreen. Restarting an embedded player within 5 s of leaving needs a
   page click. 0.0.15 filled the page, not YouTube's video (user report);
   0.0.16 has the fix, which Mac probes showed filling the window alone and
   each pane in a split.
17. Browser history (desktop only) is in Stable 0.0.16 and on the live
   backend. Check on the Mac: one titled entry per
   redirect or reload; instant, clickable suggestions; a restored tab's page
   is not counted again; one title per visit; inline fill-in (none after
   paste; Right+Enter opens real URL) and first-click select-all.
18. The PDF viewer and highlights passed `npm run test:mac --
   pdf_viewer_test.dart` on 2026-11-20. By hand on the Mac: drag-select in
   an arXiv PDF, click chat and send (the question must carry the
   selection), and open **Stored data**. Unverified: a password-protected
   PDF. Why 0.0.16 lost the selection is unknown; embedded PDFs still use
   that path. `highlight_clicks_test.dart` passed on the MacBook Neo on 2026-11-26 (main
   545dad6), one run; in Stable 0.0.18, make the development guide's by-hand highlight checks and
   check drag smoothness, then mark the 2026-11-23 report solved.
19. Check **Updates** build times on Mac.
20. Form filling (`browser.form`, `browser.fill`; desktop only) has passed only
   Chromium and WSL tests. On the Mac, in Stable 0.0.21, ask
   the real agent to fill a test form in WKWebView: the outlines show, the page
   scrolls to the first field, a React form takes the values and Relay does not
   submit. A fill aimed at a hidden tab, or made while the conversation is
   expanded, must be refused, and hidden fields must not be listed. Also share
   a test folder holding a PDF in **Shared folders** and have the real provider
   search and read it; the server changes for it are live since 2026-11-26
   ([decision 0003](../prototype/phases/phase-01/decisions/0003-shared-folders-and-form-filling.md)).

Browser isolation and PDF checks remain open. The Android device trial and phone work each await a separate request. See the [Windows test build](windows.md).

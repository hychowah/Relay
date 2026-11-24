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
is created, before it is shown; no Mac run has yet confirmed that hidden tabs
load on the real WebViews.

Stable 0.0.17 and 0.0.18 were published from `main` on 2026-11-23 and 0.0.19
on 2026-11-24. 0.0.19 adds OpenAI, VPN tabs, tab memory with unloading and a
hover card, and update checks each minute; the commit history has the earlier
ones. Analysis, 105 Flutter tests and 124 backend tests passed on its commit.
The backend was deployed on 2026-11-23 at `2d7d489`. The user asked for
each release and said of 0.0.19's test build that all works well, but did not
test unloading; which checks below they made is not recorded, and the native
Mac workflow was not rerun.

Test build `pre-0-0-20` (`7a1df86`, 2026-11-24) holds what was merged after
0.0.19: report categories, an address bar in each split pane, the Mac file
chooser, the page trace in bug recordings, no redraw for an unchanged
conversation poll, and the hover fix. Analysis, 107
Flutter tests and 127 backend tests passed on its commit, and the backend was
deployed at that commit the same day. The user asked for the build in reply to
an offer of a deploy and a build, and chose two report categories, Bug and
Request. The user said the file picker is working (2026-11-24; with which
build is not recorded). Nothing in this build has run through the native Mac
workflow, and the web page service was not redeployed.

Browser popups (desktop only): webview_flutter_wkwebview 3.27.2 loaded a
page's new window into its opener, which broke sign-in popups. A forwarding UI
delegate in the Mac runner now opens sized new windows as child popups; others
load in the tab. `npm run test:mac -- popup_windows_test.dart` checks this with
real WKWebViews.
`video_fullscreen_test.dart` checks video fullscreen with a real WKWebView.

## Next

1. Install Stable 0.0.19 on the Mac. Check that tabs, the chat panel and the
   window come back after a restart, and that its first start removes the
   update folders beside the app and the older downloads.
2. Republishing a test build's name leaves its earlier ZIP in the release
   folder on WSL. Remove it at publish time if that folder grows.
3. Review Stable 0.0.19 on the Mac: the panel, tab and menu transitions and text selection. Compare any reported hitch with a fresh `npm run perf:ui`. The suite's longest waits, on tab switches, are candidates for a smoothness fix. A real Claude image reply, a Research PDF on the device and Stop during a presentation are unverified.
4. Region capture selecting inside the active tab, and sent screenshots shown again in reopened chats, are in Stable since 0.0.9. Widget and service tests cover the crop, Escape, chat staying docked, the saved image and its Trash lifecycle; dragging over a live WKWebView and loading a saved screenshot on the Mac are unverified. The capture animation is in Stable 0.0.17: on the Mac, check that the flash and the flight to the composer run smoothly over a real page, and that the thumbnail takes over without a jump.
5. On the Mac, try the record button and **Reports** against the live
   backend: save, view, mark solved, delete and the categories Bug and
   Request; check that the whole-window screenshot shows the chat, a split and
   a Browser comment over a page, and that pages still click and scroll. Record
   any ChatGPT scroll snapping back: script scrolls are noted. For the file
   chooser, check that a hidden tab's page cannot open it and that it names
   the asking site.
   A page's hover jumped on each redraw: Flutter re-added the web view's
   container under its own top view each frame, so AppKit re-attached the web
   view and WebKit re-checked the hover from the window's corner (Mac probe,
   2026-11-24; macOS 26.6). The runner now skips re-adding a view to its own
   parent; the probe's hover moved without that and stayed with it. The
   committed code is in test build `bug-page-trace` (111e7ca); the user tried
   it on the Mac and said it "seems good" (2026-11-24; which cases they tried
   is not recorded). `hover_redraw_test.dart` has not run: run it, and re-run
   it after each Flutter upgrade.
6. The native workflow's Browser step loads a public shop page that sometimes answers slowly or with 429. Point it at a steadier page if that recurs.
7. Check on the Mac that opening a YouTube video updates the Browser address, tab title and Back button; only a faked web view tests this.
8. Check on the Mac that an app added to the live apps file appears in the app picker without Reconnect, and that a removed one leaves its open tab in place. Service and widget tests cover this, and the live backend applied a file edit without a restart; the Mac is unverified.
9. Restart Stable 0.0.19 on the Mac with a Browser tab and two or more app tabs open. Check that the last active tab shows first, the hidden tabs finish loading (none closed by the 20 s limit), and the chat history appears without waiting for them.
10. Check `browser.transcript` in WKWebView on the Mac with a short and an hour-long YouTube video, note how long each page takes against the 7-second limit, then ask about one through the real agent. Its page script passed against live YouTube only in headless Chromium with a Safari user agent. In the transcript pane, check on the Mac: opening it loads the hour-long transcript and scrolls smoothly; a drag selection survives clicking into the composer and reaches the question; moving to another video reloads it; a newer selection on the page replaces the transcript's; it stays hidden for other pages and narrow windows, and still loads in chat-only mode. For following, check that the highlight moves while the video plays, moves within a second of a seek, stays still while paused and during an ad, and still follows after moving to another video in the same tab; that scrolling the pane by hand or selecting there stops the scrolling while the highlight keeps moving; and that **Follow video** resumes it without losing the kept selection. An earlier draft of the play-time script, with an extra in-page navigation check, passed live in headless Chromium (play, seek, pause, in-page navigation; no ad appeared); the committed shorter script was not run live, and only a fake page tests the pane.
11. Try the split tab on the Mac with real WKWebViews: the drop highlight at
   each edge, three or more panes both ways, one click selecting a dimmed
   pane, pages keeping their state, dragging and double-clicking both kinds of
   divider (also over a page), switching between an app's tab and the split
   tab, and closing it, and that the split tab's outline and pane map read
   clearly in light and dark. Check that the selected page clicks and scrolls:
   nothing may be drawn over it (the 0.0.12 bug; its outline has been a
   2-pixel frame since 0.0.13). Per-pane address bars (in test build
   `pre-0-0-20`): check that selecting a pane resizes no page and narrow bars
   fit.
12. Check night mode on the Mac in Dark and Light, with macOS both light and
   dark: tabs, chat, Markdown replies, dialogs, menus and the empty Browser
   page. Also check that System follows a live macOS switch. Only widget tests
   and WSL screenshots cover it.
   Since 0.0.13 the transcript is an inset card with an accent border and
   muted timestamps. On the Mac, in both modes, check that it reads apart
   from the conversation and the playing paragraph is visible.
13. Check on the Mac that Analysis Web, registered as trusted, shows the
   confirm dialog of **Start analysis**, titled with the page's host, and that OK starts the analysis and
   Cancel does not. Page alert and confirm dialogs are tested only with a faked
   web view.
14. Try **Newest tab first** on the Mac with real pages open: clicking a tab,
   a new tab, an app opening and an agent opening a tab should each slide that
   tab smoothly to the left end while the others move right, also when the
   strip is scrolled. Only widget tests cover the order and the slide.
15. In Stable 0.0.14, sign in to figma.com with **Continue with
   Google**: the popup shows its host, closes itself and leaves Figma signed in.
   Close a tab, and the main window, with a popup open. New-tab links stay in the tab.
16. Next smoothness work: an unchanged poll is no longer decoded or redrawn
   (the user confirmed the idle hover stopped jumping), but a changed one still decodes the whole conversation on the UI thread.
   Decode large bodies off the UI isolate. Check with `npm run perf:ui` and
   `npm run perf:stress`.
17. On 2026-11-23 a hidden Figma tab held 1.1 GB. The user chose to unload
   Browser tabs after 30 silent minutes off screen (a model may choose later)
   and accepted that this loses unsent typed text and closes the tab's popups.
   Check on the Mac: a hidden page unloads, its process exits (`npm run
   perf:mem`), and it reloads at its address; tab hover cards show the page
   and its memory.
18. On the Mac, try YouTube fullscreen alone, in a split pane and embedded in
   another site, then leave macOS fullscreen by hand: the tab strip and chat
   must return. A video in a sign-in popup must fill only the popup; a popup
   opened with `noopener` has no opener, so it would still reach the tab's
   fullscreen. Restarting an embedded player within 5 s of leaving needs a
   page click. 0.0.15 filled the page, not YouTube's video (user report);
   0.0.16 has the fix, which Mac probes showed filling the window alone and
   each pane in a split.
19. Browser history (desktop only) is in Stable 0.0.16 and on the live
   backend. Check on the Mac: one titled entry per
   redirect or reload; instant, clickable suggestions; a restored tab's page
   is not counted again; one title per visit; inline fill-in (none after
   paste; Right+Enter opens real URL) and first-click select-all.
20. The PDF viewer and highlights passed `npm run test:mac --
   pdf_viewer_test.dart` on 2026-11-20. By hand on the Mac: drag-select in
   an arXiv PDF, click chat and send (the question must carry the
   selection), and open **Stored data**. Unverified: a password-protected
   PDF. Why 0.0.16 lost the selection is unknown; embedded PDFs still use
   that path. Rerun `highlight_clicks_test.dart` (not run since its last
   edits); in Stable 0.0.18, make the development guide's by-hand highlight checks and
   check drag smoothness, then mark the 2026-11-23 report solved.
21. Check **Updates** build times on Mac.
22. Form filling (`browser.form`, `browser.fill`; desktop only) has passed
   only Chromium and WSL tests. On the Mac, after a backend deploy, ask the
   real agent to fill a test form in WKWebView: the outlines show, the page
   scrolls to the first field, a React form takes the values and Relay does
   not submit. A fill aimed at a hidden tab, or made while the conversation
   is expanded, must be refused, and hidden fields must not be listed.

Browser isolation and PDF checks remain open. The Android device trial and phone work each await a separate request. See the [Windows test build](windows.md).

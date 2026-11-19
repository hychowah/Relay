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
  phone progress/Stop controls and chat-only mode. On desktop the agent can
  read a YouTube video's transcript from a Browser tab (`browser.transcript`),
  and a collapsible pane above the conversation shows it; selected transcript
  text becomes the question's selection. The pane highlights and scrolls to
  the paragraph being played until the user scrolls or selects there.
- Background update downloads with progress, verified caches and manual
  install/restart. Flutter has its own release channel.
- Every start restores the previous tabs and views, the draft, the chat panel
  state and the Mac window frame. Tabs are saved as they change.
- Split view (desktop only): dropping a tab on a page opens a split tab; the
  nearest edge places it, and panes nest both ways. Clicking an app's tab
  shows it full screen; closing the split tab keeps its apps open. Split tabs
  and divider positions are restored with the tabs. The clicked pane is the
  selected tab for context and agent navigation. The Flutter README has the
  details.
- Video fullscreen (desktop only): a page's fullscreen fills its split pane,
  or the whole screen when its tab shows alone (see the Flutter README).
- Night mode: Workspace menu → Appearance offers System, Light and Dark,
  saved per device. Relay's own screens follow it; app and website pages keep
  their own look, and the Mac title bar follows macOS.
- Newest tab first: a Workspace menu setting, off by default and saved per
  device. When on, a tab the user clicks or opens, or the agent opens, slides
  to the left end of the strip. Restoring, closing and split changes keep the
  order; reduced motion skips the slide.
- Development bug recording: actions, server exchanges, errors, tabs and a page
  screenshot are saved on the service as a report and read in the Bug reports
  viewer, where each report is marked open or solved, or deleted (see the root
  README).

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
`#/...` resource IDs in saved views, with a regression test; the full native
rerun then passed. The test renders frames itself when an SSH-launched window is
occluded.

The real-agent check also fixed failed-presentation retry: both clients
acknowledge the returned context on failure, so a corrected retry works while the
failed status stays. Backend and client regressions cover it.

The actual Dart installer passed on an isolated Mac bundle: verified background
download, signature/identity/version checks, preparation, process exit, replacement,
relaunch and preserved draft. It did not replace the installed user app.
The first sandboxed prototype's device, conversation and draft preferences were
copied to the current app on the Mac; that one-time copy has since been removed.

Before Stable 0.0.8 (no built-in server address), the native Mac workflow
passed against the deployed backend with one real DeepSeek request: Browser
read, Research reads and presentations, retained tabs and the conversation
lifecycle. It found a send during a poll idling up to a second; fixed, with a test.
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

Since 0.0.4, Reconnect retries unfinished tabs and clears the saved session
only on success, and the first snapshot interaction is no longer mistaken for
native initial context. Focused regressions cover both.

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

Stable 0.0.9 (build 9), published with that tool, added everyday restoration,
the updater's leftover removal, inline region capture, saved screenshots, bug
reports and draft conversations. The native Mac workflow was not rerun for it.

On 2026-11-19 the [UI smoothness suite](../../../flutter/README.md#measure-performance)
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

Stable 0.0.10 to 0.0.14 were published from `main` on 2026-11-19. 0.0.10
carries the Browser address fix for in-page navigation, the app list refresh,
tab restore, the transcript pane and transcript reading. 0.0.11 adds the two-tab
split view and the transcript following the playing video. 0.0.12 adds night
mode, page alert and confirm dialogs, the split divider and exit button, and
the capture animation. 0.0.13 fixes the split view taking no clicks, shows the
transcript as a bordered card, and lets bug reports be marked solved or deleted.
0.0.14 (build 14) adds Browser popup windows, the free-form split tab, inline
delete confirmation and Newest tab first. Analysis, 66 Flutter tests and 86
backend tests passed on its commit; the feed serves it with its commit and the
download matches its hash.
The backend at `main` was deployed with 0.0.10 and again with 0.0.13: it offers
`browser.transcript`, applies an edit to the live apps file without a restart,
and serves the bug report status routes. The native Mac workflow was not rerun,
and none of these builds has been reviewed on the Mac.

Browser popups (desktop only): webview_flutter_wkwebview 3.27.2 loaded a
page's new window into its opener, which broke sign-in popups. A forwarding UI
delegate in the Mac runner now opens sized new windows as child popups; others
load in the tab. `npm run test:mac -- popup_windows_test.dart` checks this with
real WKWebViews.
`video_fullscreen_test.dart` checks video fullscreen with a real WKWebView.

## Next

1. Install Stable 0.0.14 on the Mac. Check that tabs, the chat panel and the
   window come back after a restart, and that its first start removes the
   update folders beside the app and the older downloads.
2. Republishing a test build's name leaves its earlier ZIP in the release
   folder on WSL. Remove it at publish time if that folder grows.
3. Review Stable 0.0.14 on the Mac: the panel, tab and menu transitions and text selection. Compare any reported hitch with a fresh `npm run perf:ui`. The suite's longest waits, on tab switches, are candidates for a smoothness fix. The Mac PDF probe recovered selected text after focus moved to chat. A real Claude image reply, a Research PDF on the device and Stop during a presentation are unverified.
4. Region capture selecting inside the active tab, and sent screenshots shown again in reopened chats, are in Stable since 0.0.9. Widget and service tests cover the crop, Escape, chat staying docked, the saved image and its Trash lifecycle; dragging over a live WKWebView and loading a saved screenshot on the Mac are unverified. The capture animation is not in Stable yet: on the Mac, check that the flash and the flight to the composer run smoothly over a real page, and that the thumbnail takes over without a jump.
5. Try the toolbar record button and **Bug reports**, both in Stable since 0.0.9, on the Mac. Source tests cover recording,
   saving, viewing, marking solved and deleting; native screenshots and the live service's report folder are unverified. Marking solved and deleting are in Stable 0.0.13 and served by the live backend; try them on the Mac.
6. The native workflow's Browser step loads a public shop page that sometimes answers slowly or with 429. Point it at a steadier page if that recurs.
7. Check on the Mac that opening a YouTube video updates the Browser address, tab title and Back button; only a faked web view tests this.
8. Check on the Mac that an app added to the live apps file appears in the app picker without Reconnect, and that a removed one leaves its open tab in place. Service and widget tests cover this, and the live backend applied a file edit without a restart; the Mac is unverified.
9. Restart Stable 0.0.14 on the Mac with a Browser tab and two or more app tabs open. Check that the last active tab shows first, the hidden tabs finish loading (none closed by the 20 s limit), and the chat history appears without waiting for them.
10. Check `browser.transcript` in WKWebView on the Mac with a short and an hour-long YouTube video, note how long each page takes against the 7-second limit, then ask about one through the real agent. Its page script passed against live YouTube only in headless Chromium with a Safari user agent. In the transcript pane, check on the Mac: opening it loads the hour-long transcript and scrolls smoothly; a drag selection survives clicking into the composer and reaches the question; moving to another video reloads it; a newer selection on the page replaces the transcript's; it stays hidden for other pages and narrow windows, and still loads in chat-only mode. For following, check that the highlight moves while the video plays, moves within a second of a seek, stays still while paused and during an ad, and still follows after moving to another video in the same tab; that scrolling the pane by hand or selecting there stops the scrolling while the highlight keeps moving; and that **Follow video** resumes it without losing the kept selection. An earlier draft of the play-time script, with an extra in-page navigation check, passed live in headless Chromium (play, seek, pause, in-page navigation; no ad appeared); the committed shorter script was not run live, and only a fake page tests the pane.
11. Try the split tab on the Mac with real WKWebViews: the drop highlight at
   each edge, three or more panes both ways, one click selecting a dimmed
   pane, pages keeping their state, dragging and double-clicking both kinds of
   divider (also over a page), switching between an app's tab and the split
   tab, and closing it, and that the split tab's outline and pane map read
   clearly in light and dark. Check that the selected page clicks and scrolls:
   nothing may be drawn over it (the 0.0.12 bug; its outline has been a
   2-pixel frame since 0.0.13). In Stable 0.0.14; 66 Flutter tests pass on
   WSL with fake pages. Splits saved by 0.0.13 are not restored.
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
16. Next smoothness work: the one-second poll decodes and rebuilds the whole
   conversation on the UI thread. In `Workspace._refresh`, skip the decode and
   `changed()` when the snapshot body is unchanged, and decode large bodies off
   the UI isolate. Check with `npm run perf:ui` and `npm run perf:stress`.
17. One page of the installed app reached 1.5 GB and went away after a restart.
   If a page grows like that again, find it by closing tabs one at a time while
   running `npm run perf:mem`. If it is an app page, the fix belongs in that
   app's repository. If it is an outside site, whether Relay unloads hidden tabs
   under memory pressure is a product decision for the user.
18. On the Mac, try YouTube fullscreen alone, in a split pane and embedded in
   another site, then leave macOS fullscreen by hand: the tab strip and chat
   must return. Only a fixture page ran on the Mac.

Browser isolation and PDF checks remain open. The Android device trial, Windows Flutter build and phone work each await a separate request.

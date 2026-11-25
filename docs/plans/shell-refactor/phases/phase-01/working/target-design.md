# Shell refactor target design

From an independent /strategic-design-plan planner, checked against the code
and approved by the user with the changes the master plan records (slice 1
split in two, no `useWindow` helper, a different Mac check). Slice briefs
carry the parts they need.

## Hidden coupling

1. The chat panel unmounts when chat closes (`_panels` mounts it only while
   `value > 0`). State in a chat widget's own `State` would reset on close:
   draft, transcript open and selection, attachment, messages scroll.
2. The transcript selection is cleared during build, every frame, even with
   chat closed: `_chat(desktop)` is built eagerly as the
   `TweenAnimationBuilder` child, so `_transcript` runs, and it must run
   before `_composer` reads the selection.
3. The address text follows the active page URL in the shell's build,
   including app tabs and the new tab page. The controller outlives the bar,
   so an unsent edit survives fullscreen (the bar is removed then). A
   bar-owned `State` would lose it; syncing only while the bar is built would
   keep an edit across Browser, app, Browser. Both change behavior.
4. Dragging a split divider redraws the whole shell, so the tab strip's split
   map (`workspace_tabs.dart`) follows live; the workspace hears only the
   drag's end (`w.changed()` uploads tabs).
5. Library-private items several regions use: `_barHeight`,
   `_addressDecoration`, `_Suggestion`, `_typedText`.
6. Shared fields: `chatOpen`, `chatOnly`, `chatWidth` are written at about 12
   sites in 6 regions; `capture`, `selecting`, `flight`, `captureSlot` span
   the composer, page stack and `_changed` (a tab change cancels a
   selection); `draft` and `saveTimer` span the composer, send, conversation
   choice, update install and dispose.
7. Menu actions go through `_menu(String)` from page overlays (`servers`),
   the composer (`provider`), chat options (`forward`) and the toolbar
   (`record`). The switch has no default. Each name is written into bug
   recordings (`menu`, `{'item': …}`), so names are observable data.
8. `mounted` checks follow the shell's lifetime (`_send`, `_choose`,
   `_capture`, `_fillIn`, `_newConversation`); after the snapshot `await`,
   `_capture` reads `MediaQuery` and the overlay through the shell's context.
9. Tests reach internals: keys (`conversation-panel`, `address-bar`,
   `bar-<id>`, `pane-<id>`, `new-`/`report-`/`error-`/`loading-<id>`,
   `split-divider-<i>`, `drop-<side>`, `ValueKey(tab.id)`,
   `ValueKey(image)`), tooltips and hint texts (the Mac
   `ui_performance_test` uses the composer hint), tree shape (first `Stack`
   ancestor of a page slot, four α.45 `ColoredBox` outlines,
   `Opacity`→`Image`, a `Material` ancestor of a chip, `DecoratedBox` in the
   transcript), and element identity: native page views are never recreated.
10. `sources_test.dart` imports `FakePage` from `workspace_test.dart`.
    `conversations_test.dart` and `integration_test/` (`fixture.dart`,
    `workflow_test.dart`, `ui_performance_test.dart`,
    `memory_stress_test.dart`) import `main.dart` for `RelayApp` and
    `RelayShell`, which stay there with unchanged constructors.
11. The shell's build writes `w.splitShown` and `w.pageShown`; form-fill
    refusal depends on them.
12. `Platform.isMacOS` gates the VPN switch, hover cards and "Show tab
    memory", which WSL cannot render.
13. The 900 breakpoint appears 10 times, measured two ways (`MediaQuery`
    width or `LayoutBuilder` maxWidth). Keep each site's measure.
14. UI errors reach the banner by `w.error = …; w.changed()` (5 sites here, 2
    in `conversation_view.dart`).

## Options and choice

- A. Thin region widgets; the shell keeps all state. `ChatPanels` would take
  about 24 values and callbacks and `PageStack` about 15. Every feature would
  still edit shell fields, a parameter list and a call site.
- B. State owners plus region views (chosen). State that crosses regions or
  must outlive a widget gets one owner object the shell creates; regions take
  the workspace and the owners they read. Common case:
  `ChatPanel(workspace, desktop, input, layout, capture, actions,
  onConversationChosen, onNewConversation)`.
- C. Each region owns its state in its own `State`. Rejected: coupling 1, 2,
  3 and 6 show it changes behavior.

B has the simplest common-case interfaces, gives each cross-region rule one
home, and is the only option that keeps coupling 1–4 exact. The rule, as the
`RelayShell` doc comment: "State that must outlive a region's widget, or that
several regions read, is an object the shell owns and hands down. The shell
pushes the selected tab into those objects. Regions never pass their own
`BuildContext` to them."

## Modules

| File | Public interface | Owns |
|---|---|---|
| `address_bar.dart` | `AddressInput(workspace, {history})` with `follow(WorkspaceTab? tab)`, `dispose()`, `controller`, `focus` and the rule methods `suggestionsFor`, `picked`, `escape`, `pointerDown`, `tapped`, `submitted`, `go`, `edited`; `BrowserBar(workspace, tab, input)`, `static const height = 46.0`; `inlineCompletion(typed, url)` | Fill-in, suggestions, Esc and paste rules, Go target, `browserTyped`; VPN switch (`/// Desktop only (macOS).`), PDF zoom and Highlight (`/// Desktop only.`) |
| `new_tab_page.dart` | `NewTabPage`, unchanged | App search, other devices' tabs |
| `page_stack.dart` | `PageStack(workspace, desktop, address, capture, onChoose, onServers, onSplit, onResized)` | Keyed slots, split geometry, frames, tints, overlays, dividers, drop zones and hover |
| `chat_dock.dart` | `ChatLayout(open, width, saveOpen, saveWidth)` with `open`, `only`, `width`, `transcriptOpen`, `showPage({closeChat})`, `toggle()`, `toggleOnly()`, `chatOnly()`, `saveWidth()`; `ChatDock(layout, workspace, size, screen, page, panel)` | Dock, phone sheet, compact bar, expand animation, width clamp |
| `area_capture.dart` | `AreaCapture(shellContext, workspace, layout)` with `start()`, `finish(region?)`, `follow(activeTab)`, `remove()`, `sent(attachment)`, `attachment`, `selecting`, `busy`, `flying`, `slot` | Snapshot, area picking, flight overlay, the phone sheet stepping aside |
| `workspace_menu.dart` | `enum WorkspaceAction` (names are the recorded names); `ShellActions(shellContext, workspace, updates, layout, saveDraftNow, onConversationChosen)` with `run(action)`; `WorkspaceMenu(actions, workspace, updates, themeMode, onThemeMode, tabMemory)`; `actionItem(...)` for chat's Forward | Every dialog, recording and saving a bug report with its guard, update install, banner on error |
| `chat_panel.dart` | `ChatInput(workspace, layout, capture, draft, save)` with `draft`, `messages`, `follow(tab, {desktop})`, `transcriptPane`, `transcriptSelection`, `send()`, `clear()`, `flush()`, `refreshSelection()`; `ChatPanel(...)`, stateless | Header, transcript card, messages, status, composer, effort menu |
| `main.dart` (kept, about 570 lines) | `main()`, `RelayApp`, `RelayShell`, constructors unchanged | Creates and disposes the owners; listeners, lifecycle, fullscreen, banner, toolbar, `_choose`, `_conversationChosen`, `_newConversation`; calls `address.follow(w.active)` in build, `chat.follow(...)` in the `LayoutBuilder`, `capture.follow(active)` in `_changed` |
| `workspace_style.dart` (edit) | `const wideWorkspace = 900.0` | The breakpoint value only |

Interface comments are deliverables. Drafts:

- `AddressInput`: "The selected Browser tab's address as the user edits it.
  It outlives the bar, which is rebuilt as the selected tab, its pane or
  fullscreen changes, so an unsent edit stays until the selected page's
  address changes. Call [follow] with that address on every shell build."
- `PageStack`: "Every tab's page in one keyed slot of one stack, so showing it
  alone, in a split pane or hidden only moves it and never recreates its
  native view. [onResized] runs on each step of a divider drag so the tab
  strip's map follows; the workspace hears only the drag's end."
- `ChatLayout`: "Where chat is: open, chat only, its width and whether the
  transcript is open. It saves `open` when it differs from the last saved
  value, and the width when a drag ends."
- `ChatInput`: "What the next message is made of, kept while the panel is
  closed (closing unmounts it): the draft, saved 300 ms after each change and
  on dispose; the transcript selection, dropped by [follow] once its pane
  hides or the page has a newer selection; the messages' scroll. Does nothing
  once disposed."
- `AreaCapture`: "An area of the selected app tab on its way to the next
  message. On a phone the chat sheet steps aside while the user picks."
- `WorkspaceAction`: "Bug recordings name each use by [name] (except
  `record`), so names never change."

## Error model

- Draft emptiness and `busy` are checked in `ChatInput.send`; the Enter
  handler keeps today's `busy` check. Address text is left to
  `workspace.navigate`. Area-capture preconditions are checked in
  `AreaCapture.start`.
- One catch per entry point writes the banner: `ShellActions.run`,
  `AreaCapture.start`, the effort menu, `_newConversation`. `_choose` and
  `send` keep swallowing errors as now. Nothing below re-catches.
- Owners take the shell's `BuildContext` and check `context.mounted` (or
  their own disposed flag) exactly where the shell checked `mounted`, and
  never notify after dispose.
- Bugs (`updates!`, `tab!`) crash as today.

Constraints that keep a patch: `workspace.dart` is out of scope, so
`w.error = …; w.changed()` stays repeated and `w.splitShown`/`w.pageShown`
stay written from the shell's build; behavior must stay the same, so
`RelayApp` keeps passing its 12 parameters to `RelayShell`.

## Test homes

Slice 1a moves these 26 tests unchanged, by name (25 widget tests and the
`inlineCompletion` unit test):

- `new_tab_page_test.dart`: "another device's tabs…", "cold start publishes
  the app picker…", "the app picker shows current registrations…", "desktop
  and phone picker…"
- `address_bar_test.dart`: "a Browser tab highlights…", "address bar asks the
  server…", "inline completion…", "address bar selects all…"
- `page_stack_test.dart`: "dragging tabs splits…", "split dividers resize…",
  "an app tab that cannot load…"
- `chat_dock_test.dart`: "chat can reverse mid-slide…", "chat reopens
  closed…"
- `chat_panel_test.dart`: "forwarded chat…", "compact chat keeps context…",
  both YouTube transcript tests
- `area_capture_test.dart`: "screenshot selection…"
- `workspace_menu_test.dart`: "a bug report pictures the whole window…", "a
  dot marks the workspace menu…", "appearance follows the system…"
- `shell_test.dart`: "a fullscreen video…", "a click that moves a few
  pixels…", the three newest-tab-first strip tests
- The five workspace widget tests (the four about unloaded tabs and "unready
  retained pages…") and every other `test()` stay in `workspace_test.dart`.

## Safety net (slice 1b)

Through `RelayApp` only, with existing tooltips, texts and keys; no private
state, no new product keys:

- Menu: each item opens its dialog; Reconnect restarts; while recording, each
  use records `menu` with its item and the record button records none;
  Forward is enabled only with a conversation, not busy, and bots; the bug
  report's `client` keys and values; an action error shows the banner and
  Dismiss clears it; the banner is hidden in fullscreen.
- Composer: effort menu (Connection default, check mark, error to banner);
  the model button opens Provider settings; Send and Stop tooltips; History
  and New conversation disabled while sending; New conversation clears the
  draft and attachment and opens chat; the draft is saved 300 ms after typing
  and on dispose; draft, transcript open state and transcript selection
  survive closing and reopening chat; a newer page selection drops the
  transcript selection even while chat is closed.
- Dock: the phone's compact bar labels, Stop, tap opens; the divider saves the
  width once at drag end; a presentation on a phone closes chat.
- Address bar: Back and Forward enabled state; a pane under 480 px hides Go
  and zoom; Highlight tooltip states; an unsent edit survives fullscreen and
  is reset by a page URL change, Browser→app→Browser included; Go with
  history records the address as typed.
- Page stack: loading spinner; error with App servers for app tabs only;
  saved report; dragging a divider moves the split map live.
- New tab page: search filters; Enter opens the first match; "No matching
  apps."; devices hidden while searching; choosing on a phone closes chat.
- Shell and toolbar: the "Relay" wordmark only at 600 px or wider; Toggle
  chat records open and close; New tab on a phone closes chat; resume opens
  the conversation last opened elsewhere.
- Area capture: the sheet steps aside and returns on a phone; a tab switch
  cancels the selection; the attachment survives closing chat and is cleared
  when a conversation is chosen.

## Deletes

Each removed in the slice that replaces it:

- `main.dart` address members: `address`, `addressFocus`, `pickedSuggestion`,
  `addressWasFocused`, `fill`, `noFill`, `escaped`, `asked`, `lastPageUrl`,
  `_browserBar`, `_barControls`, `_addressShown`, `_vpnSwitch`,
  `_readingControls`, `_addressTarget`, `_go`, `_addressField`, `_filled`,
  `_fillIn`, `_edited`.
- Page members: `_pages`, `_divider`, `dropping`.
- Chat members: `_panels`, `_compactChat`, `_chat`, `_transcript`,
  `_composer`, `_send`, `draft`, `saveTimer`, `_save`, `messagesScroll`,
  `transcriptOpen`, `transcriptSelection`, `chatOpen`, `savedChatOpen`,
  `chatOnly`, `chatWidth`.
- Capture members: `capture`, `capturing`, `selecting`, `captureSlot`,
  `flight`, `_capture`, `_finishCapture`, `_land`.
- Menu members: `_recordBug`, `reportingBug`, `_menu(String)` and every
  action string, `_menuItem`.
- Top level: `NewTabPage`/`_NewTabPageState`, `inlineCompletion`,
  `_barHeight`, `_addressDecoration`, `_Suggestion`, `_typedText`; the order
  comment "this runs before the composer below reads it"; unused imports; the
  900 literals.
- `workspace_test.dart`: `FakePage`, `Fixture`, `apps`, `deskReport`, the 26
  moved shell tests and the imports only they used. `sources_test.dart`: its
  import of `workspace_test.dart`.
- `tools/structure.json`: the `main.dart` entry (slice 8); the
  `workspace_test.dart` entry lowered (slice 1a). The map's `main.dart` Known
  debt row (slice 8).

## Unknowns

- U1. Does the extra widget layer above the page stack re-parent native views
  on the Mac? WSL: the element-identity test. Live: the close-out Mac check.
- U2. Does `use_build_context_synchronously` flag the stored shell context?
  Slice 5 runs analyze on its first draft; if flagged, add `context.mounted`
  exactly where the shell had `mounted`.
- U3. Does saving `open` when it changes match today's once-per-build save?
  Before slice 4, audit every `chatOpen` write in the slice's ignored `tmp/`;
  report it in the hand-back and delete it.
- U4. macOS-only controls cannot render on WSL: `--color-moved` must show
  them moved verbatim in slices 2 and 6; the Mac check confirms.
- U5. Splitting the test file gives each file its own isolate, so statics such
  as `FakePage.navigateError` reset per file. Slice 1a compares per-test
  results from `flutter test --reporter json` before and after, in ignored
  `tmp/`.
- U6. Does the fixture's mock server answer each menu dialog's endpoints?
  Slice 1b adds missing routes to `support/fixture.dart` only.
- U7. Can the update-install closure be driven on WSL? Slice 1b reads
  `AppUpdates.install`; if it fakes without product changes, pin "draft and
  session saved before restart"; otherwise slice 6 moves it verbatim.
- U8. Is the suspected unloaded-tab address bug real? Yes: slice 1b confirmed
  it, and slice 1c fixed it.

## Worker hand-back

Beyond /deliver-change's format: the new module's interface comment as
committed; `main.dart` lines before and after and the `structure.json` diff;
`flutter analyze`; `flutter test` totals against the baseline; the test diff
limited to import lines; `git diff --color-moved=dimmed-zebra
--color-moved-ws=allow-indentation-change main -- flutter/lib` with every
edit that is not a pure move listed; bugs noticed but not fixed; whether a Mac
run is needed.

## Worker rules

Implement the plan's interfaces and nothing else. A part the plan does not
name is complexity its design did not account for.

- Remove everything on the plan's **Deletes** list in the same change. Fix
  the imports, links and docs that pointed at it.
- Add no option, layer, mode, compatibility path, fallback or helper that the
  plan does not name. When one seems necessary, ask the requester before
  adding it.
- Check each input once, at the boundary the plan's error model names. Code
  inside that boundary trusts it.
- Put probes and experiments where the plan says, outside the product tree.
- Tests: one fast behavior test for each new or changed behavior, through the
  public interface. Leave private internals untested and slow tests out of
  the default run. Delete the tests of code that this change deletes.
- Docs: update the standing docs that this change makes wrong. File process
  notes only where the repository's records policy says.

In the hand-back (deliver-change's format), list under the deviations
**every addition that is not in the plan and the reason for it**, and
anything on the Deletes list that you could not remove and why.

# Flutter shell refactor
Status: complete

## Outcome

`flutter/lib/main.dart` held the whole shell: one class, about 35 pieces of
screen state, every region of the window. The user approved the refactor on
2026-11-25. The shell is now one module per region, behavior unchanged apart
from the one fix below:

- `address_bar.dart`, `new_tab_page.dart`, `chat_dock.dart`,
  `area_capture.dart`, `workspace_menu.dart`, `page_stack.dart` and
  `chat_panel.dart`; the [architecture map](../../architecture.md) names them.
- `main.dart` went from 2,429 lines (its recorded size at `3e71256`) to 551,
  and its `tools/structure.json` entry and Known debt row are gone.
- The shell tests sit beside their modules, and the shared fakes are in
  `flutter/test/support/`. `workspace_test.dart` holds only workspace tests,
  at 1,062 lines (3,084 before).
- The suite grew from 110 to 168 tests: 58 new tests pin shell rules that no
  test covered.

## Slices

Each slice was built on its own branch and merged by the orchestrator, from
`3e71256` to `545dad6`.

| Slice | Commits |
|---|---|
| 1a Test homes | `5195d57`, `506d004`, `fff4b08` |
| 1b Safety-net tests | `dc41670` to `78dfb7c` |
| 1c Unloaded Browser tab's address | `50b2a72` to `abb976d` |
| 2 `address_bar.dart` (pilot) | `cecbaa6` to `e4bbed2` |
| 3 `new_tab_page.dart` | `14f5e08`, `10e5709` |
| 4 `chat_dock.dart`, `wideWorkspace` | `f56ea9d` to `19c599d` |
| 5 `area_capture.dart` | `4502852` to `31dc6e3` |
| 6 `workspace_menu.dart` | `7092fd5` to `7af0a55` |
| 7 `page_stack.dart` | `06a1dff` to `d1c0200` |
| 8 `chat_panel.dart` | `7e592e7` to `e4107dd`, `545dad6` (`88769c8` in between is the WSL test memory cap, not shell work) |

## Done measures

WSL evidence, on `545dad6`:

1. `main.dart` holds startup, `RelayApp`, `RelayShell` with the owners and
   listeners, fullscreen, the banner, the toolbar and three callbacks:
   551 lines, no `structure.json` entry. Met.
2. Each shell state field has one owner; no view reads an owner's private
   fields (grep on `545dad6`); no action is dispatched by string, as
   `WorkspaceAction` replaced them. Met.
3. The 168 tests all pass on `545dad6`, with names identical to the baseline
   (checked by the coordinator). Each slice changed test
   files only in import lines, apart from the new pinning tests. Met.
4. `workspace_test.dart` is at 1,062 lines; the fakes are in
   `flutter/test/support/`; no test imports another test file (grep). Met.
5. `flutter analyze` says "No issues found!". Met.
6. Desktop-only members carry the map's markers (for example the VPN switch
   and Show tab memory). Met.
7. The map names each module; the `main.dart` Known debt row is gone and the
   `workspace_test.dart` row shows 1,062. Met.
   `check_structure.py` and `check_records.py` pass.

Done measure 8, the Mac check, kept apart from the WSL evidence. It ran on
2026-11-26 on the MacBook Neo from main `545dad6`:

- Real-mouse tests, run by the orchestrator session at the user's request
  from a check copy of main. `highlight_clicks_test.dart` passed in one run.
  `hover_redraw_test.dart` failed twice at line 78, "the page did not load",
  before any hovering. The refactor did not cause it: the test uses no shell
  code (it imports `page_surface.dart`, `web_page.dart` and
  `window_capture.dart` only), those files, `flutter/macos`,
  `flutter/integration_test` and `package.json` are unchanged between
  `3e71256~1` and `545dad6`, and the Flutter plan records the test as never
  run before. The likely cause, unconfirmed, is line 77 comparing `'$count'`
  with `'40'` when WKWebView probably returns 40.0. Mac time: three runs,
  about 4 minutes; nothing left on the Mac.
- Hand check on the test build `shell-closeout` (main `545dad6`): VPN switch;
  tab hover card; Show tab memory; address fill-in; chat open and close
  (page not reloaded, draft kept); area capture; split view (drag a tab to
  split, drag the divider, neither page reloads). The user said, "i checked
  shell-closeout, all pass". That overall statement is the record, not seven
  separate results. The split view and chat steps are the live evidence for
  unknown U1: the extra widget layer does not recreate native page views.

## Lasting decisions

- Owner, view and `follow`: state that must outlive a region's widget, or
  that several regions read, is an object the shell owns and hands down. The
  shell pushes the selected tab into it with `follow`. Regions never pass
  their own `BuildContext` to it. The map's "The Flutter shell" section
  keeps the rule.
- The user's one behavior change, slice 1c: an unloaded Browser tab (for
  example after a failed reload) shows its known address, in an unselected
  split pane too, and Go from it is recorded as typed.
- Accepted redraw difference B1, slice 8: the chat panel's reduce-motion and
  pixel-ratio reads now redraw only the panel. A stale transcript selection
  after a silent page-selection change can last until the next shell redraw.
  It is rare and corrects itself.
- Settled with the user: slice 1 split into 1a and 1b; no `useWindow` test
  helper for now; a self-contained Mac check instead of `workflow_test.dart`,
  which runs against the deployment's real records; slices 3 to 8 ran
  without further pauses.

## What is left

No unfinished target remains. The hover test is open: whether a redraw keeps
a page's hover under the mouse is still unverified on the Mac. Making
`hover_redraw_test.dart` pass is a separate change outside this refactor.

Not now:

- `Workspace.showError(Object)` and screen facts set on the workspace by one
  setter: for the workspace.dart refactor.
- A settings object replacing `RelayApp`'s parameters.
- A `useWindow(tester, size)` test helper for the 20 repeated window setups.
- `AddressInput.edited` could return a plain flag instead of signalling the
  kept fill-in through object identity.
- A public `Suggestion` type name instead of the spelled-out record type in
  `AddressInput`'s public methods.
- Merge `shell_actions_test.dart`'s `_CheckedUpdates` with
  `workspace_menu_test.dart`'s `_RestartingUpdates`.
- Let `TabMemory` notify when switched, so `WorkspaceMenu` can be stateless.
- An `actions.item(...)` method in place of the free `actionItem` function.

# Flutter shell refactor
Status: active

## Goal

`flutter/lib/main.dart` holds the whole shell: one class with about 35
pieces of screen state that draws every region of the window. Its tests share
`flutter/test/workspace_test.dart` with the workspace tests and the shared
fakes. Nearly every client feature edits both files. This refactor splits the
shell into a module per region, each piece of shared screen state with one
owner, and the tests beside the modules they test. Behavior stays exactly the
same. The user approved this brief on 2026-11-25.

The [target design](phases/phase-01/working/target-design.md) holds the
modules, interfaces, hidden coupling, error model, Deletes and unknowns. In
the same folder, `baseline.md` (slice 1a writes it) defines "behavior
unchanged", and `playbook.md` (slice 2 writes it) holds the method every
later slice repeats.

## Done measures

1. `main.dart` holds only startup, `RelayApp`, `RelayShell` with the state
   owners and listeners, fullscreen, the banner, the toolbar and three
   callbacks, about 570 lines. Its `tools/structure.json` entry is gone.
2. Each shell state field has one owner, no module reads another module's
   internals, and no menu action is dispatched by string.
3. Every baseline test passes after every slice, unmodified apart from import
   lines, or replaced by a named test at the new interface.
4. `workspace_test.dart` holds only workspace tests, at its lowered recorded
   size; shared fakes are in `flutter/test/support/`; no test imports another
   test file.
5. `flutter analyze` is clean, `integration_test/` included.
6. Desktop-only members are marked as the map says.
7. The [architecture map](../../architecture.md) names each new module; the
   `main.dart` Known debt row is gone and the `workspace_test.dart` row shows
   its lowered size.
8. One Mac check at close-out is recorded, separate from the WSL evidence.

## Slices

Each slice is built by a /deliver-change worker on its own branch from `main`
and merged by the orchestrator. Every slice after 1a edits `main.dart` or the
new test files, so they run one at a time. Each production slice builds the
new module beside the old code, moves the callers, deletes the old code, runs
`python3 tools/check_structure.py --update`, updates the `main.dart` Known
debt line count, and marks itself done here. A slice that fails before merging
is discarded; a merged one is reverted by a new slice.

| # | Slice | Status |
|---|---|---|
| 1a | Test homes: fakes and shell tests moved unchanged | done |
| 1b | Safety net: tests for the untested shell behavior | to do |
| 2 | Pilot: `address_bar.dart` | to do |
| 3 | `new_tab_page.dart` | to do |
| 4 | `chat_dock.dart` and `wideWorkspace` | to do |
| 5 | `area_capture.dart` | to do |
| 6 | `workspace_menu.dart` | to do |
| 7 | `page_stack.dart` | to do |
| 8 | `chat_panel.dart` | to do |
| 9 | Close-out: Mac check, then an upkeep slice | to do |

**1a. Test homes (tests only).** Move `FakePage` to
`flutter/test/support/fake_page.dart` and `Fixture`, `apps` and `deskReport`
to `support/fixture.dart`; point `sources_test.dart` there. Move the 26 shell
tests unchanged into the eight test files the target design lists. Lower the
`workspace_test.dart` size and its map row's line count. Write the baseline
from `flutter test --reporter json` output. Exit: the whole suite's 110 test
names pass before and after; each new file passes alone; `git diff --color-moved` shows
only moves and import lines. Rollback: revert; tests only.

**1b. Safety net (tests only).** Add the target design's safety-net tests
through `RelayApp`, using existing tooltips, texts and keys; no product
change. Run probes U6–U8. Break one pinned behavior on purpose, see a test
fail, revert, and report it under Checks. Add the new test names to the
baseline. Exit: suite passes; baseline updated from the runner's output.
Rollback: revert; tests only.

**2. Pilot, `address_bar.dart`.** `AddressInput`, `BrowserBar`,
`inlineCompletion`; the shell's build calls `address.follow(url)`. Writes the
playbook. Exit: baseline passes unmodified; `main.dart` near 2,050 lines.

**3. `new_tab_page.dart`.** A verbatim move. Exit: baseline passes; near
1,765 lines.

**4. `chat_dock.dart`.** `ChatLayout` and `ChatDock`; `wideWorkspace` in
`workspace_style.dart` replaces the 900 literals, each site keeping its own
measure. Probe U3 first. Exit: baseline passes; near 1,620 lines.

**5. `area_capture.dart`.** `AreaCapture`; `_changed` calls
`capture.follow(active)`. Probe U2. Exit: baseline passes; near 1,530 lines.

**6. `workspace_menu.dart`.** `WorkspaceAction`, `ShellActions`,
`WorkspaceMenu`; action names stay the recorded names. Exit: baseline passes;
no action strings left; near 1,340 lines.

**7. `page_stack.dart`.** `PageStack`. Exit: the element-identity and
nothing-over-the-page tests pass unmodified; near 1,050 lines.

**8. `chat_panel.dart`.** `ChatInput` and `ChatPanel`; the shell calls
`chat.follow(...)` before building the dock. Exit: done measures 1–7; the
`main.dart` structure entry and Known debt row removed.

**9. Close-out.** After slice 8, one Mac check of about 20 minutes, with the
user told first: `npm run test:mac -- hover_redraw_test.dart` and
`highlight_clicks_test.dart` (real mouse events, so the MacBook Neo), and a
hand check on a preview build of the VPN switch, tab hover card, Show tab
memory, address fill-in, chat open and close, and area capture.
`workflow_test.dart` is not used: it runs against the deployment's real
records. Then an upkeep slice with the `Upkeep: structure` trailer removes the
map's window note, records what is left, and closes these records.

## Structure window

These files belong to this refactor until the slice named merges. Other
sessions do not edit them before then; a shell feature waits, or goes into a
module that already exists.

- `flutter/lib/main.dart`, the new `flutter/lib/` modules, and
  `flutter/test/support/`: until slice 8.
- The new shell test files (`address_bar_test.dart`, `new_tab_page_test.dart`,
  `page_stack_test.dart`, `chat_dock_test.dart`, `chat_panel_test.dart`,
  `area_capture_test.dart`, `workspace_menu_test.dart`, `shell_test.dart`):
  until slice 8.
- `flutter/lib/workspace_style.dart`: until slice 4.
- The `main.dart` entry of `tools/structure.json` and its row of the map's
  Known debt: until slice 8.

## Pause points

Stop and check with the user after slice 1b merges, after the pilot (the user
looks at its diff and the playbook), and after two failed slices in a row,
which means a prerequisite is missing and goes back to the planner.

## Project limits

- Behavior identical: after 1b, a slice edits tests only in import lines.
  A bug found is noted in the hand-back and moved as it is.
- No Mac run in a slice unless WSL cannot prove it; then one run, said first.
- Recorded sizes only go down. Workers use worktrees named for the slice,
  reset to local `main`, and never merge, push or deploy.
- Client code only: no backend deploy is needed.

## Not now

- `Workspace.showError(Object)` and screen facts set on the workspace by one
  setter: for the workspace.dart refactor.
- A settings object replacing `RelayApp`'s parameters.
- A `useWindow(tester, size)` test helper for the 20 repeated window setups.
- The suspected address bug: an active Browser tab that is not loaded shows
  an empty address, and a Go from it is not recorded as typed. Slice 1b checks
  it; a fix slice after slice 8 needs the user's yes.

## Next

Slice 1a is done and awaits the orchestrator's merge. Next is slice 1b, the
safety-net tests; it adds their names to the baseline.

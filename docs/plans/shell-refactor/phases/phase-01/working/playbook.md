# Shell refactor playbook

How each production slice (3 to 8) moves one region out of
`flutter/lib/main.dart`. Slice 2, the pilot, moved the address bar into
`flutter/lib/address_bar.dart` this way. Read the slice's row in the
[target design](target-design.md) and the
[master plan](../../../master-plan.md) first. The refactor rules in the slice
brief come before this page.

## The pattern: owner object, view, `follow`

State that must outlive a region's widget, or that several regions read,
goes into an owner object that the shell creates and disposes. The region's
widget is a view: it gets the workspace, the selected tab or other inputs,
and the owner objects it reads, and it keeps no state of its own. The shell
pushes the selected tab into each owner from its build.

The pilot in practice:

- **Owner object.** `AddressInput` is a plain Dart class, not a widget and
  not a `ChangeNotifier`: the old code changed these fields without
  `setState`, so nothing needs to listen. It holds the text controller, the
  focus node and the fill-in, suggestion, Esc and paste state. Its public
  interface is the constructor (whose `workspace` and `history` stay
  readable), `follow`, `dispose`, the `controller` and `focus` getters for
  the field, and the rule methods below. Its state fields are
  library-private (a leading `_`).
- **The shell's side.** `main.dart` keeps one line per owner:
  `late final address = AddressInput(w, history: widget.browserHistory);`
  as a field, `address.follow(w.active);` in build where the old sync code
  was, and `address.dispose();` in `dispose` where the old disposals were.
- **`follow`.** It takes the selected tab, not a value worked out from it,
  so the rule that decides the value (here `_addressOf`, an unloaded Browser
  tab's own address) lives in the module with everything else that uses it.
- **View.** `BrowserBar(workspace, tab, input)` is a `StatelessWidget`. The
  shell builds it where it called `_browserBar(tab)`, under the same keyed
  `Positioned`, so keys and the tree shape tests rely on stay the same.
- **Logic placement.** The rules live on the owner, as public methods
  named for what the user does: `suggestionsFor`, `picked`, `escape`,
  `pointerDown`, `tapped`, `submitted`, `go` and `edited`. The view draws
  and wires its widgets to those methods (`onSelected: input.picked`). A
  view calls owner methods and passes in, or acts on, what needs its
  context; an owner never takes a region's `BuildContext`. An owner the
  shell creates and disposes may store the shell's own context, guarded by
  `context.mounted` exactly where the shell checked `mounted`
  (`AreaCapture`, `ShellActions`). Enter passes the
  field's `submit` callback in, as `input.submitted(submit)`. `edited`
  returns `now` itself unless the fill-in stays, and the view's formatter
  invokes `AutocompleteFirstOptionIntent` with its own context exactly when
  the returned value is a new one, as the old code did on that branch.
- **No field access from the view.** A view never reads or writes an owner
  field, even in the same file, where Dart would allow it. Later owners such
  as `ChatLayout` and `AreaCapture` are used from several files, where
  library-private access does not work, so the pilot does not teach it.
  Check with `grep -n 'input\._' flutter/lib/<module>.dart` (with the view's
  own name for its owner in place of `input`): expect nothing.
- **Lifetime checks.** Where the shell checked `mounted` after an `await`,
  the owner checks its own `_disposed` flag, set first thing in `dispose`.
  The owner is disposed exactly when the shell is, so the check means the
  same as before.
- **Shared constants.** `_barHeight`, which the page geometry also reads,
  became `BrowserBar.height`. A private item that code staying in
  `main.dart` still uses becomes the smallest public piece of the new
  module, and the hand-back lists it.

## Steps, in order

1. **Start.** Confirm the worktree's `HEAD` equals local `main`
   (`git log -1 --oneline` against `git log -1 --oneline main`); if `main`
   moved on and you have no commits, `git reset --hard main` on your branch.
   Run `flutter pub get` in `flutter/` and `npm ci --prefer-offline` at the
   root.
2. **Baseline run.** Run the full Flutter suite with the JSON reporter into
   `tmp/` (commands below) before any edit, and turn it into a name list.
   It must match `baseline.md`'s count.
3. **Read.** The target design's row for the module, its interface comment
   draft, the hidden coupling items the brief names, the Deletes list, and
   the code in `main.dart`.
4. **Find every member and its users.** Grep `main.dart` for each name on
   the slice's Deletes list. For each hit outside the code you move, decide:
   it is a caller (switch it to the new interface) or a shared piece (keep
   the smallest public part in the new module). Grep `flutter/test`,
   `flutter/integration_test` and `docs/` too: a public top-level function
   a test calls (like `inlineCompletion`) needs an import line in that test.
5. **Pin untested behavior first.** For each behavior of the code you move
   that no test pins, add a test that pins it, through `RelayApp`, before
   the move. To find such a behavior, break it on purpose (replace a
   condition with `false`, then `true`) and run the module's test file;
   nothing failing means nothing pins it. Show the new test passes on the
   old code and fails with the behavior broken, commit it alone as a
   test-only commit, and add its name to `baseline.md` by command (below).
6. **Build the module beside.** Write the new file: owner class first, then
   the view, then top-level helpers, in the old file's order where you can,
   so the moved blocks stay recognisable. Copy method bodies exactly. Keep
   every name, except a leading `_` for fields that move onto an owner and
   the public name, for what the user does, of a view callback that becomes
   an owner method with the same body, which the view then calls.
   Give the owner and the view a `w` getter (`Workspace get w =>
   workspace;`), as the shell has, so lines that use `w.` move unchanged.
7. **Move the callers.** In `main.dart`: replace the old fields with the
   owner field, the old sync code in build with `owner.follow(...)` at the
   same place, the old disposals with `owner.dispose()` at the same place,
   and each old builder call with the view, under the same key.
8. **Delete the old.** Remove every Deletes item from `main.dart`. A Python
   script that slices the file by line numbers, with an `assert` on the
   first and last line of each slice, is safer than hand edits for blocks of
   hundreds of lines. Add the new import; let `flutter analyze` report the
   imports that became unused.
9. **Markers.** A desktop-only member of the new shared file gets
   `/// Desktop only.` or `/// Desktop only (macOS).` as the first words of
   its doc comment (turn an existing `//` comment into the doc comment). This
   changes comment lines only; the code under it must stay a pure move.
10. **Format and analyze.** `dart format` the two files, then
    `flutter analyze` must say "No issues found!". It covers `test/` and
    `integration_test/` too, so a test that needs an import fails here first.
11. **Tests.** Fix only import lines in tests. Run the full suite with the
    JSON reporter again and compare the names (below): same count, all
    passing, no name lost or changed.
12. **Move review.** Run the `--color-moved` diff and list every line that
    is not shown as moved. Each must be one of: the new file's imports,
    class and constructor lines, the owner's `follow` and `dispose`, field
    renames, `mounted` to the disposed check, `widget.<x>` to the owner's
    field, a view callback replaced by an owner method call, an added
    `BuildContext` parameter, and comment edits for markers.
    Anything else is a behavior change and does not belong in the slice.
13. **Structure and map.** `python3 tools/check_structure.py --update` (it
    only lowers), then set the `Lines` cell of the `main.dart` Known debt
    row in `docs/architecture.md` to the new count, and drop the module's
    own name from that row's "Where its code should go" cell, since the
    module exists now. All go in the move commit.
14. **Other checks.** `npm test`, `npm run build`,
    `python3 tools/check_records.py`, `python3 tools/check_structure.py`.
15. **Commits.** Any test-only pinning commit first (step 5). Then one
    move commit (code, test imports, `structure.json`, the map's line
    count), through /smart-commit with a bug review. Then one records
    commit: slice marked done in the master plan, Next updated, any
    new trap added here. Stage, and run
    `python3 tools/check_records.py --staged` before each commit.
16. **Clean up.** Delete your own files in `tmp/`, then send the hand-back.

Do not split the move into "add the copy" and "delete the original": neither
diff would show a move. One move commit keeps the `--color-moved` evidence
in one diff.

## Check commands

Run from the worktree root. An agent's shell may not have `flutter`, `dart`,
`node` or `npm` on `PATH`. The local machine notes that AGENTS.md names give
the Flutter SDK's folder. Set `FLUTTER` to its `bin/flutter`, and add the
folder that holds `node` and `npm` to `PATH`, first:

```sh
FLUTTER=<path to the flutter binary>
(cd flutter && $FLUTTER pub get)
(cd flutter && $FLUTTER analyze)
(cd flutter && "$(dirname "$FLUTTER")/dart" format lib/main.dart lib/<module>.dart)
```

Test names before and after. Save this script as `tmp/names.py` (it skips
the "loading <path>" entries, which are not tests):

```python
import json, sys
tests, suites, results = {}, {}, {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith('{'):
        continue
    e = json.loads(line)
    if e.get('type') == 'suite':
        suites[e['suite']['id']] = e['suite']['path']
    elif e.get('type') == 'testStart':
        t = e['test']
        if t['name'].startswith('loading '):
            continue
        path = suites.get(t['suiteID'], '?').split('flutter/')[-1]
        tests[t['id']] = (path, t['name'])
    elif e.get('type') == 'testDone' and e['testID'] in tests:
        results[e['testID']] = 'skipped' if e.get('skipped') else e['result']
for i, (path, name) in sorted(tests.items(), key=lambda x: x[1]):
    print(f"{results.get(i, 'missing')}\t{path}\t{name}")
```

```sh
(cd flutter && $FLUTTER test --reporter json > ../tmp/before.json)
python3 tmp/names.py tmp/before.json > tmp/before.txt
# ... make the change ...
(cd flutter && $FLUTTER test --reporter json > ../tmp/after.json)
python3 tmp/names.py tmp/after.json > tmp/after.txt
wc -l < tmp/after.txt; cut -f1 tmp/after.txt | sort | uniq -c
diff <(cut -f2- tmp/before.txt) <(cut -f2- tmp/after.txt) && echo names identical
```

The move review. `git add -N` makes the new file show in the diff; the
second command prints only the lines git did not colour as moved:

```sh
git add -N flutter/lib/<module>.dart
git diff --color-moved=dimmed-zebra --color-moved-ws=allow-indentation-change main -- flutter/lib
git diff --color=always --color-moved=dimmed-zebra \
  --color-moved-ws=allow-indentation-change main -- flutter/lib \
  | grep -P '^\e\[3[12]m[+-]' | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^[+-]\s*$'
```

A new pinning test changes `baseline.md`. Regenerate its name lists from
the JSON run, then update the count and commit in its header by hand. Save
this as `tmp/baseline.py`; it prints each file's section in the record's
layout:

```python
import json, sys
from collections import defaultdict
suites, order = {}, defaultdict(list)
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith('{'):
        continue
    e = json.loads(line)
    if e.get('type') == 'suite':
        suites[e['suite']['id']] = e['suite']['path'].split('flutter/')[-1]
    elif e.get('type') == 'testStart':
        t = e['test']
        if not t['name'].startswith('loading '):
            order[suites[t['suiteID']]].append((t['id'], t['name']))
for path in sorted(order):
    tests = sorted(order[path])
    print(f"## {path} ({len(tests)})\n")
    print('\n'.join(f"- {name}" for _, name in tests) + '\n')
```

```sh
python3 tmp/baseline.py tmp/after.json > tmp/baseline-body.md
```

Short lines such as `),`, `}` or `submit();` can show as not moved even
inside a moved block: git needs about 20 letters or digits for a moved
block. Count them as moves when their neighbours are.

Structure, records and the rest:

```sh
python3 tools/check_structure.py --update
python3 tools/check_structure.py
python3 tools/check_records.py
git add -A && python3 tools/check_records.py --staged
npm ci --prefer-offline
npm test
npm run build
```

## Traps

- **"loading <path>" entries.** `flutter test --reporter json` reports a
  "loading <path>" pseudo-test for each file. Count only real tests.
- **Names exactly as printed.** Keep a test name as the runner prints it,
  including notes such as "(variant: TargetPlatform.macOS)".
- **Menu items.** `find.text('Reports')` also finds the Research app's
  description on the new tab page. Use
  `find.widgetWithText(MenuItemButton, …)` for menu items.
- **Running replies.** A running reply's spinner never settles, so
  `pumpAndSettle` times out. Tests with a running reply pump a fixed time.
- **`web_page_test.dart` under load.** Some of its tests can time out once
  when the machine is busy. Re-run the file alone, then the full suite once
  more, and report both runs.
- **The stash is shared.** Never use a bare `git stash` or `git stash pop`:
  every worktree and session shares one stash stack. Set work aside with a
  temporary commit.
- **Seeing a test fail on old code.** Put the old file in place with
  `git show <commit>:<path> > <path>`, run the test, then restore yours.
- **Subagents and worktrees.** A subagent cannot call EnterWorktree; it
  works in the worktree its starter made, by absolute path, with `cd
  <worktree> &&` before every shell command.
- **Private types in a public API.** `flutter_lints` reports a public field
  or method whose type names a private type (the pilot's private
  `_Suggestion` typedef). The owner's fields are library-private, so they
  may use it. Its public methods spell the record type out,
  `({String url, String title})`, which is the same type, so no new public
  name is needed.
- **A rule split between owner and view.** When the view keeps one
  context-bound step of a moved rule (the pilot's intent call after
  `edited`), check whether a test pins it: replace the view's condition with
  `false`, then with `true`, and run the module's test file. In the pilot
  neither failed, so the merge review asked for a test that pins the
  highlight reset; it came after the move. Later slices add such a test
  before the move (step 5).
- **No `context` in a stateless view.** A shell method that read
  `Theme.of(context)` or the shell's `colors` getter needs the context as a
  parameter in a `StatelessWidget`. In a builder callback that has its own
  `context`, read the theme there (one added line, such as
  `final colors = Theme.of(context).colorScheme;`). Check that no `Theme`
  widget sits between the shell and the view; in the shell there is none,
  so the colours are the same.
- **`late final` owners.** An owner created by `late final` is built on its
  first use, which is the shell's first build. That is fine for the shell:
  build always runs before `dispose`.
- **Reviewers need the full Flutter path.** Give /smart-commit's
  reviewers the SDK's path, or they skip `flutter analyze` and the tests.
- **Recorded size versus file length.** The recorded size can be lower than
  the file's length before the slice (slice 1c grew `main.dart` past it).
  `--update` sets it to the new length; the Known debt row takes the same
  number.

- **An owner others change.** When the old fields were written inside the
  shell's `setState` and later modules or a view change them too, make the
  owner a `ChangeNotifier` that the shell listens to with
  `setState(() {})`, as `ChatLayout` does. Notify on every change, even one
  that leaves the value as it was, since the old `setState` always redrew.
  An owner call inside the shell's own `setState` callback nests a
  `setState`; Flutter allows it.
- **No change during a build.** Never call a method of a notifying owner
  that changes it (`ChatLayout`, `AreaCapture`) during a build: its notify
  calls the shell's `setState`, which Flutter rejects during a build. Call
  them from event handlers, async continuations or the workspace listener
  (`_changed`); a build only reads the owner's getters.
- **Pinning tests use only the old code's names.** A pinning test must
  pass before the move, so it cannot name the new module's widgets (such
  as `ChatDock`). Find regions by keys, tooltips, texts or fixed geometry.
- **A sweep of broken conditions.** To find untested rules, a small script
  in `tmp/` can apply one exact replacement at a time to `main.dart`, run
  the region's test files with the JSON reporter and restore the file. Pass
  the test files rather than the whole suite: each run is a few seconds
  instead of about a minute.
- **The formatter and an existing test file.** `dart format` drops a test
  file's leading blank line. Put it back, so the test diff is only the new
  tests and import lines.
- **Private constructor parameters.** `prefer_initializing_formals` flags a
  named parameter copied into a private field. Positional `this._field`
  parameters, as in `ChatLayout`, avoid it.
- **A stored shell context.** `use_build_context_synchronously` follows a
  context kept in a field: `AreaCapture` reads `MediaQuery` through
  `_context` after an `await`, and the lint flags it unless
  `_context.mounted` guards it. Put that guard exactly where the shell
  checked `mounted`; after an `await` the two mean the same, and the owner
  then never notifies after the shell disposes it.
- **`Uint8List` in a new module.** `package:material_ui/material_ui.dart`
  does not export it; import `package:flutter/services.dart`, as the shell
  does.
- **Early returns in an old `setState` callback.** Write the same steps as
  if-blocks followed by one notify, and keep what followed the callback (as
  `finish` keeps its post-frame image release) on every path it ran on.
- **A record with a flag the view must not see.** When the old field is a
  record that also holds owner-only state (`reopenChat`), give the view a
  query method (`pickingOn(tab)`) rather than the record.
- **A guard the UI already enforces.** A rule that only repeats what the UI
  allows (`start`'s check that no capture is running, behind a disabled
  button) cannot fail a test through `RelayApp`. Say so in the hand-back and
  move it as it is.
- **A view that calls the shell's `setState`.** Make it a
  `StatefulWidget` with no fields, so the line moves verbatim (Show tab
  memory), and check that nothing else needed the shell's redraw.
- **Field promotion.** After the first `_updates!`, a private final field
  is promoted; drop the later `!` the analyzer flags.
- **An enum-first step.** Wrapped calls can pass the 50-line allowance; put
  the new type in the new module from the start.
- **A test file at its limit.** Pins that would pass 800 lines go in a new
  file named for their owner (`shell_actions_test.dart`).
- **Fixture routes.** A route or flag a pin adds to `support/fixture.dart`
  defaults to the old answer.

## Hand-back contents

As the [target design](target-design.md)'s Worker hand-back says, plus the
test name comparison.

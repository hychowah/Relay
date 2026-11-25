# Architecture

Where code lives and where new code goes. Change it in the same commit that
adds, moves or removes an area.

## Areas

| Area | Paths | Owns | Uses |
|---|---|---|---|
| Service | `server/` | Records, routes, agent runs, app protocol, Browser and Files apps, providers | `shared/` |
| Shared | `shared/` | Types and provider facts for the service and web page | only `shared/` |
| Web page | `web/` | The React browser fallback | `shared/` |
| App bridge | `public/` | `app-bridge.js`, which apps load, and the Flutter host page | nothing |
| Flutter client | `flutter/lib/` | The main client: tabs, chat, page surfaces, settings | its own files |
| Page scripts | `flutter/assets/` | JavaScript run inside web pages (`page_*.js`), the update script | nothing |
| Mac runner | `flutter/macos/Runner/` | macOS-only Swift: PDF viewer, popup windows, the window | Flutter |
| Windows runner | `flutter/windows/runner/` | Flutter's template runner | Flutter |
| Android runner | `flutter/android/app/src/` | Flutter's template host; no Relay code yet (the Android client comes later) | Flutter |
| Room example | `examples/` | A sample app that joins by the protocol | nothing from Relay |
| Tools | `tools/` | Developer tools, and `flutter-experiment.ts` (below) | `server/`, `shared/` |
| Tests | `tests/`, `flutter/test/`, `flutter/integration_test/`, `flutter/test_driver/` | Node, Flutter and Mac tests | what they test |

The service has two entry points: `server/index.ts` serves the web page, and
`tools/flutter-experiment.ts` serves the Flutter client.

## Where new code goes

- A service feature: `server/<feature>.ts` exporting `add<Feature>(app,
  store)`, added in `runtime.ts`, like `devices.ts`. `store.ts` is at its
  limit: a feature that needs new tables first splits it as Known debt says,
  in a commit of its own.
- A change to the app protocol: `shared/types.ts`, `server/integrations/http.ts`,
  `public/app-bridge.js`, the Room example and [the protocol](integration.md)
  together. Relay holds no code for one particular app.
- A Flutter feature: its own `flutter/lib/<feature>.dart`, opened from
  `main.dart` with one call. Its state gets its own class there (like
  `tab_memory.dart`), not fields in `workspace.dart`. Service calls go in
  `relay_api.dart`.
- A script run inside web pages: `flutter/assets/page_<feature>.js`, checked
  in Chromium by `tests/page-<feature>.test.ts`.
- Desktop-only code (Android comes later): a whole feature in its own file
  whose first line says `Desktop only` (or `Desktop only (macOS)`), started
  behind a `Platform` check; a desktop-only member of a shared file gets a
  `/// Desktop only.` line.
- macOS-only native code: one Swift file per feature in
  `flutter/macos/Runner/`, reached through the `app.relay/browser` channel.
- Windows-only code: `flutter/lib/windows_web_view.dart`, behind the
  `webview_flutter` interface.
- `web/` is the browser fallback, maintained only (R01 in the
  [master plan](plans/prototype/master-plan.md)): keep its chat and app
  opening working and fix bugs in place; it is not split.
- Tests: `tests/<feature>.test.ts` and `flutter/test/<feature>_test.dart`.
  Shared Flutter fakes go in `flutter/test/support/`, Mac-run helpers beside
  `flutter/integration_test/fixture.dart`. Production code never imports them.

## Boundaries

- `web/` and `server/` meet only through `shared/`. Checked by the rule
  "web and server meet only in shared".
- `shared/` imports only `shared/`. Checked by "shared imports only shared".
- Only `flutter/lib/windows_web_view.dart` imports `webview_all_windows`.
  Checked by "Windows web view stays in its adapter", which allows that file.
- Not checked by a rule: the Flutter client talks to the service only over
  HTTP and WebSocket, and apps join only by the protocol.

## Known debt

| File | Lines | Where its code should go |
|---|---|---|
| `flutter/test/workspace_test.dart` | 1,062 | Split with `workspace.dart` |
| `flutter/lib/web_page.dart`, `flutter/test/web_page_test.dart` | 1,535, 840 | `browser_address.dart`, `mac_browser.dart` (macOS), `page_trace.dart`, `page_highlights.dart`, `hosted_page.dart`; the test's fake to `flutter/test/support/` |
| `flutter/lib/workspace.dart` | 1,340 | `conversation_state.dart`, `workspace_session.dart` (save, restore, device tabs) |
| `server/store.ts` | 877 | Keeps the database and schema; `store-browser.ts`, `store-runs.ts`, `store-memory.ts` |
| `server/app.ts` | 864 | `tool-handlers.ts`, `runs.ts`; bots and memories to `add*` route modules |
| `web/App.tsx`, `web/style.css` | 1,877, 2,305 | Maintained fallback, not split |

## Structure window

The [Flutter shell refactor](plans/shell-refactor/master-plan.md) owns
`flutter/lib/main.dart`, the shell modules (`address_bar.dart`,
`new_tab_page.dart`, `chat_dock.dart`, `area_capture.dart`,
`workspace_menu.dart`, `page_stack.dart`, `chat_panel.dart`),
`flutter/test/support/` and the shell tests (the modules' `_test.dart`
files, `chat_input_test.dart`, `shell_actions_test.dart`, `shell_test.dart`)
until its close-out ends. Do not edit them before then; a shell feature
waits.

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
| Mac runner | `flutter/macos/Runner/` | macOS-only Swift: PDF viewer, popup windows, downloads, site icon fetches, the window | Flutter |
| Windows runner | `flutter/windows/runner/` | Flutter's template runner, and `screen_fill.cpp`: the window covers the screen for a fullscreen page | Flutter |
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
  The window reports presses on a page on `app.relay/page-press`, which
  `page_press.dart` hears from startup, before any page exists, and
  downloads on `app.relay/downloads`, which `browser_downloads.dart` hears.
  That file, not the runner, picks where each download goes.
- Windows-only code: `flutter/lib/windows_web_view.dart`, behind the
  `webview_flutter` interface. Native window code: one C++ file per feature
  in `flutter/windows/runner/`, answering on the `app.relay/browser` channel
  as the Mac window does.
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
  HTTP and WebSocket, and apps join only by the protocol. On the Mac every
  fetch Relay makes for a Browser tab (its PDF, its site icon) uses the tab's
  route, `WKWebView.tabFetches`, so a VPN tab's fetches never leave its tunnel.
  A download runs in its tab's own data store, so it should keep the tab's
  route (unverified for VPN tabs).

## Known debt

| File | Lines | Where its code should go |
|---|---|---|
| `flutter/test/workspace_test.dart` | 1,062 | Split with `workspace.dart` |
| `flutter/lib/web_page.dart`, `flutter/test/web_page_test.dart` | 1,483, 840 | `mac_browser.dart` (macOS), `page_trace.dart`, `page_highlights.dart`, `hosted_page.dart`; the test's fake to `flutter/test/support/` |
| `flutter/lib/workspace.dart` | 1,340 | `conversation_state.dart`, `workspace_session.dart` (save, restore, device tabs) |
| `server/store.ts` | 877 | Keeps the database and schema; `store-browser.ts`, `store-runs.ts`, `store-memory.ts` |
| `server/app.ts` | 864 | `tool-handlers.ts`, `runs.ts`; bots and memories to `add*` route modules |
| `web/App.tsx`, `web/style.css` | 1,877, 2,305 | Maintained fallback, not split |

## The Flutter shell

`flutter/lib/main.dart` holds startup, `RelayApp` and `RelayShell`: the state
owners and listeners, fullscreen, the banner and the toolbar. Each region of
the window has its own module:

| Module | Region |
|---|---|
| `address_bar.dart` | `BrowserBar` and `AddressInput`: fill-in, suggestions, Go |
| `new_tab_page.dart` | `NewTabPage`: app search, other devices' tabs |
| `page_stack.dart` | `PageStack`: every tab's page, split panes with their title rows and buttons, dividers, drop zones |
| `chat_dock.dart` | `ChatDock` and `ChatLayout`: dock, phone sheet, width |
| `chat_panel.dart` | `ChatPanel` and `ChatInput`: header, transcript, composer |
| `area_capture.dart` | `AreaCapture`: area picking and its attachment |
| `workspace_menu.dart` | `WorkspaceMenu`, `ShellActions` and `WorkspaceAction`: menu, dialogs, bug reports |

State that must outlive a region's widget, or that several regions read, is an
owner object the shell creates, disposes and hands down; the region's widget
is a stateless view of it. The shell pushes the selected tab into each owner
with `follow`. An owner keeps its state private and offers getters and
methods named for what the user does; a view uses only those and never passes
its own `BuildContext` to it. An owner the shell redraws on is a
`ChangeNotifier`; never call a method that notifies during a build (`follow`
runs in the build and never notifies).

A new region or feature follows the same pattern in its own module. The shell
never recreates a tab's native page view: `PageStack` keeps every page in one
keyed slot, so nothing above it may change the widgets' parent chain.

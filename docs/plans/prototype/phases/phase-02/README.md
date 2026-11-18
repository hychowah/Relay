# Phase 02

Status: active

The user prioritized a general plugin protocol before more app-specific features.
The [master plan](../../master-plan.md) owns requirements; the
[code plan](../../plugin-protocol.md) records this slice's structure and
[integration contract](../../../../integration.md) defines the implemented API.

## Foundation choice

A probe used MCP client/server SDK 2.4.0 and MCP Apps
2.0.4. Actual SDK exchange verified discovery, structured calls, progress and
cooperative cancellation; App/AppBridge exchange verified view tools and model
context. It did not exercise browser rendering. MCP core remains technically
viable, but native external URLs and persistence are deferred in the
[MCP Apps stable specification](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx).
The selected Relay v2 contract keeps independently hosted app screens and a shared
browser bridge. It is not MCP-compatible and introduces no MCP dependency.

## Evidence

On 2026-11-16:

- The pre-change Relay suite passed 39 tests. The implemented operation/bridge
  suite passed 57 tests; TypeScript, production build and direct Node 24 imports
  passed. A runtime smoke caught and removed a TypeScript parameter property
  unsupported by the production Node entry point.
- Operations use scoped discovery, app-owned schemas/results, recorded progress
  and upstream HTTP abort on Stop. Tests cover invalid response envelopes,
  published operation names and bot scope. Current app implementations are
  read-only; the protocol does not infer permissions for arbitrary future writes.
- The room-layout example has no search/read/Report API. Through the real
  OpenCode loop and scripted provider it discovers, inspects and presents four
  semantic furniture targets. Browser checks confirm manual context, render
  acknowledgement, user interruption, Stop, reopening chat and phone layout.
- Research's hosted source adds v2 operations and native presentation while
  preserving v1 routes and the old bridge. Source baseline/final checks passed
  320/322 cases with six environment skips. Separate-port browser checks use
  synthetic published evidence and actual native UI code; both price and DoF
  targets rendered. Offline pack inputs are unchanged, so no pack rebuild is
  needed. Live process, publication and feedback were left untouched.
- A render-failure check identified stale context after partial navigation.
  The bridge now obtains current app context for failed/manual presentations;
  a failure never becomes applied. Original question context remains recorded.
- Browser checks confirmed repeated Research → Room → Research presentation in
  one run, with fresh generations after remounting and unchanged original question
  context. A focused regression also covers returning from a legacy source view.
- Final native Research checks confirmed both qualified fields highlighted after
  animation completion, trusted manual input superseding presentation, Stop and
  correct next-question context after a forced post-navigation target failure.
  Legacy Library/citation opening and reload kept the same saved revision.
  Desktop and 390-pixel native/legacy frames had no horizontal overflow; the
  final browser console had no errors or warnings. Temporary servers were closed.
- After the user's WSL migration, Relay was reconnected to Research at
  `127.0.0.1:2000`. Live v2 discovery, catalog/search and native-view HTTP checks
  passed, including the existing Tailscale forwards from Windows.
- Room browser checks covered draft and frame retention, Stop and reopening
  chat, keyboard controls, reduced motion, phone layouts and manual takeover.

On 2026-11-17, the attention/citation changes passed 63 Relay tests and the build.
Research's synthetic native view showed price/DoF markers and completed animation
before applied; Stop/manual interaction cleared markers and reduced motion
produced none. A synthetic recorded citation restored both fields at the original
revision through saved-source navigation. Research baseline/final checks passed.

An earlier fixed split was rejected. The user now requests desktop chat on the
right, initially 30% wide, with a draggable divider; phones retain the overlay.
The build and browser checks passed at 1440px, 1024px and 390px, including short
screens, keyboard resizing, saved width, draft retention and unchanged iframe.
Two scripted turns through OpenCode applied Room presentations: desktop chat
stayed open; phone chat collapsed. Static assets are live without a service
restart. Drawing and resolved points remain unimplemented.

The prompt-first follow-up used six real DeepSeek Flash turns on isolated Room
browser sessions, with synthetic app evidence. It exercised target selection,
new selection, manual takeover and unavailable actions. Correct navigation and
stale handling were observed; excess narration/inferences and hidden explanations
remain. The [evaluation](working/discussion-prompt-evaluation.md) records each turn,
the bounded prompt refinement and limits. Five harness tests and the build passed.
The production harness was not restarted.

The explanation follow-up adds optional bounded plain text beside app targets.
Three more real DeepSeek turns used it in Room and native Research with synthetic
evidence. All 66 Relay tests/build and Research baseline/final checks passed;
browser checks covered phone layout, manual cleanup and pending cancellation.
The [evaluation](working/presentation-explanations.md) records behavior and limits.
At the user's subsequent request, both live services were restarted. Updated bridge
and discovery passed local/Windows-forward checks; Research startup regenerated
its publication revision. Conversation identities remained unchanged.

On 2026-11-18, both stock adapters passed v2 discovery, saved-record search/read
and v1 revision reopening. They now live in a separate project. Chromium exercised
the Analysis FastAPI report route on a synthetic archive and Rust `bt serve` on a
fictional HK run. The Flutter browser host focused and explained a report's
risks and a backtest's performance, opened both original websites, returned
to each saved reader and restored the cited sections. The React picker
listed both apps and opened the saved backtest. All 81 Relay tests passed.

## Limits

No physical Android or second-device network test was performed. Live provider
checks used synthetic Room/Research data. Production Research answer quality and
Android keyboard behavior remain unverified. The broader Phase 02 exits
(live stock-app trials, cross-app sourced answers and split views) remain open.

## Next

Follow the master plan’s provider, deployment and device checks.

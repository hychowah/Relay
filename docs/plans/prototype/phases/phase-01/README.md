# Phase 01

Status: active

This phase covers native app interaction and the prioritized bot/memory slice.
See the [master plan](../../master-plan.md) for requirements and exits, and the
[README](../../../../../README.md) for operation.

OpenCode supplies the [model/tool loop](decisions/0001-agent-runtime.md);
apps follow the [integration contract](../../../../integration.md).

## Evidence

Verified on 2026-11-15 with Node 24.22.0, React 19.3.1 and OpenCode 2.3.0:

- Scripted harness tests cover app registration, revisions, persistence,
  cancellation, recovery, unavailable sources and device-bound navigation,
  including admission and pagination regressions.
- Bot/memory tests cover additive migration, shared/private scopes, permissions,
  corrections/forgetting, fixed-message forwarding and paginated original history.
  Two actual OpenCode compactions retain original messages and re-inject current
  memory/checkpoints.
- Synthetic desktop and 390×844 browser checks cover sourced answers, selection,
  navigation success/staleness, two-device isolation, browser closure/reload,
  bot/memory CRUD, forwarding/source navigation and history search without
  horizontal overflow. A permitted native index page stays mounted when document
  context clears; changing chats/bots clears prior app context.
- Provider tests and synthetic-key browser checks cover private persistence,
  redaction, external-key reuse, replacement, model/mode changes, password
  clearing, focus and mobile layout. Changes preserve open views/conversations;
  existing sessions adopt the new model on their next request.
- The real Research Web publication passed native Chromium checks for initial
  search/open, manual routing, filters/language/selection, confirmed/stale
  navigation, two devices and both layouts. Saved text remains available when
  the native publication changes. PDF links open new tabs; standalone inline
  PDFs still work. Its `make check` passed 319 cases with six environment skips;
  the final browser console was clear. See Research Web's
  `relay-interface-2026-11-15.md` handoff.
- Windows `curl.exe` received HTTP 200 at `http://localhost:3210` through existing
  WSL forwarding. Restart retained all seven conversations and 28 messages.
  No firewall, portproxy or Tailscale configuration was changed.
- Records-checker cleanup preserves enabled rules. Synthetic Git repositories
  verified indexed content, sizes, links, instructions and ignore rules against
  conflicting working edits. Two focused regression tests remain in the suite;
  TypeScript and the repository records check pass.

On 2026-11-16:

- The user's saved “hi” conversation contains completed DeepSeek answers and
  Research Web search/read calls. Its valid Markdown tables were previously
  displayed as plain text, with conversation-wide source cards below replies.
  Responses now render GFM and group collapsed activity/sources by question.
  Renderer tests and desktop/390×844 browser checks cover tables, citations,
  bounded disclosures, history scrolling and the Latest answer control.
- Thinking checks cover conversation persistence/migration, simultaneous-session
  isolation, default resets, restored sessions, tool steps and compaction through
  the actual DeepSeek adapter. All 62 tests pass. Desktop and
  390×844 fixture UI checks verify separate Max/Low chats, reopening and inherited
  defaults. Synthetic-key checks verify redaction; no paid requests.
  Relay was restarted with no active replies; all nine conversations, 38 messages
  and run records were preserved.
- Trash tests cover migration/persistence, restore, hidden history, 24-hour expiry,
  cleanup retries and preserved memories/other chats. Agent-session deletion uses
  the real harness with a local fixture. Desktop/phone screenshots verify 11px
  confirmation without overflow; checks cover restore and Trash persistence. The running
  fixture automatically purged a chat backdated beyond 24 hours.
- Windows Tailscale Serve privately forwards 10001 to Relay and 10002 to Research
  Web; existing forwards remain intact. Research Web now permits both Relay
  Tailscale parent origins. Windows HTTP checks return 200 for Relay and the
  embedded Research page through IP/MagicDNS. WSL cannot reach those Tailscale
  addresses directly, so this does not establish second-device browser access.
- Applying Research Web's parent-origin setting restarted its normal publication
  supervisor, which published the current source with a new revision. Saved
  Relay records remain intact; older views report the revision mismatch and
  offer an explicit Open current app page action.
- Live browser checks render the existing “hi” tables and keep its 19-call turn
  collapsed. An old citation retains saved text; Open current app page and fresh
  Apps resources open the real Research iframe with populated parent context.
  These checks route Tailscale requests to local services inside Playwright,
  preserving browser origins/CSP; they verify rendering, not tailnet routing.
- The app-led UI opens the app as the main workspace and collapses chat into
  actual operation status. Synthetic browser checks through OpenCode verify two
  successive navigations, both field highlights, reopening chat during work,
  Stop, manual navigation superseding automation, chat-only entry and phone layout.
  Applied acknowledgements advance the run's navigation token without changing
  original question context. Research Web exposes full published catalog evidence
  and model field targets; its baseline/final checks pass 319/320 cases with six skips.
  Native Research browser checks through the scripted harness confirm both fields
  remain visible on desktop/phone, correct context updates and current-publication
  reloads without rewriting stored citations. Both publication profiles built;
  the Windows host and Relay service were refreshed after preserving the prior
  publication. Tailnet HTTP checks pass; browser checks still use scoped routing.

## Limits

The initial checks used fixtures. Subsequent live provider evidence is in the
[provider record](working/provider-connections.md); real Claude answers, memory
selection/correction/forgetting and realistic long-history recall remain
unverified. Thinking options have transport and UI evidence, not a live comparison
of their results. Manual memory edits
and forgotten keys have deterministic protection, not semantic erasure of
archived facts.

Docker Compose configuration validates, but the image, container recreation and
resource restrictions remain untested: Docker Desktop's Linux engine and WSL
integration were unavailable. Access from a second tailnet device and live
Analysis Web remain unverified, keeping Phase 01 active. The Android hardware
trial is deferred.

## Next

Follow the [master plan's next work](../../master-plan.md#next). Update this
record when new verification changes the evidence or limits; keep operating
instructions in README.

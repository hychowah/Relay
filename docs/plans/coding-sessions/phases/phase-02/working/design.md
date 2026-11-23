# Phase 2 design: the coding workspace screen

Code design for [phase 2](../../../master-plan.md#phase-2--workspace-screen).
The work happens in the coding app's own repository, except the theme, which is
in Relay core. Delete this file when phase 2 is done; lasting facts go into the
coding app's README and AGENTS.md and Relay's `docs/integration.md`.

## Shape

The screen follows the user's mockup. The left bar holds the workspace (one
configured target), its worktrees and its sessions, and folds away. The right
side shows one session with Conversation, Changes and Terminal tabs and a
composer. hapi is the engine and is not changed.

**The server owns the session model; the page draws snapshots.** The page
uses three things:

- `GET /api/sessions/:id` returns a full snapshot: header plus blocks.
- `GET /api/events` only says "session X changed".
- `POST` routes carry the user's intents.

On a change the page fetches the snapshot again. It has no merge logic and no
hapi formats. The later check-back phase reuses the same snapshot for the
agent.

Rejected: a thin proxy with a thick page. That would leak hapi's roughly 80
routes, its event types and the raw Claude and Codex formats into the page,
and check-back would need a second normalizer.

**Messages become blocks through hapi web's own reducer, run on the coding
app's server.** `build.ts` bundles hapi's `web/src/chat/normalize.ts` and
`reducer.ts` from the local hapi checkout (`HAPI_SOURCE_DIR`, default
`../hapi`) into an ignored `build/hapi-chat.js`. It runs before start and
before tests. The bundle also includes hapi's permission-mode and effort
lists.

That code path uses no React; it imports only `@/chat/*`, plain helpers,
types and `@hapi/protocol`. Writing our own normalizer was rejected: hapi
already has about 5,000 lines for this (`normalizeAgent.ts` alone is 1,480),
and they track Claude Code and Codex format changes. Moving the reducer into
hapi's hub was rejected as too large a change to the fork. When hapi changes,
only `conversation.ts` breaks, at build or test time.

**Page technology.** The page uses Preact with htm, from the single file
`htm/preact/standalone.module.js` served from node_modules. There is no page
build, and `script-src 'self'` still holds. Markdown is drawn by markdown-it
with `html:false`. The terminal is drawn by `@xterm/xterm` and its fit add-on.

## Modules (coding app)

| Module | Hides | Interface |
| --- | --- | --- |
| `hapi.ts` | All of hapi's API: sign-in (JWT cached, signs in again on 401), routes, events, terminal socket | `sessions()`, `session(id)` (the latest 200 raw messages, agent state, metadata), `send`, `resume`, `approve`, `deny`, `abort`, `setSettings`, `events(signal)` (yields changed session ids), `openTerminal` (step 3), and the existing `start` and `openOutside`. Error text is safe to show and never contains the token. It no longer groups sessions. |
| `conversation.ts` | hapi's block shapes and tool names | `toBlocks(messages, agentState) → {blocks, contextUsed}`. The block kinds are `user`, `agent`, `step` and `note`. A `step` has a title, state and duration, and optionally a `diff`, an `output`, an `approval:{requestId,state}` and child `steps`. A `note` is an event, an error or thinking. Common Claude and Codex tools get titles; any other tool shows its name and a short input summary. |
| `diff.ts` | How diffs are made | `Diff = {file, added, removed, hunks:[{lines:[{kind,text,oldLine?,newLine?}]}]}`, built by `fromStrings(old,new)`, and in step 2 by `fromGit(text)`. The page has one diff renderer. |
| `workspace.ts` | git | `worktrees(target)` returns branch, folder, last change, and from step 2 the added, removed and file counts. Also `changes(target, worktree)` and `fileDiff(target, worktree, file)`. A session belongs to the worktree whose path equals its hapi folder. |
| `server.ts` | The HTTP boundary; **every check happens here, once** | Relay protocol routes (unchanged) plus the screen API. Session grouping moves here from `hapi.ts`. |
| `build.ts` | How hapi's chat code is bundled | `HAPI_SOURCE_DIR` → `build/hapi-chat.js` |
| `view/` | Drawing | `main.js` (bridge, view routing, stream, snapshot fetch), `bar.js`, `session.js`, `changes.js`, `terminal.js`, `ui.js` (htm, Markdown, diff), `view.css` (uses `var(--relay-*, fallback)`) |

## Screen API

All routes are same-origin only, and writes take JSON only, through the
existing `/api/*` middleware.

| Route | Use |
| --- | --- |
| `GET /api/workspaces` | Targets (id, name) for "Open workspace…" |
| `GET /api/workspaces/:targetId` | `{name, worktrees[], sessions[]}`, including conversations from outside hapi in those worktrees |
| `GET /api/sessions?all=1` | Today's list across projects, which keeps C08 |
| `GET /api/sessions/:id` | `{session:{id,title,agent,model,effort,permissionMode,status,folder,branch,worktree?,targetId?,startedAt,contextUsed?,hapiUrl,canSend}, blocks, earlier}`. Blocks come from the latest 200 messages; when `earlier` is true the page shows "Earlier messages in hapi ↗". |
| `GET /api/events` | SSE lines of `{sessionId}`. The page refetches the open session, one fetch at a time; changes that arrive meanwhile become one more fetch. It also refetches the bar. |
| `POST /api/sessions/:id/messages {text}` | Sends exactly that text. A stopped session is resumed first, with the permission mode sent explicitly; the button then reads "Resume and send". |
| `POST /api/sessions/:id/approvals/:requestId {decision}` | `approve` or `deny` |
| `POST /api/sessions/:id/stop` | Stop |
| `POST /api/sessions/:id/settings {model?,effort?,permissionMode?}` | Composer menu |
| `POST /api/sessions {targetId, agent, worktree, text}` | New session from "+". It saves a draft record and starts it through the same `startDraft()` as `/api/drafts/:id/start`, so there is one start path that starts at most once. |
| `GET /api/workspaces/:t/worktrees/changes?worktree=…`, `…/file?worktree=…&file=…` | Step 2 |
| `POST /api/sessions/:id/terminal` → `{terminalId}`; `GET /api/terminals/:id/output` (SSE); `POST …/input`, `…/resize` | Step 3. Using SSE plus POST keeps the existing origin and JSON checks, with no WebSocket server. The terminal closes when its output stream closes. |

## Error model

- **Checked once, in `server.ts`.** `targetId` is configured; `worktree` is in
  that target's current `git worktree list`; `file` is in that worktree's
  current change list; text is at most `MAX_REQUEST`. Code behind the server
  trusts its input. Folders come only from configured targets and the
  worktrees git reports for them.
- **hapi down, sign-in failure or a hapi refusal.** The server answers 502
  with hapi's phrase. The page keeps the last snapshot and shows one line
  where the action failed.
- **The event stream drops.** `EventSource` reconnects and the page fetches
  the snapshot again. There is no resume logic.
- **An approval that was already answered** (hapi answers 404 or 409) counts
  as done, and the page refetches.
- **Question tools** (AskUserQuestion, `request_user_input`). The card links to
  "Answer in hapi ↗".
- **A Claude session attached to a live terminal.** hapi's 409 reason is shown
  as it is.

## Theme (Relay core)

- **The message.** Relay sends `relay.theme` to the app after `relay.ready`
  and again on every change: `{theme:{mode, colors:{background, surface,
  raised, text, muted, accent, onAccent, line, tint, danger}, font,
  monoFont}}`.
- **The bridge.** `public/app-bridge.js` checks the origin and token as it does
  for other messages. It then sets `--relay-<name>` CSS variables and
  `color-scheme` on `:root`. Apps use `var(--relay-text, <own default>)`, so an
  app still works without the message.
- **Flutter.** A pure `appTheme(ThemeData) → Json` function in
  `workspace_style.dart` builds the message. `_AppPage` sends it through
  `window.relayPresent` when it changes. `flutter-host.html` does not change.
- **Not changed.** The React fallback sends no theme.

## Views and the agent boundary

- View ids stay `home`, `session` and `draft`. `home` gains
  `state:{targetId}`.
- The context never carries paths, titles or messages.
- No Relay operation reaches a screen action or the terminal.
- `trustedNative` is no longer needed: the page uses `fetch` and no forms.

## Steps

1. **Session screen, with the theme in Relay core.**
   - Start with the probe below.
   - Server: `build.ts`, `conversation.ts`, the deeper `hapi.ts`, `diff.ts`
     (`fromStrings`), `workspace.ts` (`worktrees()` without counts), and the
     snapshot, event, action and new-session routes.
   - Page:
     - the bar: workspace menu with "Recent sessions in all projects", the
       workspace's sessions, "+", and the fold toggle (an overlay below about
       760 px);
     - the header with title, status, branch, "Open in hapi ↗" and Stop;
     - the conversation: Markdown; steps folded to one line, with finished
       neighbours of the same kind grouped; inline diffs; approval cards;
     - the composer: Enter sends and Esc stops; one menu for model, effort and
       permission mode; the context bar.
   - A draft opens as the new-session composer, filled in, with an explicit
     Start.
   - Small reading tasks while writing it: what `engine.resumeSession`
     returns and which mode it uses (the stand-in encodes the answer); the
     model lists per agent (`shared/src/models.ts`, `/codex-models`).
   - Tests (about 7, with a stand-in hapi):
     - `toBlocks` on a small synthetic Claude fixture and a Codex fixture;
     - no secret appears in a snapshot;
     - send passes the exact text, and a stopped session is resumed with an
       explicit mode;
     - approve, deny, already-answered, and stop;
     - one new POST route refuses cross-site and non-JSON requests (the
       middleware covers the rest);
     - events become `{sessionId}`;
     - new session and draft Start share the start-once rule.
   - Theme: one bridge test, one Flutter `appTheme` test, and a short "Theme"
     entry in Relay's `docs/integration.md`.
   - In the Mac run, also watch for a theme flash before `relay.ready` (if it
     happens, pass `mode` in the view URL) and that "Open in hapi ↗" opens the
     external browser.
2. **Worktree tree and Changes tab.**
   - `workspace.ts` gains counts: `git diff HEAD --numstat` plus untracked
     files, so "Clean" means nothing uncommitted. It also gains `changes()`
     and `fileDiff()`, and `diff.ts` gains `fromGit()`.
   - The page gets the tree (branch, "Updated …", +/− or Clean, running dot,
     "N active"), the Changes tab with its count, and the sessions filter.
   - Two tests on a temporary git repository: the counts and the change list,
     and that an unknown worktree or file is refused.
3. **Terminal tab.**
   - `hapi.ts` gains `openTerminal`, with routes as above, and xterm in the
     page.
   - One test: input reaches a stand-in socket and its output reaches the
     stream. It needs `socket.io` as a dev dependency.

Each step ends with one headless-browser run against the stand-in and **one Mac
run**.

**Not built:** search (⌘K); creating worktrees from "+" (sessions start in
an existing worktree, main by default); answer forms for question tools;
paging through older messages; any hapi change.

## Deletes

- **Coding app:**
  - `view.js` and `view.css`, replaced by `view/`;
  - the `/api/session-url` route and its tests;
  - `?sidebar=hidden`; the draft screen's `sessionUrl` becomes `hapiUrl`;
  - `frame-src` in the CSP and its test;
  - the `url` field on listed sessions and the framing assertions;
  - `SessionGroup` and the grouping in `hapi.ts`;
  - in the README and AGENTS.md, every mention of the frame, including the
    `trustedNative` paragraph and apps-file example, the "framed session"
    wording of `HAPI_BROWSER_URL` and `RELAY_ALLOWED_ORIGINS`, and the "Not
    yet verified" items about the frame.
- **Relay:** at phase 2 handoff, rewrite the Phase 1 frame text in the coding
  master plan (the "opens one in the frame" note and "Phase 2 replaces the
  frame…").
- **Runtime:** the user drops `trustedNative: true` from the coding app's entry
  in Relay's apps file.

## Probes

Probes run in the coding app's ignored `tmp/`, log no session content, and are
deleted after.

| Unknown | Probe |
| --- | --- |
| hapi's reducer bundles and runs in Node 24 (esbuild resolves `@/` and `@hapi/protocol`; no browser globals), and which tool names and input shapes come out of it. If it fails, write our own small normalizer instead. | The first act of step 1: esbuild over a two-line entry, then `toBlocks` on hapi's own test fixtures. If it works, it becomes `build.ts`. If the running hub can differ from the bundled checkout, the README says to rebuild the coding app with hapi. |
| hapi's `/api/events` from the server: Bearer auth, `all=true`, gzip through Node `fetch` | A 30-second read-only stream that prints event types only |
| How long a snapshot of a long session takes | Time one. If it is slow, cache normalized messages in `conversation.ts`; the interface does not change. |

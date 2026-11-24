# App integration

Relay connects independently hosted apps through a configured HTTP origin.
Flutter displays the app in an iframe inside a system WebView. The React
browser fallback displays the app in an iframe. Apps own data, routes, semantic
targets and animation. Relay owns chat, execution records, device-scoped
presentation and cancellation. It does not install executable app code into the
agent harness. App processes are not part of the protocol; the host's service
manager can run them, controlled from the optional
[servers file](../README.md#manage-app-servers).

## Registration

`RELAY_APPS_FILE` contains an array of `{id,name,serverUrl,browserUrl?,trustedNative?}`. Addresses
are HTTP(S) origins. `serverUrl` is reachable from the service; `browserUrl`
defaults to it and must be reachable from the browser. App and Relay origins must
differ. Each app permits its configured Relay parent origins.

The service reads the file again whenever it needs the app list, so added,
changed and removed entries apply without a restart, including the app list
the agent sees on its next step. Unchanged entries keep running. If the file
cannot be read or has an invalid entry, the previous list stays in use and the
service log says why. A tab already open on an app whose entry changes keeps
its old view until the tab is reopened. Flutter refreshes its app list when the app picker, App
library or Bots dialog opens; open tabs stay. The browser page reads apps when
it loads.

An app that is down when it is registered is treated as v2 and works when next
opened or used. A v1-only app, and its Library control, appear once its
manifest has loaded and the client next reads the app list.

Native apps use an iframe sandbox by default. An operator can set
`trustedNative: true` for their trusted app to omit that sandbox and retain native
browser features such as embedded PDF viewing. This gives the app ordinary
cross-origin iframe privileges, including forms, downloads and user-initiated
top-level navigation; use it only for trusted registrations. The separate-origin
requirement still applies. App manifests and agent calls cannot enable this flag.
Generated content does not inherit this trust. The default sandbox also ignores
page dialogs (`confirm()` answers false at once) and blocks form submission, so
an app that needs either must be registered as trusted
(`tests/app-frame-dialogs.test.ts`).

The [room-layout example](../examples/room-layout/README.md) is a complete v2 app
without document APIs. Research Web implements v2 plus its existing v1 evidence
interface. Adding either requires registration, with no app-specific Relay core
branch. Running v1 installations remain supported until refreshed.

## HTTP protocol v2

`GET /_relay/manifest` returns:

```json
{
  "version": 2,
  "id": "room-layout",
  "name": "Room layout",
  "description": "Inspect a studio's furniture and zones.",
  "instructions": "Use layout.inspect, then present its returned intent.",
  "view": { "path": "/_relay/view" }
}
```

Names/descriptions identify available apps. `app_discover(appId)` loads that app's
instructions and `GET /_relay/operations`; other apps' detailed schemas are not
injected into the model context. Discovery returns:

```json
{
  "operations": [{
    "name": "layout.inspect",
    "description": "Inspect a room zone.",
    "inputSchema": {
      "type": "object",
      "properties": { "zone": { "type": "string", "enum": ["all", "work", "rest"], "default": "all" } },
      "additionalProperties": false
    }
  }]
}
```

`app_call(appId, operation, arguments)` sends `POST /_relay/call` with
`{operation,arguments}`. The response is `application/x-ndjson`: optional progress
events and exactly one terminal result or error, followed by response completion.

```jsonl
{"type":"progress","message":"Inspecting the work zone"}
{"type":"result","result":{"data":{"count":2,"presentation":{"viewId":"room","state":{"zone":"work"},"targetIds":["desk","lamp"]}}}}
```

An app error uses `{type:"error",message}`. Results are
`{data:JSON,sources?:Source[]}`; `data` belongs to the app. Returning presentation
intent inside data is a useful convention, not an automatic navigation trigger.
The agent chooses meaningful steps through `app_present`. Sources use the
revision-pinned evidence identity; apps publishing these citations also provide
the optional v1 read/view interface to reopen them. Tool records retain operation
data and source references.

Relay checks the protocol envelope, configured identity, source origin and
published operation name. The app validates arguments and business rules. Bot
app access is enforced by Relay. Current implementations expose operations that
read, and one that saves a draft inside its own app for the user to act on;
discovery is not a sandbox for arbitrary third-party writes.
Provider credentials never enter app requests or browser frames.

Progress describes actual work. Stop aborts the HTTP request and cancels pending
presentation; apps should stop cooperative work on disconnect. Disconnect alone
does not establish that remote work stopped. There is no durable job scheduler or
automatic replay. Transport failures, malformed responses and app errors remain
distinct in tool results. Relay waits ten seconds for call response headers and up to
60 seconds between complete events. Apps should report progress at least once every
60 seconds while work continues.

## Native presentation

`GET /_relay/view?token=...&parentOrigin=...` opens home without reading a Report.
The app validates its permitted parent and sets `frame-ancestors`. Native frames
allow scripts and their own origin by default; trusted-native registrations omit
the sandbox so embedded PDF viewers work. Native apps own PDF markup and fallback links.

Hosted views load `${parentOrigin}/app-bridge.js`, then connect:

```js
const bridge = RelayApp.connect({
  token, parentOrigin,
  getContext: () => ({ viewId: "room", state: { zone: currentZone } }),
  // Optional: opt in to short explanations beside a rendered target.
  getExplanationTarget: intent => intent.targetIds?.length
    ? findTarget(intent.targetIds[0]) : roomElement,
  async present(intent, { signal }) {
    // Resolve after the app's route, targets and animation settle.
    return await renderRoom(intent, signal);
  }
});
// Publish manual route, filter or selection changes:
bridge.updateContext({ viewId: "room", state: { zone: "work" } });
```

`ViewIntent` is `{viewId,state?:object,targetIds?:string[],source?:Source,explanation?:string}`.
Targets are stable app-owned identifiers, not selectors or executable code.
Context adds optional `selection`; the helper owns numeric `generation`.
`getContext` reports the currently visible state, including a partial view change
if presentation fails. Failure updates context without claiming success.
The callback returns settled context without generation. It checks its abort
signal before delayed changes, verifies targets and awaits its own animation.
Respect reduced-motion preferences. Do not call `updateContext` from `present`:
that method means manual state has superseded automation.

Apps supporting explanations advertise this in discovery instructions and provide
`getExplanationTarget(intent)`, returning the first requested target's DOM element
or the current view root when no target was requested. Missing requested targets
must not fall back silently. The helper also resolves subsequent targets through
this callback to avoid covering highlighted evidence when space permits.
`explanation` is optional plain text, nonblank and at most 600 characters. It
should explain the finding with its qualifications in one or two short sentences.
The helper renders one dismissible note inside the app frame, using text content,
after native presentation settles. It positions the note near the target and
tracks scrolling/resizing. Unsupported, missing or invisible targets fail the
command; `applied` includes the note's render frames.

This is a temporary explanation, not a saved annotation. A new presentation,
manual app interaction/context change, pending-command cancellation, failure or
disposal removes it. Reading or scrolling inside the note preserves it; Escape
and its dismiss button close it. Apps with their own manual-input handlers should
ignore events inside `[data-relay-explanation]`. The intent remains in tool history;
reopening a source does not restore the note.

The shared helper checks parent window, origin and token. All messages carry
`version:2` and `token`:

| Message | Direction | Payload |
| --- | --- | --- |
| `relay.ready` | App → Relay | Initial `context` |
| `relay.context` | App → Relay | New manual `context` and generation |
| `relay.present` | Relay → app | `commandId`, `expectedGeneration`, `intent` |
| `relay.presented` | App → Relay | `commandId`, `status`, resulting `context`, optional `error` |
| `relay.cancel` | Relay → app | `commandId` |
| `relay.theme` | Relay → app | `theme` (see Theme) |

Only completed rendering/animation produces `applied`; other results are `stale`
or `failed`. Captured pointer/key input immediately invalidates pending work.
Subsequent app updates publish settled manual context. Disposal removes listeners
and aborts pending work. The helper coordinates requests, not app rendering.

Relay also checks originating device/tab and its own view token. An applied
acknowledgement advances the next command's token and app generation, preserving
original question context in history. A failed presentation may also return its
actual context and token so a corrected retry uses the current view; the action
stays failed. Stale/manual changes never advance that chain. Once its token
check passes, the Flutter client presents with the open page's own generation,
so a request sent without context can still present in the app already open.
Commands remain pending until acknowledged; a server result is not proof of a
visible change. A disconnected browser does not block the agent indefinitely.

### Theme

The Mac client sends `relay.theme` after `relay.ready` and on each theme change:
`theme:{mode:"light"|"dark", colors:{background, surface, raised, text, muted,
accent, onAccent, line, tint, danger}, font, monoFont}`. The helper sets
`color-scheme` and `--relay-<key>` variables (kebab case, such as
`--relay-on-accent` and `--relay-mono-font`) on the root element. Use them with
your own default, `var(--relay-text, #222)`, because other hosts send no theme.

## V1 evidence and retained views

V1 manifests have `version:1`, `capabilities:{search:true,read:true,...}` and
`view:{path:"/_relay/view",resourceId?}`. The optional resource is the readable
home. Existing `app_search`, `app_read` and `app_navigate` tools remain available:

- `GET /_relay/search?q=...` returns `{resources:Resource[]}`.
- `GET /_relay/read?resourceId=...&revision=...` returns
  `{source:Source,sections:[{id,title,text}]}`; revision is optional. An unavailable
  requested revision returns 409 rather than silently replacing evidence.
- Native views accept resource ID, revision, token and parent origin. For a v2
  app retaining this interface, saved-source opening adds `protocol=1`.

A v2 app that keeps this interface declares `capabilities.search` and/or
`capabilities.read`; Relay refuses the matching tool otherwise.

`Source` is `{appId,resourceId,revision,title,sourceUrl}`. URLs resolve against the
browser origin. Saved Reports retain exact evidence independently of whether
the live app still serves its revision. Old commands without a kind are read as
navigation commands; saved data is not migrated destructively.

The v1 bridge uses `relay.ready`, `relay.context`, `relay.navigate` and
`relay.navigation`. Navigation supplies source, command ID, section ID, optional
`highlightIds` and `viewState:{query?,filters?,language?}`. IDs come from the
published Report. Applied means those targets rendered. A null source clears
previous document context while preserving app context. `capabilities.search`
also keeps Relay's Library control for a v2 app.

An app that cannot serve the protocol itself can sit behind an external adapter
registered by address. See [Setup](../README.md#setup) for registration.

## Built-in Files app

The Flutter backend registers `files`, beside Browser, for read-only access to
the folders listed in Settings (`GET`, `POST {path}` and
`DELETE ?path=` on `/api/settings/folders`, saved as `folders.json` in
`RELAY_DATA_DIR`; a damaged file shares nothing and is logged). A folder
reached by several paths is kept once. Like App servers, these routes answer
only requests whose Host is one of Relay's own addresses, so a page rebound to
Relay's address cannot use them. Changes that carry another site's Origin are
refused too. A folder must be an existing directory given as an absolute WSL
path. Its operations are `files.list`, `files.search` (names, plus words in the
first 1 MB of each text file and in the text of each PDF, stopping at 50
matches or after 10 seconds, with a note when it stops early) and `files.read`
(pages with `nextOffset`; a PDF gets 30 seconds). Readable files are plain text
by extension and PDFs up to 20 MB. PDF text comes from `unpdf` in a worker
thread, one per search or read, ended at the deadline or on Stop, so a large
PDF does not stall the service. Other files are listed by name only. It has no
view, so the app picker leaves it out (`hasView: false` in `/api/config`). A
chat with no bot can use every registered app, Files included; a bot can use
Files only when it is among the bot's allowed apps.

The service enforces the rules, not the model instructions: a path counts only
when its real location, after symlinks, is inside a shared folder; names that
start with a dot below a shared folder are refused; and `RELAY_DATA_DIR`
(which holds the provider settings), `RELAY_PROVIDER_DIR`, any
`*_API_KEY_FILE` and every folder holding a `relay.sqlite` (another Relay's
records) stay out even inside a shared folder, and are not listed. A refused
path gets the same answer as a missing one. Nothing is written or run. Shell
and code tools still need the separate executor boundary.

## Standard fit

This is **Relay protocol v2, not MCP compatibility**. Operation descriptors use
familiar MCP shapes. An isolated probe with MCP SDK 2.4.0 and MCP Apps 2.0.4 verified
discovery, structured calls, progress, cancellation and view-tool calls. MCP could
carry operations; Relay-specific visible-render, device and manual-change semantics
would still be needed. The [MCP Apps stable specification](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx)
defers external app URLs and state persistence, while Relay uses persistent,
independently hosted websites. No MCP dependency or speculative adapter is added.

Types are in [shared/types.ts](../shared/types.ts); trusted agent schemas are in
[server/agent-tools.ts](../server/agent-tools.ts). App JSON never installs
executable OpenCode plugins or grants shell/file access.

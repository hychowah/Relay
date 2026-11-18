# Plugin protocol slice

Implementation is complete in source. The [phase record](phases/phase-02/README.md)
holds verification and runtime limits; broader Phase 02 work remains open.

## Design

**Goal:** Treat each independent app as a plugin whose operations and visual workspace Relay can discover and coordinate, without requiring every screen to be a readable Report. Preserve live v1 Research, saved evidence and commands.

**Options:**

1. **MCP server plus MCP Apps.** Apps expose standard tools; Relay supplies MCP clients and presentation extensions. Common interface: tool discovery/calls plus an app-view bridge. MCP addresses operation exchange, but persistent independently hosted app views still require Relay-specific coordination.
2. **Small Relay HTTP contract plus browser bridge.** Apps describe operations and accept calls; their existing websites remain primary views. Common interface: discover an app, invoke its named operation, present an app-owned view. Report evidence is optional.

**Chosen:** Option 2. SDK fit evidence shows MCP would leave the same presentation work while adding transport dependencies to the current stdlib Research server. Call this **Relay protocol v2**, explicitly not MCP-compatible.

Keep three boundaries:

- **HTTP integration:** validates remote envelopes, contains transport/version differences and exposes app descriptions, operation discovery/calls and an initial view descriptor. Retain v1 search/read/view support because released integrations and stored data use it.
- **Operation execution:** checks bot access, records real progress and invokes app operations using the run’s `AbortSignal`. It knows no app-specific arguments.
- **Presentation:** owns device/tab context, supersession and acknowledgement. Apps own routes, targets, rendering and animation.

Concrete outline:

```ts
interface Operation {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>; // JSON Schema
}
interface OperationResult {
  data: unknown;                      // JSON value
  sources?: Source[];
}
interface ViewIntent {
  viewId: string;
  state?: Record<string, unknown>;    // app-owned JSON
  targetIds?: string[];               // stable semantic identifiers
  source?: Source;                   // evidence, when applicable
}
```

`GET /_relay/manifest` supplies `{version:2,id,name,description,instructions?,view:{path:"/_relay/view"}}`.

`GET /_relay/operations` supplies `{operations:Operation[]}`. Discover only the selected or explicitly requested allowed app.

`POST /_relay/call` accepts `{operation,arguments}`. NDJSON responses contain `{type:"progress",message,...}` followed by exactly one `{type:"result",result}` or `{type:"error",message}`. Validate envelope/schema shape at the integration boundary; the app validates operation arguments and semantics. Do not add writable operations in this slice.

Agent tools: `app_discover(appId)`, `app_call(appId,operation,arguments)`, `app_present(appId,intent)`. Keep existing v1 tools for existing callers.

The authenticated browser bridge exchanges ready/context, present, cancel and presented messages. Context contains `viewId`, optional state/source/selection and a generation. Presentation includes `commandId`, expected generation and intent; acknowledgement reports `applied|stale|failed` with resulting context. `applied` means targets rendered and requested animation finished. Manual interaction supersedes pending automation.

Transport failure is unavailable; invalid app replies are protocol failures; operation errors remain app errors. Stop aborts requests and invalidates pending presentation. Describe upstream cancellation as cooperative; do not claim remote work stopped merely because Relay disconnected.

## Plan

1. **Operation boundary.** Add v2 types/HTTP handling and discovery/call tools. Preserve v1 adapter behavior and evidence storage. Interface comments explain discovery scope, JSON ownership and cancellation guarantees.
2. **Presentation boundary.** Add source-optional typed presentation commands, normalizing old stored commands when read. Open v2 home views without `readReport`. Extract a reusable browser bridge with the generation/acknowledgement rules above.
3. **Independent implementations.** Extend Research source while retaining its v1 endpoints. Add an unrelated fixture such as a room-layout viewer with `layout.inspect` and semantic furniture targets. Both use the bridge; registering either requires no app-specific Relay core branch.
4. **Focused proof.** Test operation discovery/call/progress/abort, non-Report presentation, render acknowledgement/manual supersession and old saved-command behavior. Run Research source fixtures and browser checks on separate ports. Update the contract and master-plan Next.

**Deletes:** Replace Report-mandatory native-view assumptions in `server/app.ts`, `web/App.tsx` and v2 instructions in `server/harness.ts`; replace corresponding expectations in `tests/http-integration.test.ts` and `tests/workspace.test.ts`. Rewrite superseded universal-v1 claims in `docs/integration.md`. Preserve actual v1 compatibility branches and saved records.

## Resolved probes

The [phase evidence](phases/phase-02/README.md) records native render completion,
HTTP cancellation and cross-origin shared-helper loading. Separate-port fixtures
and ignored scratch were used; no live Research publication was replaced.

The render probe exposed partial navigation before a failed highlight. The shared
bridge therefore reads app-owned `getContext()` at initialization, manual input
and failed presentation. Failed results carry the actual visible context and
advance the generation without reporting applied. This replaces a fixed initial
context value and prevents the next question from describing the previous page.

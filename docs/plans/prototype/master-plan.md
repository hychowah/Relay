# Relay prototype master plan
Status: active

## State and authority

Requirements reflect the user's 2026-11-15 prototype decisions and 2026-11-18
client choice. Phase 01 remains active. The user prioritized Research Web and an early Phase 03 slice: normal chat, reusable
bots, shared preferences, separate bot memory and conversation forwarding.
Those features are implemented; verification evidence and remaining limits live
in the [phase record](phases/phase-01/README.md).

A saved requirement does not independently authorize accessing credentials,
changing another service or deploying changes.

## Purpose

Build a personal, general agent workspace similar in experience to the user's
Grok bot, with visual app surfaces the agent can show and control. It connects
independent apps through a small integration contract. It must extend beyond
backtesting, stock research, and humanoid research.

Build the smallest useful prototype for the MacBook in Flutter. Keep the web
page available on Windows and user records recoverable through documented
storage and export.

## Agreed requirements

| ID | Required behavior |
| --- | --- |
| R01 | Flutter on the MacBook is the main client. Maintain chat and app opening in the React browser fallback on Windows. Desktop chat is adjustable on the right, initially 30% wide. Native Android is the long-term goal, with chat overlaid on the app. Phone work is deferred; see the [Flutter Windows test build](../flutter/windows.md). |
| R02 | Connect apps the user develops. Each owns its screens, can use its own framework, and remains independently usable. |
| R03 | Register an app by configured address and integration information. Apps can run on the same machine or reachable remote hosts. |
| R04 | A conversation can span apps and remain open when the user switches apps. |
| R05 | Include an API-key-based agent, configurable provider/model connections, and DeepSeek as the first provider. |
| R06 | Provide a proper harness: tool execution, context management, persistent conversations, searchable logs, and recovery of recorded state. |
| R07 | Automatically provide the active app, document/result identity, filters, and selected content as question context. Retrieve further content when needed. |
| R08 | Read/search app information and open or adjust app views. Navigation applies only to the device that initiated the request. |
| R09 | Share personal preferences across projects and maintain separate project memory. Automatically remember useful preferences and decisions. |
| R10 | Provide in-app memory inspection, editing and deletion, plus conversation/log access. Support explicit remember/forget requests. |
| R11 | Let apps provide instructions and reusable skills. Start with one main agent; helper agents are a later capability. |
| R12 | Continue work while the browser is closed or disconnected, provided the host remains running. Reconnecting exposes progress and results. |
| R13 | Support optional file access, web access, and terminal capabilities configured per project. |
| R14 | Show existing app views and generate new tables, charts, documents, or interactive views. Save generated outputs for reopening. |
| R15 | Run the workspace/harness in Docker on WSL. Use the user's existing Tailscale connection for other devices. |
| R16 | Separate agent command execution from service credentials and persistent records. Limit shared files, network access, and resources. |
| R17 | Start, stop and watch local app servers from Relay, with the host's service manager keeping them running. See the [app servers plan](../app-servers/master-plan.md). |
| R18 | Preserve an extension path for running backtests and other app actions later. Initial integration emphasizes reading, navigation, and visualization. |
| R19 | Provide normal chat and reusable bots with individual objectives, scope, allowed apps and memory. Share personal preferences; keep bot knowledge separate. Forward a chosen conversation with a handoff and recoverable source messages. |
| R20 | Show meaningful app actions while the agent works: search/results, selected evidence and the final focused view with field highlights. Progress reflects actual operations. Keep chat expandable and Stop available; preserve direct manual app use. |
| R21 | Each Mac Browser tab can route through WSL's NordVPN. See the [Browser VPN plan](../browser-vpn/master-plan.md). |
| R22 | Read-only shared folders, form filling: [decision 0003](phases/phase-01/decisions/0003-shared-folders-and-form-filling.md). |

A project is proposed to group conversations, memory, outputs, and links to
relevant app resources. One project may use several apps; one app may serve
several projects. Project data and conversations are shared across devices;
open tabs and layouts remain device-specific. The conversation last opened
on any device opens on each device when it starts or returns to the front, and
a device can open a copy of another device's last saved tabs.

## App integration expectations

An app describes its identity, integration version, address, availability, and
supported capabilities. It supplies:

- View identities and ways to open a particular resource or section.
- Current user-visible context, with stable record/version references when
  the app has them.
- App-defined operations returning useful data and optional source references;
  document search/read is a capability rather than a universal requirement.
- Explicit view commands and their success/failure results.
- App-specific instructions and skills, loaded when relevant.
- Optional future work operations with observable status and cancellation.

The host must have no special cases for ticker symbols, strategies, or robotics.
The same underlying app operation should serve a manual control and an agent
request where both perform the same task.

Adding a fourth unrelated example app must require its own integration and
registration, with no app-specific edit to Relay core. The implemented boundary
is defined in the [integration contract](../../integration.md).

## Representative behavior and acceptance

**App-led research.** Open Research Web, expand chat and ask for hands with more
than 12 DoF below USD 3,000. Desktop chat stays beside the app. The existing narrow layout collapses chat.
Show selected meaningful steps, as the user chose, rather than every background
read. Present relevant products and highlight the displayed price and DoF on the
chosen model. Keep qualifications and unknowns visible; a capped text search is
not proof of an exhaustive count. The compact panel reports real progress and
completion; expanding it recovers the conversation. This first slice reuses native
navigation, adds app-owned field targets and exposes published catalog evidence.
It does not add a generic query language, currency service or cursor playback.

Completion evidence: synthetic question through the real harness opens the app,
retains desktop chat, presents meaningful navigation and highlights both fields. Check
manual intervention, Stop and reopening chat. Defer physical phone checks. Verify the
Research Web page itself after source changes, separately from model answer quality.
This slice extends Phase 01 and covers R01, R07–R08 and R20; existing bot/memory
behavior remains available.

**Research question.** Ask for risks in the latest research for a selected
company. The agent finds the appropriate saved version, answers with references,
opens that same report, and focuses the relevant section. Record whether the
view command succeeded; a requested navigation alone is not success.

**Current-view question.** Select content or a saved result and ask "explain
this." Capture the originating device/tab context with the request. If the
user changes views while work continues, handle stale view commands explicitly
rather than acting on an unrelated current selection.

**Across apps.** Ask a question using research and a saved backtest. Fetch
evidence through both integrations and open the associated views side by side
on desktop. Retain source identities in the answer and any generated comparison.
The future phone layout should provide equivalent access.

**Memory.** Remember a useful preference or project decision. Inspect the saved
item, its scope, source conversation, and updates. Edit it, then observe the
corrected value in a new conversation. A forgotten item must not be silently
re-created solely from the same old conversation. Treat changing app facts as
information to refresh from the app, not permanent truth.

**History and context.** Search/reopen old conversations, inspect messages,
supplied app context, tool requests/results, references, and outputs. Context
compaction can summarize working history while retaining the recorded original.
Log available model usage and timing without recording secrets. Exact retention,
redaction and deletion mechanics are proposed technical design details.

**Generated output.** Build a chart or comparison from retrieved data, save it
with its inputs/source references, and reopen it. Run generated code in a
restricted execution environment. Render generated interactive HTML in a
restricted browser preview with no inherited app credentials.

**Disconnect/restart.** Close the browser while a task runs; the host continues.
Reconnect to see the task's actual status and results. Persist conversations,
memories, and artifacts across service/container recreation. Following a host
crash, show completed/interrupted status accurately; do not assume arbitrary
commands can be replayed safely. Automatic crash resumption needs evidence.

**Unavailable app.** An app can be disconnected or incompatible without breaking
the conversation or other apps. Report unavailable data and operations explicitly.

## Isolation and persistence

Use a small Docker Compose deployment in WSL. Inspect existing Docker tooling
before choosing Docker Engine inside Ubuntu or Docker Desktop WSL integration.
Use one installation; do not assume a new engine is necessary.

The workspace service holds provider credentials and persistent user records.
Agent-generated commands execute separately with selected inputs and a dedicated
output area. The executor must not receive broad home/Windows mounts, provider
credentials, or an unrestricted Docker control socket. A trusted mechanism must
control executor startup and mounts; the agent cannot select arbitrary host
mounts or bypass restrictions by supplying its own runtime flags.

Use non-root execution, resource limits, explicit filesystem access, and
restricted network paths appropriate to enabled tools. App API permissions
must be enforced outside model instructions: filesystem isolation alone does
not prevent a writable API from altering real data.

Keep the existing Tailscale access path and verify the actual location of its
listener before configuring forwarding. Publish only the required workspace
entry point. App resources and the browser-side views must also be reachable
from each client device. Verify phone connectivity when its trial is requested.

Containers reduce impact but share a kernel and are not an absolute isolation
guarantee. Preserve the distinction between server command isolation and
browser preview isolation.

Store conversations, memories, app registrations, and outputs in explicit
persistent storage outside disposable container layers. Document backup/export
and recovery for a possible rewrite. User records are never engineering scratch.

## Selected foundation

Flutter owns new client features. The React/TypeScript page supports chat and
opening apps in a browser. Node 24 and SQLite own the service and records.
OpenCode 2.3.0 supplies the model/tool loop and compaction without a fork.
The [runtime decision](phases/phase-01/decisions/0001-agent-runtime.md) records the
bounded comparison with DeepSeek Harness. Earlier FastAPI/PydanticAI suggestions
were provisional. Reopen the runtime choice only for a demonstrated requirement
or maintenance problem, not for another framework survey.

Existing apps retain their own stacks and expose the app-owned HTTP/view bridge
in the [integration contract](../../integration.md). Docker Compose, WSL,
Tailscale and DeepSeek-first configuration remain the agreed deployment choices.
Executable agent tools require a separate isolation boundary before activation.

Implement shared client rules in the service. The [client platform decision](phases/phase-01/decisions/0002-client-platform.md)
records the platform evidence and limits. The [Flutter plan](../flutter/master-plan.md)
owns client status.

## Phases and requirement coverage

### Phase 01 — Harness selection and one useful app interaction

Prerequisites: this plan; read-only reference inspection; private fixtures for
initial tests. Inspect the environment and perform the bounded harness probe.

Deliver the selected foundation, basic client workspace, DeepSeek configuration,
persistent chat/tool records, device-scoped page context, and an Analysis Web
read/navigation integration. Establish container boundaries before executable
agent tools are enabled.

Exit evidence: on the MacBook, ask about a known report, get a sourced answer
and open its correct section. Verify chat and opening apps in a Windows browser.
Demonstrate chat surviving browser closure and persistent records surviving container recreation. Show working
Tailscale access when live setup is available. Record model and harness versions,
real-provider status, and any fixture-only evidence.

Covers R01, R05–R08, R12, R15; establishes the R16 boundary.

### Phase 02 — Generic multi-app workspace

Prerequisite: Phase 01's chosen integration contract and complete interaction.

Integrate Backtest Web and Humanoid Research Web for saved-information access
and view control. Add registration/availability, tabs/split views, cross-app
questions, and app instructions/skills.

Exit evidence: all three apps remain independently usable; one conversation
uses evidence from two apps and shows both views; a fourth unrelated fixture
app joins through registration/integration only; one unavailable app leaves
others working. Check simultaneous MacBook and Windows browser sessions for isolated navigation.

Covers R02–R04, R07–R08, R11 and the current R01 desktop layout.

### Phase 03 — Memory and inspection

Prerequisites: persisted conversations and project identity.

The user prioritized a bot/conversation slice before further app expansion:
editable bot profiles and app permissions, shared/bot memory,
scoped history retrieval, explicit forwarding and task checkpoints. Use the
existing SQLite store and OpenCode compaction. Project grouping remains a later
part of this phase; bots do not replace projects. Source-bound forwarding grants
only messages present when forwarded. No vector service or consolidation worker
is needed for this slice. Relay enforces scopes; the model selects useful notes.
Semantic retrieval, background consolidation and automatic crash continuation
require demonstrated demand. Reference patterns came from [Anthropic memory research](https://www.anthropic.com/research/components-of-agent-memory),
[Claude Code memory](https://code.claude.com/docs/en/memory),
[Letta conversations](https://docs.letta.com/concepts/conversations), and
[LangGraph memory](https://docs.langchain.com/oss/python/concepts/memory);
these are not new dependencies.

Implement automatic shared/project memory, inspection/edit/delete, source
links and updates, conversation search, and inspectable tool activity.

Exit evidence: demonstrate remembering, cross-conversation retrieval, correcting,
and forgetting; test project boundaries and shared preferences; reopen full
history after context compaction; restore records from documented backup/export.

Covers R06, R09–R10 and R19.

### Phase 04 — Generated outputs and general tools

Prerequisites: app access, persistent outputs, and verified isolation boundaries.

Provide project-configured file/web/terminal tools and saved generated tables,
charts, documents, and restricted interactive previews. Extend task status,
cancellation, and reconnect behavior for these operations.

Exit evidence: generate and reopen an evidence-linked comparison; verify that
commands cannot read unshared files, service secrets, or control the container
runtime; test configured network limits and browser preview isolation; close
the interface during execution, then reconnect to the real result/status.

Covers R13–R14, completes R12 and R16.

R18 remains a later extension. Android and Windows packages, helper
agents, new backtest execution, live app-data editing, scheduling, public sharing,
and a third-party marketplace are outside the first prototype commitment.

## Other repositories

The connected apps live in their own repositories. Their locations and operating
notes are in the local machine notes named in AGENTS.md. A source repository is
not proof of live readiness: consult the
[phase evidence](phases/phase-01/README.md) before claiming an integration is
verified, and follow each repository's source/runtime rules when making changes.

External references inspected during planning:

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
- [DeepSeek tools](https://api-docs.deepseek.com/guides/tool_calls/)
- [OpenCode providers](https://opencode.ai/docs/providers/)
- [OpenCode plugins](https://opencode.ai/docs/plugins/)
- [OpenCode compaction](https://opencode.ai/docs/compaction/)
- [Docker WSL](https://docs.docker.com/desktop/features/wsl/)
- [Docker security](https://docs.docker.com/engine/security/)
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)

Recheck reference versions; some OpenCode server/SDK links redirect to V1
documentation, and DeepSeek Harness was in preview when inspected.

## Implementation readiness and handoff

The [README](../../../README.md) holds operating instructions and current
configuration behavior. The phase record holds verification; this plan holds
requirements and the next work. Keep those responsibilities separate.

Provider credentials belong in private service storage outside source control.
An external key file and UI-managed settings are supported configuration paths.
Do not ask the user to paste it into chat or print it. Confirm the permitted
test usage/spend before a live benchmark; no spending budget was specified in
planning. Missing live credentials do not block source work and fixture tests,
but must remain an explicit verification gap.

Follow the original app repositories' live-runtime and source rules. Initial
checks use private fixtures. Reading a document here does not authorize
restarting another service, changing live research, broadening tailnet access,
or deploying changes.

Create phase records only as needed. Update evidence and Next as work advances.
After all required exits pass, consolidate operational/contract docs and perform
records close-out. Do not label the prototype complete based on source alone
while required Mac/browser, live-provider, or integration checks remain missing.

The configured DeepSeek token is authorized for testing. Live requests require
the host's NordVPN connection unless that check is off. A DeepSeek reply
and Claude and DeepSeek model discovery passed.
Claude replies remain unverified; the user reports OpenAI works. See the [provider record](phases/phase-01/working/provider-connections.md).
The [Phase 02 evidence](phases/phase-02/README.md) covers Research and Room on
protocol v2, with v1 saved evidence retained. The [presentation evaluation](phases/phase-02/working/presentation-explanations.md)
records explanation and restoration checks. Docker recreation and second-device
Tailscale checks for Relay and Research Web remain open prototype exits.

## Next

Defer read/write effects to the first write, access scopes and versioned migrations to projects, and network policy injection to the Docker executor. Revisit server acknowledgement checks if bridge ownership changes, and new tool statuses or a run-oriented harness when lifecycles fall short.

The [Flutter handoff](../flutter/master-plan.md#next) covers installing and reviewing Stable 0.0.21 on the Mac, with its checks for tab restore, the transcript pane and the app list refresh, and the split view. It also lists Mac checks for the capture animation, the Browser's PDF viewer, highlights and Stored data, which are in Stable since 0.0.17, published on 2026-11-23. The backend, last deployed at `92f7bc5` on 2026-11-26, connects the Browser on the Relay port, not 3251: builds older than 0.0.17, and a Windows app built before `acad2d8`, cannot read pages or transcripts. Windows checks wait until the user returns to Windows.

The [coding sessions plan](../coding-sessions/master-plan.md) hands requests to Claude Code or Codex sessions through a coding app in its own project. The [shell refactor](../shell-refactor/master-plan.md) is complete; the coding plan's Next holds steps.

Phase 1 of the [app servers plan](../app-servers/master-plan.md) (R17) is deployed and in Stable 0.0.18; its Mac check is next.

1. Verify a sourced two-app question on the user's saved records from the Mac.
   Both stock adapters have run as local services, registered with the live
   Flutter backend, since 2026-11-19; search through Relay returns saved
   records and the user opened both apps on the Mac. See the
   [Phase 02 evidence](phases/phase-02/README.md).
2. Evaluate sourced Research Web answers, memory correction and forgetting, and retrieval of old details after compaction with the configured real provider.
3. Establish the Compose executor boundary before enabling any file-writing, terminal or code tool.
4. Serve the web page from the app backend so both clients share one set of records.
5. Defer the Android device trial and phone work until separately requested.
6. Have Analysis Web and Backtest Web serve the Relay protocol from their own projects, then retire the adapter project.

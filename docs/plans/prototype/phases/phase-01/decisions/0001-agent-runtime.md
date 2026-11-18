# Agent runtime: OpenCode 2.3.0

Select the pinned OpenCode CLI and plugin packages, without a fork. Relay owns
the browser, application integrations and user-facing records; OpenCode owns
the model/tool loop and session context.

| Candidate | Evidence | Cost for Relay |
| --- | --- | --- |
| OpenCode 2.3.0, MIT | HTTP session API, tool/context hooks, persisted messages, cancellation, compaction, skills and events | Small private process adapter and one trusted plugin |
| DeepSeek Harness 0.2.2-rc.1 npm preview, MIT | Native DeepSeek handling, streaming, persistent sessions, cancellation and SDK profiles | Cordis/profile composition and stdio JSON-RPC bridge; minimal SDK still enables full-access shell by default |

Inspected OpenCode source at `d432a06b9c07bab0be4e8d642173b1cb14137f11`:
[session protocol](https://github.com/anomalyco/opencode/blob/d432a06b9c07bab0be4e8d642173b1cb14137f11/packages/protocol/src/groups/session.ts),
[events](https://github.com/anomalyco/opencode/blob/d432a06b9c07bab0be4e8d642173b1cb14137f11/packages/protocol/src/groups/event.ts),
[plugins](https://github.com/anomalyco/opencode/blob/d432a06b9c07bab0be4e8d642173b1cb14137f11/packages/plugin/src/README.md).
The server/SDK website links still redirect to V1 docs; implementation follows
the tested V2 API. DeepSeek Harness source at
`39163dd30f703a79079e2d2446545cff3c453738` identifies itself as newer rc.3 development:
[minimal profile](https://github.com/deepseek-ai/deepseek-harness/blob/39163dd30f703a79079e2d2446545cff3c453738/packages/bundle/sdk-minimal/README.md),
[SDK](https://github.com/deepseek-ai/deepseek-harness/blob/39163dd30f703a79079e2d2446545cff3c453738/packages/sdk/client/README.md).
No broad framework survey or custom agent loop is needed for this slice.

The initial selection probe ran the pinned executable through a synthetic
streaming read/navigation/answer flow with three app tools. It verified context
and citations across restart, active cancellation and accurate pending navigation.
The [phase record](../README.md) holds current verification and remaining
live-provider and realistic-history limits as the tool surface grows.

OpenCode events are volatile. Relay polls persisted messages and snapshots for
reconnect, avoiding a second event persistence system. Token usage is converted
from cumulative session totals to per-run values. Original user context and
tool results remain in Relay's database regardless of later harness compaction.

Disable instruction/skill discovery and all built-in tools. Keep a final tool
allowlist hook because built-in registration order alone is insufficient.
Trusted harness/plugin code receives a local gateway token; real provider keys
remain in Relay. This is not an execution sandbox. Shell/file/generated-code tools remain absent until a separate executor
is implemented. Pin upgrades and repeat the focused runtime test when changing
OpenCode versions.

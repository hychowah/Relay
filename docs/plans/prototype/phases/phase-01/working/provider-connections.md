# Provider connections and VPN prerequisite

2026-11-17. The user requested direct Anthropic Console support, preservation of
DeepSeek, a structure suitable for OpenAI later, and NordVPN checks before API key
use from this WSL host. OpenAI was added on 2026-11-23; see [OpenAI](#openai).

## Design and review

The strategic design review accepted independent saved connections, native
OpenCode adapters and service-owned transport definitions. It requested two
changes: one provider/model capability decision, and a network prerequisite at
the outbound request boundary rather than only in UI/startup/prompt admission.
The user accepted both and requested implementation.

`ProviderSettingsStore` owns selected mode, independent connection settings
and private keys. Browser status remains
redacted. Blank keys reuse only the selected provider's saved/external key.
Each provider definition supplies its adapter, endpoint, authentication format,
display name, default model, token limits and models with thinking effort.
The harness alone maps a stored conversation preference to supported options.

Relay starts the live gateway and gives the harness its loopback address and a
random token. The provider key stays with the service. The gateway fixes the destination from
service configuration, checks NordVPN for every request, and only then attaches
the selected provider key. Follow-up tool calls, retries and compaction use this
same endpoint. Redirects are rejected; streaming and cancellation are preserved.
Disconnected, missing, failing or unrecognized NordVPN status blocks requests with
an actionable error. Local fixtures bypass the gateway and VPN requirement.
Saving settings does not call a provider or require a VPN connection.

The model picker reads each provider's model-list API through the same guarded
outbound request function. Saved keys load automatically; draft keys require
**Load models**. Discovery neither persists a key nor changes the active
connection. Anthropic pagination is handled server-side; each page checks the
VPN. Provider changes/key edits cancel stale lookups. No model cache, new
provider framework or additional dependency was introduced.

## Network evidence and limits

Read-only checks found the native WSL NordVPN CLI reporting Connected, firewall
and routing enabled, and **Kill Switch disabled**. Relay shares the WSL network
namespace; environment-proxy mode is not enabled. Routes for resolved DeepSeek and
Anthropic destinations use `nordlynx` through policy routing table 205. The ordinary
WSL interface also has a default route. No VPN, firewall or routing setting was
changed.

A fresh status check is a prerequisite, not an OS egress guarantee: a disconnect
between check and send, or during a stream, is not prevented by this code. The
existing disabled kill switch remains disabled. Live Docker use needs its own
verified VPN status/routing arrangement; no host-control mounts or speculative
container networking were added.

## Verification

- Production build and all 75 tests passed. Provider tests cover key separation,
  external-key ownership, legacy migration and provider-scoped effort validation.
- The actual OpenCode Anthropic adapter completed a local synthetic Messages/tool
  round trip in an existing conversation through the gateway. Both model calls
  invoked the status check. Changing the synthetic CLI status to Disconnected
  blocked the next call and retained the actionable NordVPN error in run state.
- Gateway tests cover both authentication formats, repeated calls after disconnect,
  unknown/missing/failing status probes, key replacement, streaming/cancellation
  and rejection of redirects. They use local fixtures and no real VPN disruption.
- One user-authorized real DeepSeek request succeeded through the gateway and
  returned the exact requested test phrase: 3,041 input tokens, 3 output tokens,
  no reasoning tokens. The test used isolated harness storage and no user content.
- Three model-discovery tests cover provider authentication/pagination, VPN
  blocking and sanitized failures, and draft-key isolation without saving or
  switching. Existing gateway tests still cover streaming and redirects.
- Relay was restarted with no active runs. Live model discovery succeeded for
  both configured keys: 15 Claude models and 2 DeepSeek models. Claude key
  authentication is now verified for discovery; a real Claude answer remains
  unverified by this work. The active Claude Sonnet 5.5 connection was preserved.
- Browser checks covered real provider lists, draft keys using intercepted
  synthetic responses, cancellation, stale responses after provider switching,
  and no horizontal overflow at 390px width. Tests did not save settings.
- Records and whitespace checks passed. No commit or push; VPN settings unchanged.

## OpenAI

The user asked for OpenAI API key support on 2026-11-23. OpenAI is a third
saved connection on OpenCode's native `openai` adapter (Responses API), using
the same gateway, Bearer key and per-request NordVPN check. Discovery reads the
unpaginated `/v1/models` list, which gives IDs only. Image input is on. The
default is `gpt-6.2-sol`, the mid-price model in OpenAI's current list. Like
Claude, OpenAI has no thinking-effort control and runs on OpenAI's default; its
documented values differ by model and none was checked live. The 200,000-token
context limit matches Claude to keep each step's cost bounded. OpenCode sends
OpenAI no `max_output_tokens`, so the 8,192 output limit only shapes compaction;
reasoning counts against any cap and OpenAI advises reserving 25,000 tokens.

OpenAI's model list includes embedding, speech and image models. After loading
models, the web page keeps the current model if listed, then the provider
default; Flutter keeps the saved or default model the server sends. Otherwise,
for every provider, the model stays unchosen and Save is disabled; neither
client picks the first entry.

OpenCode's built-in OpenAI plugin switches the connection to WebSocket unless a
transport is set. The gateway relays HTTP POST only, so the harness sets
`transport: "http"` for every provider. Before that, a synthetic run showed one
refused WebSocket attempt at the gateway and an HTTP fallback; nothing reached
the upstream.

Evidence: in an existing conversation, the OpenAI adapter completed a synthetic
tool round trip with an image through the gateway. Both model calls passed the
VPN check, the key stayed out of OpenCode's configuration, and a Disconnected
status blocked the next call with the NordVPN message. Request bodies for all
three adapters carry no `transport` field. Discovery tests cover OpenAI
authentication and VPN blocking. Model-choice tests use an OpenAI list with
non-chat models first. Flutter's runs the dialog and fails with the old
first-entry fallback; the web test covers `pickListedModel`, not the rendered
dialog. The full suite (124 tests), the build, Flutter analyze and
all 95 Flutter tests passed.

Limits:
- Rollback: a backend older than this change fails to start while
  `provider.json` holds mode `openai`. Switch the provider away from OpenAI
  before rolling back.
- Screenshots are allowed for every OpenAI model; a model without image input
  fails at OpenAI.
- Flutter builds up to Stable 0.0.18 do not list OpenAI. After OpenAI is chosen
  from the web page, their provider settings may show an empty choice.
- Like the Claude test, the OpenAI round trip depends on polling time and fails
  if `RELAY_VPN_CHECK=off` is set while tests run.

Unverified without a real key: any real OpenAI request or model list, that
`gpt-6.2-sol` is available to the key, the order of `/v1/models`, stateless
storage with encrypted reasoning on the chosen model, real stream and error
shapes, and whether OpenAI's addresses route through `nordlynx`.

## Next

Refresh Relay to use the model picker. A real Claude conversation is the
remaining provider-readiness check. For OpenAI, after merge and deployment,
save a key in Model connection, load models and send one short reply; this
needs the user's key and approval of the small spend. Treat the documented
precheck and OS egress guarantee separately; the observed disabled kill switch
has not been enabled by this change.

# Provider connections and VPN prerequisite

2026-11-17. The user requested direct Anthropic Console support, preservation of
DeepSeek, a structure suitable for OpenAI later, and NordVPN checks before API key
use from this WSL host. OpenAI is not implemented in this slice.

## Design and review

The strategic design review accepted independent saved connections, native
OpenCode adapters and service-owned transport definitions. It requested two
changes: one provider/model capability decision, and a network prerequisite at
the outbound request boundary rather than only in UI/startup/prompt admission.
The user accepted both and requested implementation.

`ProviderSettingsStore` owns selected mode, independent connection settings,
private keys and migration from the original flat file. Browser status remains
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

## Next

Refresh Relay to use the model picker. A real Claude conversation is the
remaining provider-readiness check. OpenAI remains
future work. Treat the documented precheck and OS egress guarantee separately;
the observed disabled kill switch has not been enabled by this change.

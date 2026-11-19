# Coding sessions from Relay
Status: active

## Goal

From a Relay conversation, hand a written request to a Claude Code or Codex
session in one app's repository, supervise that session inside Relay, and ask
the Relay agent how it is going. The user asked for this on 2026-11-19 and
chose the decisions below.

A typical use: the user finds a paper in the Browser, discusses it with the
Relay agent, and sends a request to the Research Web repository. A coding
session there adds the paper under that repository's own rules.

## Agreed behaviour

| ID | Required behaviour |
| --- | --- |
| C01 | The Relay agent prepares a request: the target repository, Claude Code or Codex, and the request text with its links. |
| C02 | Nothing starts until the user reads the request, edits it if needed and presses Start. The Relay agent cannot start a session. |
| C03 | The session opens beside the chat, where the user approves its steps. |
| C04 | The session stays linked to the conversation and can be reopened from it. |
| C05 | On request, the Relay agent reads the session and reports its state and result. |
| C06 | The Relay agent can prepare a follow-up message; the user confirms each one before it is sent. |
| C07 | Commits, merges and server restarts happen inside the coding session, with the user's approval there and under that repository's rules. |

Not included: the two agents talking without the user, the Relay agent acting
when a session finishes, the Relay agent answering approval requests, and a
session screen built into Relay.

## Approach and boundaries

The user's existing session tool already starts, shows and steers Claude Code
and Codex sessions, and offers the same actions to programs. Relay reuses it
through a small coding app in its own project. That app speaks Relay's
[integration contract](../../integration.md) on one side and the session tool's
interface on the other. Relay core has no coding-specific code.

The Start and Send controls are on the coding app's own screen. The Relay agent
reaches the app only through published operations, and no operation starts a
session or sends a message. This keeps C02 and C06 true without a confirm step
in Relay.

The repositories a request may target are local configuration of the coding app.
The folder never comes from the model or from a page. Page text is untrusted,
so the user sees the exact text that will be sent. Each target's approval mode
is local configuration too. It defaults to asking before each step, and the
review screen shows it before Start.

Coding sessions run outside Relay's harness with the approvals the session tool
already enforces. This plan gives the Relay agent no file or terminal tool, so
the prototype's executor boundary (R13, R16) is unchanged.

## Phases

### Phase 0 — Probe

Done on 2026-11-19 against the local session tool, with one real Claude Code
session in a scratch folder: sign-in, start in a chosen folder, send a request,
see the turn end, read the reply, see an approval request, stop and archive.
The requested file was not written without approval. The tool's page sends no
header that forbids framing. Showing that page inside the Mac client is unproven.

### Phase 1 — Handoff

The coding app with its targets, draft requests, the review screen with Start
and Discard, the started session shown on that screen, and a draft's status.
Covers C01–C04.

Done when: with a stand-in for the session tool, a draft starts nothing, Start
sends the edited text to the configured folder, and a request from another site
cannot start a session. Then, with live registration approved by the user, one
request to a scratch repository starts only after Start in the Mac client and
reopens from its conversation.

The stand-in part passed on 2026-11-19 in the coding app's project: seven tests
cover those three points, a start that happens once, the three start outcomes
and requests addressed to a foreign host. Relay's app loader accepted the app
and refused an unpublished start operation. The live part is open: no real
session has been started through the app, and it is not registered.

### Phase 2 — Check-back

Reading a session's state and result for the Relay agent, and follow-up drafts
the user sends from the screen. Covers C05–C06.

Done when: the agent reports a session correctly while it runs and after it
ends, and a follow-up reaches the session only after the user sends it.

### Phase 3 — First real use

Add one paper to Research Web end to end, following that repository's rules.
Covers C07 in practice. Read those rules before this phase starts.

## Next

1. Ask the user to approve the live setup: the coding app as a local service
   with the real targets, its registration as a trusted app (the framed session
   page needs forms, which the default frame restrictions block), and a forward
   for its port. At registration, update the integration contract's statement
   that current apps expose read-only operations: preparing a draft saves one.
2. Check the Mac client: one request to a scratch repository, the session
   screen inside the app view, its sign-in after a restart, and its layout at
   the chat-side width.
3. Build phase 2 after that check.

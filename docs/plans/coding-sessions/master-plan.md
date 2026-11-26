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
| C08 | The user can open any recent session of the session tool from the coding app's screen, not only one the app started. |
| C09 | The coding screen feels like part of Relay, not another app: it fills the tab and follows Relay's look. A folding left bar shows the workspace (a configured repository), its worktrees and its sessions; the right side shows one session's conversation, changes and terminal with one composer. The session tool's own page is only a link. |

C09 was added on 2026-11-19 after the user's bug report: the framed session
tool page, with its own header, composer and colours inside the coding app's
page, felt like a separate app. Its layout follows the user's mockup of
2026-11-23.

Not included: the two agents talking without the user, the Relay agent acting
when a session finishes, the Relay agent answering approval requests, a
session screen in Relay core (it lives in the coding app), and rewriting the
session tool or giving it Relay-specific screens.

## Approach and boundaries

The user's existing session tool already starts, shows and steers Claude Code
and Codex sessions, and offers the same actions to programs. Relay reuses it
through a small coding app in its own project. That app speaks Relay's
[integration contract](../../integration.md) on one side and the session tool's
interface on the other. Relay core has no coding-specific code.

The session tool is the engine; the coding app draws the screen. The tool's
server already offers what the screen needs: messages, sending a message,
approve and deny, stop, model and effort, and a live event stream. The tool's
own web page is not framed. The tool is the user's copy of an outside project
(about 500,000 lines, nine of its commits the user's own), so it is not
rewritten. A change to it is a small, general addition to its interface that
could go back to the original project. The coding app reaches the tool through
one module and tests against a stand-in, so a tool update is fixed in one
place. The tool's token stays on the coding app's server; the screen talks only
to its own server.

The Start, Send, Approve, Deny and Stop controls are on the coding app's own
screen. The Relay agent
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
The requested file was not written without approval.

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
and refused an unpublished start operation. Live: a real session was started
in the scratch target from the Mac on 2026-11-26 (Phase 2's check); whether it
came from a drafted request and reopened from its conversation is not
recorded.

Added at the user's request on 2026-11-19, covering C08: the home screen lists
up to 30 recent sessions and opens one. An opened session reports
only its id as the view context, so a restored tab reopens it. Nine tests and a
headless browser run against stand-ins passed, and the live app listed the
user's real sessions. The Relay repository is now a target as well.

The list is grouped by project and sorted by last use, and since 2026-11-19 it
also shows Claude Code and Codex conversations started outside the session
tool. Opening one attaches to it if it runs in the background, or shows a
Claude Code conversation's saved history read-only; a Codex conversation opens
only while Codex has it loaded and is otherwise listed with that reason. Ten
tests pass, and the live app listed 30 conversations in 6 projects. Opening an
outside conversation through the real session tool is unverified.

Phase 1 showed sessions in a frame of the session tool's own page; Phase 2
replaced it with the coding app's own screen.

### Phase 2 — Workspace screen

Replaced the framed session tool page with the coding app's own screen, and
added a theme message to Relay core. Covers C03 and C09. The coding app's
server owns the session model and the page draws its snapshots; hapi's own
chat reducer, bundled on that server, turns messages into blocks.

1. **Session screen.** The workspace bar, conversation, composer and
   approvals, with Relay's theme. Done when the stand-in tests pass, the
   theme message is in the [integration contract](../../integration.md), and
   on the Mac one real session in the scratch target is started, approved and
   answered inside the tab beside the chat, in light and dark.
2. **Worktree tree and Changes tab.** Done when the tree's counts and a
   worktree's changes match git on the Mac.
3. **Terminal tab.** Done when typing in a session's terminal works on the
   Mac.

Built in source on 2026-11-23 in the coding app's branch `workspace-screen`
(steps 1–3), with the theme in Relay. Evidence: 23 stand-in tests and the type
check pass; headless runs against a stand-in showed each view at full and
narrow width; each step had an audit and a bug review, and a first-principles
review covered all three.

Mac, reported by the user on 2026-11-26 with Stable 0.0.21, no problems
reported: a real session in the scratch target started, approved and answered
beside the chat, in light and dark; the tree's counts and a worktree's changes
matched git; the terminal took typing. Unverified: sending to a stopped
session (resume) and "+".

Agreed with the user on 2026-11-23:
- "Open workspace…" lists the configured targets plus "Recent sessions in all
  projects";
- counts and changes are uncommitted work compared with HEAD;
- sending to a stopped session resumes it;
- "+" starts a session in an existing worktree.

### Phase 3 — Check-back

Reading sessions for the Relay agent, and follow-up drafts the user sends from
the screen. Covers C05–C06. The agent's reading reuses the screen's session
snapshot rather than a second normalizer.

- Operations to list sessions and read one, agreed on 2026-11-23: title, project name, agent, status (running, waiting for approval,
  idle, finished), waiting approvals, recent messages and the result. Never the
  tool's token or address, or folder paths.
- A follow-up draft shows as a card on the session screen; only the user's
  Send delivers it.
- Answer Relay's app search with sessions, so the agent's search no longer
  fails with 404.

Done when: the agent reports a session correctly while it runs and after it
ends, and a follow-up reaches the session only after the user sends it.

### Phase 4 — First real use

Add one paper to Research Web end to end, following that repository's rules.
Covers C07 in practice. Read those rules before this phase starts.

## Next

Phase 2 is done; the coding app runs it since 2026-11-23. Claude
Code sessions are started with `claude --bg`, so they show in the user's TUI,
and a message reaches a running one through Claude Code's daemon socket; if
that fails, an idle one is stopped and resumed. Codex and hapi-started
sessions act through hapi. Conversations started outside hapi are read from
their Claude Code and Codex transcripts.

1. Phase 1's live check is not recorded: on the Mac, a session started from
   a drafted request reopens from its conversation. Ask the user.
2. Phase 3 (check-back).
3. Suggested on 2026-11-19, not yet agreed: show in Relay's tab bar and in the
   conversation when a session waits for approval or finishes (display only),
   and send a Browser selection or capture to a session as a draft.

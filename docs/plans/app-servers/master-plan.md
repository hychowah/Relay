# App server management
Status: active

## Goal

See and control the user's app servers from Relay, without a terminal. The
user asked for this on 2026-11-22 because starting apps by hand in separate
terminals, especially after a WSL restart, is tiresome. It replaces the
prototype's optional R17 ("independent launchers suffice").

Typical uses:

1. After a WSL restart the user opens Relay. Research Web shows as stopped.
   The user presses Start; it shows as running and its tab loads.
2. The user opens an app's tab while the app is down. The tab offers Start
   instead of only reporting the app as unavailable.
3. An app crashes. It restarts by itself, and Relay shows the failure and the
   last log lines.
4. Relay is redeployed or restarted. Every app keeps running.
5. The user turns on "start with the computer" for an app; it is running after
   the next WSL restart.
6. The agent needs a stopped app. It says so in chat with a Start button; the
   app starts only if the user presses it.

## Agreed behaviour

| ID | Required behaviour |
| --- | --- |
| S01 | An App servers screen in the Flutter client lists each managed app with its state: running, starting, stopped or failed. |
| S02 | Start, Stop and Restart from that screen. The screen reports what actually happened; a start that fails says so. |
| S03 | A "start with the computer" switch per app, where the app's service allows it. Otherwise the switch is shown as not available. |
| S04 | Recent log lines for each app, readable from the screen. |
| S05 | The host's service manager runs every app, not Relay. Apps keep running when Relay restarts or is redeployed. Apps Relay sets up restart by themselves after a crash. |
| S06 | Start commands, folders and settings for each app live only in a private settings file on the host, outside the repository. Neither the screen nor the agent can add or change them. |
| S07 | An app that already has its own service is named in that file and controlled as it is. Relay does not rewrite that service. |
| S08 | When a managed app is unavailable, its tab offers Start. |
| S09 | The agent can see whether a managed app is running. To start one it puts a Start button in chat; nothing starts until the user presses it. The agent cannot stop or restart apps. |
| S10 | Apps on other machines and apps not named in the settings file show no controls. Relay never controls its own backend or web page services; the adapters and coding app are managed apps. |

User decisions of 2026-11-22: start commands are set in the private file only
(S06), the agent may start an app only with the user's press (S09), and all
local apps are managed: Research Web, Analysis Web, Backtest Web, both stock
adapters and the coding app.

Not included: the web page fallback (it keeps chat and app opening only),
Windows-side network forwards, running app servers on the Mac or a phone,
installing or updating apps, and remote machines. Nothing here is desktop-only:
a later phone client can use the same backend operations.

## Approach and boundaries

Relay is a remote control. The host's user service manager starts, stops,
restarts and logs each app, so app lifetimes do not depend on Relay.

A start command entered through a screen would let anyone who can reach Relay
over the tailnet run commands on the host, because Relay has no sign-in. The
settings file on the host is therefore the only place commands are defined.
The screen and the agent only act on what that file names.

No app repository changes. Each app keeps its existing start command or its
existing service; the settings file points at them. Relay core stays generic:
the settings describe any app by command or service name, with no app-specific
code. The adapters and coding app are apps like any other.

The agent's start request is enforced by Relay, not by model instructions: the
chat button is the only path from the agent to a start.

This requires Relay's backend to run directly on the host, as it does today.
If the backend moves into Docker (R15), controlling host services needs a new,
deliberate route; the container must not receive general control of the host.

The current launch arrangements were checked on 2026-11-22. Research Web is
started by hand from a launcher script. Analysis Web is started from a Windows
command that runs inside WSL. Backtest Web has its own service with careful
stop settings and no auto-start entry. The adapters and the coding app are
already services. Machine paths are in the local machine notes, not here.

## Phases

### Phase 1 — Manage local apps

Prerequisite: a short probe that Relay's backend, running as a user service,
can start, stop, read the state of and read logs from another user service.
If it cannot, revisit the approach before building.

Deliver the private settings file, the App servers screen (S01–S04), service
setup for apps given by command (S05), control of existing services (S07),
Start in an unavailable app's tab (S08) and the limits in S06 and S10.

Done when:

- Automated tests use a made-up test app and a temporary service that the
  test removes afterwards. They never touch the user's real apps or records.
- On the Mac, after a backend deploy: a stopped test app is started from the
  screen, shows its logs, survives a Relay restart, and is started again from
  its unavailable tab. One Mac run, a second only if inconclusive.

Switching the user's real apps to managed services is a separate live step
that needs the user's approval: write their entries in the settings file,
stop any hand-started copy, and check each app.
Check then that Backtest Web's tailnet forward still works when the site is
started without its own launcher, and that nothing else starts Analysis Web
at the same time.

Covers S01–S08 and S10.

### Phase 2 — Agent start request

Prerequisite: Phase 1.

Give the agent the managed apps' state and a way to request a start, shown as
a Start button in chat (S09).

Done when a test confirms that the agent's request starts nothing until the
button is pressed, that the agent cannot stop or restart, and that a pressed
button reports the real result. On the Mac, the agent asks for a stopped test
app and the user starts it from chat.

Covers S09.

## Open points

- Where the settings live (the existing apps file or a file beside it), how
  services are named and how logs are read are code-design choices.
- Whether Backtest Web's auto-start can be offered without changing its own
  service. If not, its switch stays unavailable (S03).

## Next

Phase 1 is not started. It needs the user's go-ahead, then a code design and
the probe above.

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
2. The user opens an app's tab while the app is down. The tab offers a button
   to the App servers screen instead of only reporting the app as unavailable.
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
| S05 | The host's service manager runs every app from its own user unit, set up once on the host; apps keep running when Relay restarts or is redeployed and restart after a crash. |
| S06 | Start commands, folders and settings for each app live only on the host, in its user unit, outside the repository; a private settings file names the units Relay controls. Neither the screen nor the agent can add or change them. |
| S07 | An app that already has its own service is named in that file and controlled as it is. Relay does not rewrite that service. |
| S08 | When an app's tab cannot load, it offers a button that opens the App servers screen. |
| S09 | The agent can see whether a managed app is running. To start one it puts a Start button in chat; nothing starts until the user presses it. The agent cannot stop or restart apps. |
| S10 | Relay controls only units the settings file lists; apps on other machines and unlisted apps show no controls. The file must not list Relay's own backend or web page units: Stop would end the backend mid-request, and the client could not start it again. The adapters and coding app are managed apps. |

User decisions of 2026-11-22: start commands are set in the private file only
(S06), the agent may start an app only with the user's press (S09), and all
local apps are managed: Research Web, Analysis Web, Backtest Web, both stock
adapters and the coding app.

User decisions of 2026-11-23, after a first-principles review of the first
Phase 1 build: Relay only controls existing user units and never writes one
(S05, S06); a tab that cannot load links to the App servers screen instead of
starting servers itself (S08); Relay's own units are kept out by not listing
them (S10); the settings file is read on every request and a broken file is
shown on the screen.

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

No app repository changes. Each app runs from a user unit on the host; the
settings file points at it. Relay core stays generic: the settings name any
app's unit, with no app-specific code. The adapters and coding app are apps
like any other.

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

Prerequisite, done 2026-11-23: a probe showed that a user service could
start, inspect, read the logs of and stop another user service.

Deliver the private settings file, the App servers screen (S01–S04), control
of each app's own user unit (S05, S07), the App servers button in a tab that
cannot load (S08) and the limits in S06 and S10.

Done when:

- Fast automated tests use a fake command runner; a manual check against the
  real user service manager uses temporary made-up units that are removed
  afterwards. Neither touches the user's real apps or records.
- On the Mac, after a backend deploy: a stopped test app is started from the
  screen, shows its logs, survives a Relay restart, and the App servers screen
  opens from its unavailable tab. One Mac run, a second only if inconclusive.

Live setup, approved by the user on 2026-11-23: Research Web and Analysis Web
now run from their own user units, enabled at boot, using their existing
launch commands unchanged. Analysis Web's unit signals only its supervisor, as
Ctrl+C does, so a stop leaves running analysis jobs alone; a stop freed both
ports and a start served both sites and the Analysis adapter. Its Windows
launcher must no longer be used. Still to do with the deploy: list all six
units in the servers file, and check that Backtest Web's tailnet forward
still works when the site is started without its own launcher.

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

## Phase 1 design as built

The servers file format and the screen are in the
[README](../../../README.md#manage-app-servers). Beyond that:

- The servers file is separate from the apps file because some servers are
  not registered apps.
- Routes under `/api/app-servers`: list; `:id/start|stop|restart`;
  `PUT :id/auto-start`; `:id/logs`. Requests carry only a server id.
  systemctl and journalctl run without a shell behind one runner seam.
- Every route refuses a request whose Host is not one of Relay's own
  addresses, against DNS rebinding; changes must be sent as JSON (415).
- A start first clears that unit's failed state and counts only if the
  server is still up a second later; otherwise the reply is a failure with
  the reason.
- Logs (last 200 journal lines) stay out of bug recordings and Relay's log.
  The screen refreshes states every 3 s and shown logs every 10 s.

## Phase 1 source evidence (2026-11-23)

Checked on the reworked code:

- All automated checks pass (2026-11-23): `npm test`, `npm run build`,
  `flutter analyze`, `flutter test` and `python3 tools/check_records.py`.
  The app server tests cover entry and unit-name checks, reading on every
  request, empty and broken files, state mapping, real-failure reporting,
  static auto-start, logs, the Host check and the 415 rule, bare template
  units, an older backend's 404, refreshes skipped while a read runs, and the
  App servers button in a tab that cannot load.
- Manual real-systemd check on WSL, with a scratch backend on a free port, a
  temporary data dir and two hand-made temporary units: no file gave an empty
  list; an invalid file gave its reason (500); start, logs, restart and stop
  worked; a unit exiting with status 3 was reported as failed with that
  reason; auto-start on a unit without `[Install]` was refused (409); the
  running unit kept running after the backend stopped. The units were
  removed and no unit named zz* remains.

Enable and disable against a real unit were checked only in the first build,
before this rework, and here with the fake runner. Not yet verified: the Mac
run and the backend under the live `relay-app` service.

Limit: each systemctl or journalctl call has its own 15-second limit, so a
start can outlast the client's 20 seconds; the client then shows a timeout
while systemd carries on, and the next list read shows the real state.

## Next

1. Merge and deploy the backend with `RELAY_SERVERS_FILE` set (listing the six
   app units), then one Mac check (Phase 1 Done when).
2. Phase 2 (S09): confirm with the user that it is still wanted before
   building it.

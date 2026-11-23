# Relay

Relay is a personal agent workspace. You chat with an AI agent beside your own
apps. The agent can read from a connected app, answer with sources, and show
the result inside that app's own screen.

## Vision

- **One workspace for your own tools.** A conversation can span several apps
  and stays open when you switch between them.
- **Apps stay independent.** Each app keeps its own screens and technology, and
  joins Relay by address through a [small protocol](docs/integration.md).
  Relay itself holds no code for any particular app.
- **Your records stay with you.** Conversations, memory and provider keys live
  in the Relay service on your own machine, not in the clients or the apps.
- **Desktop first, phone later.** The Flutter app is the main client, the web
  page is the browser fallback, and a phone app is the long-term goal.

## How it fits together

| Part | What it is |
| --- | --- |
| Service (`server/`) | Node 24, SQLite and the OpenCode agent runtime. It holds the records and makes every model call. |
| Flutter client (`flutter/`) | The main client. See its [README](flutter/README.md). |
| Web page (`web/`) | A React page served by the service. |
| Apps | Your own websites that implement the protocol. `examples/room-layout` is a complete sample. |

## Setup

You need Node 24.9 or later.

```sh
npm ci
npm run build
npm start
```

Open `http://127.0.0.1:3210`. Without an API key Relay runs in a scripted demo
mode, so you can try chat right away.

**Try the sample app.** Start it in one terminal and Relay in another:

```sh
node examples/room-layout/server.ts
RELAY_APPS_FILE=examples/room-layout/apps.json npm start
```

Choose **+ → Room layout** and send a message.

**Connect your own app.** Implement the [protocol](docs/integration.md) in the
app, copy `apps.example.json`, set the app's address, and start Relay with
`RELAY_APPS_FILE` pointing at your copy. Later edits to that file apply
without a restart; reload the page to see them.

**Use a real model.** Open **Model connection** in the page and add a Claude or
DeepSeek key, or set a key file as shown in `.env.example`. By default live
requests are sent only while the host's NordVPN client is connected; set
`RELAY_VPN_CHECK=off` to turn that check off.

**Keep your data.** Records are stored in `RELAY_DATA_DIR` (default `runtime/`).
To back up, stop Relay and copy that whole folder; restore it to the same path.

## Manage app servers

The Flutter app can start and stop the servers of your local apps. Choose
**App servers** in the workspace menu: each server shows whether it is
running, starting, stopping, stopped or failed, with Start, Stop, Restart, a
**Start with the computer** switch and its recent log lines. An app tab that
cannot load has an **App servers** button that opens the same screen.

Relay is only a remote control. Your user service manager (`systemd --user`)
runs each server from its own user unit, so servers keep running when Relay
restarts, restart after a crash, and keep their logs. Relay never writes or
changes a unit; start commands live only in the unit files on the host.

Each server needs its own user unit, set up once, for example
`~/.config/systemd/user/notes-web.service` with made-up values:

```ini
[Unit]
Description=Notes web

[Service]
WorkingDirectory=/srv/notes
ExecStart=/usr/bin/node server.js
Restart=on-failure

[Install]
WantedBy=default.target
```

Run `systemctl --user daemon-reload`, then add one line for it to a private
servers file outside the repository, and set `RELAY_SERVERS_FILE` on the
Flutter backend to that file's path:

```json
[
  {"id": "notes-web", "name": "Notes", "unit": "notes-web.service"}
]
```

`id` uses lowercase letters, digits, `-` and `_`; `name` is shown on the
screen; `unit` is the user unit Relay controls. A request names only a server
id, so the screen can act only on units the file lists. These requests must
name the backend's own address (`127.0.0.1:3250`, `localhost:3250` or
`FLUTTER_RELAY_ORIGIN`), so a page that points its name at Relay (DNS
rebinding) is refused. Do not list Relay's own backend or web page units:
Stop would end the backend mid-request, and the client could not start it
again. A unit without an `[Install]` section cannot start with the
computer, and its switch shows as not available.

The file is read on every request, so edits apply at once. Without
`RELAY_SERVERS_FILE` or the file, the screen is empty; a file that cannot be
read or is not valid shows its reason on the screen.

## Development

Read [AGENTS.md](AGENTS.md) and the [master plan](docs/plans/prototype/master-plan.md)
first. Before a change is merged, run:

```sh
npm test
npm run build
python3 tools/check_records.py
```

**Bug reports.** In the Flutter app, press the record button at the top right,
reproduce the problem, then press the red record button again and describe it.
The recording holds your actions, each server request and reply (a repeated
poll reply is kept once; Browser history and highlight requests are left out), error
messages, the open tabs and a screenshot of the current page. The service saves
it as `bug-reports/<time>-<id>.json` (with a `.png`) in `RELAY_DATA_DIR`, adds its own record of the conversation and replaces
API keys and other secret fields with `[redacted]`. Reports contain conversation
text, so they stay with the runtime data, outside the repository. Choose **Bug
reports** in the workspace menu to read them: each shows its description, screenshot
and a timeline of events that expand to their full details. Mark a report solved
with the circle beside it (click again to reopen it); the header counts open and
solved reports. The bin button deletes the report and its screenshot. The status
is saved as `status` (`open` or `solved`) in the report file.

### Measure performance

Run `npm run perf` on Linux (WSL) from time to time to see how speed changes
as the project grows. It is not a test and has no pass or fail. In about 10–45
seconds, depending on machine load, and with no network or API keys, it seeds
a temporary database with synthetic conversations, memories and a
2,000-message conversation. It then measures server startup, the median time
and response size of the main HTTP reads (including the conversation list,
its search, and `GET /api/conversations/:id`, which the Flutter client polls
every second), the median message round trip with the scripted provider,
server peak memory, and the web build's JS and CSS sizes. The round trip moves
in roughly 400 ms steps because the server polls the agent harness, so it
shows only large slowdowns. Add `-- --skip-build` to leave out the web build.

Each run is saved in `tmp/perf/` and the table shows the change from the
previous run. Sizes and memory more than 20% larger are marked; timings are
not, because they vary by tens of percent between runs. The numbers depend on
the machine, so compare runs from the same machine. Each run also records the
machine load and warns when it was busy; repeat such a run on a quiet machine.
On the Mac, `npm run perf:ui` measures the Flutter client's smoothness in
everyday actions, `npm run perf:stress` its memory over repeated actions and
under heavy load, and `npm run perf:mem` the installed app's memory during real
use; see [Measure performance](flutter/README.md#measure-performance).

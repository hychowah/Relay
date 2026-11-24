# Relay

Relay is a personal agent workspace. You chat with an AI agent beside your own
apps. The agent can read from a connected app, answer with sources, and show
the result inside that app's own screen. In the Flutter app, it can also read
and search folders on your computer that you choose to share, without changing
them, and fill in a web form in the built-in Browser for you to check and
submit yourself.

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

**Use a real model.** Open **Model connection** in the page and add a Claude,
DeepSeek or OpenAI key, or set a key file as shown in `.env.example`. Without a
saved key, Relay also uses `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY` or
`OPENAI_API_KEY` from its environment, so a key exported for other tools counts
as configured. By default live requests are sent only while the host's NordVPN
client is connected; set `RELAY_VPN_CHECK=off` to turn that check off.

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

To build, test, measure or publish Relay, see the
[development guide](docs/development.md).

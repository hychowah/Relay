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
`RELAY_APPS_FILE` pointing at your copy.

**Use a real model.** Open **Model connection** in the page and add a Claude or
DeepSeek key, or set a key file as shown in `.env.example`. By default live
requests are sent only while the host's NordVPN client is connected; set
`RELAY_VPN_CHECK=off` to turn that check off.

**Keep your data.** Records are stored in `RELAY_DATA_DIR` (default `runtime/`).
To back up, stop Relay and copy that whole folder; restore it to the same path.

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
poll reply is kept once), error messages, the open tabs and a screenshot of the
current page. The service saves it as `bug-reports/<time>-<id>.json` (with a
`.png`) in `RELAY_DATA_DIR`, adds its own record of the conversation and replaces
API keys and other secret fields with `[redacted]`. Reports contain conversation
text, so they stay with the runtime data, outside the repository. Choose **Bug
reports** in the workspace menu to read them: each shows its description, screenshot
and a timeline of events that expand to their full details.

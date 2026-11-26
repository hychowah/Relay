# Running Relay

How to configure a running Relay: model keys, other devices, backups and the
app servers screen. To build, test or publish Relay, see the
[development guide](development.md).

## Use a real model

Open **Model connection** in the page and add a Claude, DeepSeek or OpenAI key,
or set a key file as shown in `.env.example`. Without a saved key, Relay also
uses `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` from its
environment, so a key exported for other tools counts as configured. By default
live requests are sent only while the host's NordVPN client is connected; set
`RELAY_VPN_CHECK=off` to turn that check off.

## Connect your own app

Implement the [protocol](integration.md) in the app, copy `apps.example.json`,
set the app's address, and start Relay with `RELAY_APPS_FILE` pointing at your
copy. Later edits to that file apply without a restart; reload the page to see
them.

## Open it from another device

Relay answers only requests addressed to `127.0.0.1` or `localhost` on its
port, so a website that points its own name at Relay (DNS rebinding) is
refused. To use the page through a forward, such as a private tailnet, set
`RELAY_ORIGIN` to the address the other device opens, for example
`http://<device-reachable-host>:<port>`.

## Keep your data

Records are stored in `RELAY_DATA_DIR` (default `runtime/`). To back up, stop
Relay and copy that whole folder; restore it to the same path.

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
id, so the screen can act only on units the file lists. Do not list Relay's
own backend or web page units: Stop would end the backend mid-request, and
the client could not start it again. A unit without an `[Install]` section
cannot start with the computer, and its switch shows as not available.

The file is read on every request, so edits apply at once. Without
`RELAY_SERVERS_FILE` or the file, the screen is empty; a file that cannot be
read or is not valid shows its reason on the screen.

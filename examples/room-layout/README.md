# Room layout example

A standalone SVG room viewer implementing [Relay v2](../../docs/integration.md).
It has one read-only operation, `layout.inspect`, and semantic furniture targets.
It has no Report, search endpoint or Relay-specific core code.

From the Relay repository root, start the app:

```sh
node examples/room-layout/server.ts
```

Open `http://127.0.0.1:3220` to use it independently. To connect it, include the
registration in `apps.json` in your configured app list; Relay picks it up
without a restart.
For a separate demo with private scratch data and the scripted provider:

```sh
RELAY_PROVIDER=fixture RELAY_DATA_DIR=tmp/room-layout-demo \
RELAY_APPS_FILE=examples/room-layout/apps.json node server/index.ts
```

Build Relay first with `npm run build`. Its default port is 3210; use this command
when that port is free. The scripted provider discovers the first operation,
uses its schema defaults and presents its returned intent; it does not interpret
arbitrary questions. DeepSeek can choose a zone when configured.

`PORT` sets the example app's port. `RELAY_ALLOWED_ORIGINS` is a comma-separated
list of permitted Relay browser origins; defaults are localhost and 127.0.0.1
on port 3210. Remote use also needs a reachable `browserUrl` in the registration.

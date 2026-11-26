import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, request } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

async function freePort() {
  const server = createServer();
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  const { port } = server.address() as AddressInfo;
  await new Promise((done) => server.close(done));
  return port;
}

// fetch cannot choose the Host header, so this sends it with node:http.
function status(port: number, host: string, path: string) {
  return new Promise<number>((done, fail) => {
    request({ host: "127.0.0.1", port, path, headers: { Host: host } }, (response) => {
      response.resume();
      done(response.statusCode!);
    }).on("error", fail).end();
  });
}

// The real web page service, as started on the host. The Flutter backend
// (tools/flutter-experiment.ts) wraps its service the same way but listens on
// a fixed port, so it is not started beside the running one.
test("the web page service answers only requests that name its own address", async (t) => {
  const dataDir = mkdtempSync(join(tmpdir(), "relay-hosts-"));
  const port = await freePort();
  // Explicit environment: no .env, so no provider keys reach the child.
  const child = spawn(process.execPath, ["server/index.ts"], {
    cwd: new URL("..", import.meta.url),
    env: {
      PATH: process.env.PATH, HOME: dataDir, RELAY_DATA_DIR: dataDir, RELAY_PROVIDER: "fixture",
      RELAY_HOST: "127.0.0.1", PORT: String(port), RELAY_VPN_CHECK: "off", RELAY_ORIGIN: "http://relay.test:10001",
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
  t.after(async () => {
    if (child.exitCode === null) {
      const exited = new Promise((done) => child.once("exit", done));
      child.kill("SIGTERM");
      await exited;
    }
    rmSync(dataDir, { recursive: true, force: true });
  });
  for (let waited = 0; ; waited += 200) {
    if (await status(port, `127.0.0.1:${port}`, "/api/config").catch(() => 0) === 200) break;
    assert.ok(waited < 60_000 && child.exitCode === null, "The service did not start.");
    await new Promise((done) => setTimeout(done, 200));
  }

  for (const host of [`localhost:${port}`, "relay.test:10001"])
    assert.equal(await status(port, host, "/api/config"), 200, host);
  // A rebound name and another port, for a route, an encoded spelling of it
  // and a static file.
  for (const host of [`evil.test:${port}`, `127.0.0.1:${port + 1}`])
    for (const path of ["/api/conversations", "/%61pi/conversations", "/flutter-host.html"])
      assert.equal(await status(port, host, path), 403, `${path} with Host ${host}`);
});

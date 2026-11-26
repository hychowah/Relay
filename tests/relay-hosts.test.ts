import test from "node:test";
import assert from "node:assert/strict";
import { Store } from "../server/store.ts";
import { createWorkspace } from "../server/app.ts";
import { addAppServers } from "../server/app-servers.ts";
import { createFiles } from "../server/files.ts";
import { onlyRelayHosts, relayHosts } from "../server/relay-hosts.ts";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test("Relay answers only requests that name its own address", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "relay-hosts-"));
  const store = new Store(":memory:");
  const files = createFiles(dir, {});
  const workspace = createWorkspace(store, () => [files.app], { mode: "fixture", model: "fixture", configured: true });
  t.after(async () => { await workspace.close(); store.close(); rmSync(dir, { recursive: true }); });
  files.addRoutes(workspace.app);
  addAppServers(workspace.app, undefined);
  const hosts = relayHosts(3250, "http://relay.test:10007");
  assert.deepEqual(hosts, ["127.0.0.1:3250", "localhost:3250", "relay.test:10007"]);
  const fetch = onlyRelayHosts(workspace.app.fetch, hosts);
  const request = (host: string, path: string, init: RequestInit = {}) =>
    fetch(new Request(`http://${host || "relay.test:10007"}${path}`, { ...init, headers: { ...(host ? { Host: host } : {}), ...init.headers } }));
  const memory = { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ key: "k", content: "v" }) };

  for (const host of ["127.0.0.1:3250", "LOCALHOST:3250", "relay.test:10007"])
    assert.equal((await request(host, "/api/config")).status, 200, host);
  // A rebound name, another port, and no Host at all; also an encoded path,
  // which the routes decode to /api.
  for (const host of ["evil.test:3250", "relay.test:3251", ""]) {
    for (const [path, init] of [["/api/conversations"], ["/%61pi/conversations"], ["/api/settings/folders"],
      ["/api/app-servers"], ["/api/memories", memory]] as const) {
      const refused = await request(host, path, init);
      assert.equal(refused.status, 403, `${path} with Host ${host || "(none)"}`);
    }
  }
  assert.deepEqual(store.memories(), []);
});

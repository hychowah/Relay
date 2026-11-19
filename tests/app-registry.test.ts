import test, { type TestContext } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { appRegistry } from "../server/app-registry.ts";

// Closed loopback ports: manifest probes fail at once and only warn.
const notes = { id: "notes", name: "Notes", serverUrl: "http://127.0.0.1:9" };
const rooms = { id: "rooms", name: "Rooms", serverUrl: "http://127.0.0.1:7" };
const browser = { id: "browser", name: "Browser", serverUrl: "http://127.0.0.1:13" };

function appsFile(t: TestContext) {
  const dir = mkdtempSync(join(tmpdir(), "relay-apps-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  t.mock.method(console, "warn", () => {});
  t.mock.method(console, "log", () => {});
  const errors = t.mock.method(console, "error", () => {});
  const file = join(dir, "apps.json");
  return { file, errors, write: (value: unknown) => writeFileSync(file, typeof value === "string" ? value : JSON.stringify(value)) };
}

async function manifestServer(t: TestContext) {
  const server = createServer((_request, response) => response.writeHead(200, { "Content-Type": "application/json" })
    .end(JSON.stringify({ version: 2, id: "notes", name: "Notes", description: "Synthetic", view: { path: "/_relay/view" } })));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => server.close());
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

test("apps file changes apply on the next read and unchanged entries keep their instance", async (t) => {
  const { file, write } = appsFile(t);
  assert.deepEqual(appRegistry(undefined, [browser])().map((app) => app.id), ["browser"]);
  const served = { ...notes, serverUrl: await manifestServer(t) };
  write([served]);
  const apps = appRegistry(file, [browser]);
  const [fixed, first] = apps();
  assert.ok((await first.integration.open!("token", "http://relay.test")).sandbox);

  write([served, rooms]);
  const added = apps();
  assert.deepEqual(added.map((app) => app.id), ["browser", "notes", "rooms"]);
  assert.equal(added[0], fixed);
  assert.equal(added[1], first);

  write([{ ...served, trustedNative: true }, rooms]);
  const changed = apps();
  assert.notEqual(changed[1], first);
  assert.equal(changed[2], added[2]);
  assert.equal((await changed[1].integration.open!("token", "http://relay.test")).sandbox, undefined);

  write([rooms]);
  assert.deepEqual(apps().map((app) => app.id), ["browser", "rooms"]);
  assert.equal(apps()[1], added[2]);
});

test("a broken apps file keeps the previous list, is logged once, and the next good file applies", (t) => {
  const { file, errors, write } = appsFile(t);
  write([notes]);
  const apps = appRegistry(file, [browser]);
  const good = apps();
  for (const [broken, problem] of [
    ['[{"id":"notes","name":"No', /was not applied: .*JSON/],
    [{ id: "notes" }, /was not applied: it must contain a JSON array/],
    [[{ ...notes, trustedNative: "yes" }], /entry 1 needs/],
    [[{ ...notes, serverUrl: "http://127.0.0.1:9/path" }], /app "notes": App addresses must be HTTP\(S\) origins/],
    [[notes, notes], /"notes" is used more than once/],
    [[{ ...rooms, id: "browser" }], /"browser" is used more than once/],
  ] as const) {
    write(broken);
    const before = errors.mock.callCount();
    assert.deepEqual(apps(), good);
    assert.deepEqual(apps(), good);
    assert.equal(errors.mock.callCount(), before + 1);
    assert.match(String(errors.mock.calls.at(-1)!.arguments[0]), problem);
    assert.match(String(errors.mock.calls.at(-1)!.arguments[0]), /Keeping the previous 2 apps\.$/);
  }
  rmSync(file);
  assert.deepEqual(apps(), good);
  assert.match(String(errors.mock.calls.at(-1)!.arguments[0]), /could not be read \(ENOENT\)/);

  write([notes, rooms]);
  const recovered = apps();
  assert.deepEqual(recovered.map((app) => app.id), ["browser", "notes", "rooms"]);
  assert.equal(recovered[1], good[1]);
});

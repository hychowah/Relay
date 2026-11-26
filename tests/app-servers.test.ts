import test, { type TestContext } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createWorkspace } from "../server/app.ts";
import { addAppServers, parseServers, serverStatus, type AppServer, type Run } from "../server/app-servers.ts";
import { Store } from "../server/store.ts";

type Unit = Record<string, string>;
const running: Unit = { LoadState: "loaded", ActiveState: "active", SubState: "running", Result: "success", ExecMainStatus: "0" };
const stopped: Unit = { LoadState: "loaded", ActiveState: "inactive", SubState: "dead", Result: "success", ExecMainStatus: "0" };
const missing: Unit = { LoadState: "not-found", ActiveState: "inactive", SubState: "dead", Result: "success", ExecMainStatus: "0", UnitFileState: "" };

const notes = { id: "notes", name: "Notes", unit: "notes-web.service" };
const site = { id: "site", name: "Site", unit: "site-web.service" };

/** A service manager in memory: `units` holds each unit's state and `onStart` decides how a start ends. */
function fakeSystemd() {
  const units: Record<string, Unit> = {};
  const calls: string[][] = [];
  let onStart = (unit: string) => { units[unit] = { ...units[unit], ...running }; return { ok: true, stdout: "", stderr: "" }; };
  const run: Run = async (command, args) => {
    calls.push([command, ...args]);
    if (command === "journalctl") return { ok: true, stdout: "tick\ntick\n", stderr: "" };
    const [, verb, ...rest] = args;
    const unit = rest.at(-1)!;
    switch (verb) {
      case "show":
        return { ok: true, stderr: "", stdout: rest.slice(1).map((name) =>
          Object.entries(units[name] ?? missing).map(([key, value]) => `${key}=${value}`).join("\n")).join("\n\n") + "\n" };
      case "start": case "restart": return onStart(unit);
      case "stop": units[unit] = { ...units[unit], ...stopped }; break;
      case "enable": units[unit] = { ...units[unit], UnitFileState: "enabled" }; break;
      case "disable": units[unit] = { ...units[unit], UnitFileState: "disabled" }; break;
    }
    return { ok: true, stdout: "", stderr: "" };
  };
  return { units, calls, run, failStart: (handler: typeof onStart) => { onStart = handler; } };
}

function setup(t: TestContext, entries?: unknown) {
  const dir = mkdtempSync(join(tmpdir(), "relay-servers-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const errors = t.mock.method(console, "error", () => {});
  const logs = t.mock.method(console, "log", () => {});
  const file = join(dir, "servers.json");
  const write = (value: unknown) => writeFileSync(file, typeof value === "string" ? value : JSON.stringify(value));
  if (entries !== undefined) write(entries);
  const systemd = fakeSystemd();
  const store = new Store(":memory:");
  t.after(() => store.close());
  const { app } = createWorkspace(store, () => [], { mode: "fixture", model: "fixture", configured: true });
  addAppServers(app, entries === undefined ? undefined : file, { run: systemd.run, settleMs: 0 });
  // Like every client request, a POST sends JSON.
  const request = async (path: string, method = "GET", body: unknown = method === "GET" ? undefined : {}) => {
    const response = await app.request(path, body === undefined ? { method } : {
      method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    return { status: response.status, body: await response.json() as any };
  };
  return { request, app, write, remove: () => rmSync(file), systemd, errors, logs };
}

test("servers file entries are checked so nothing in them can reach a unit name or argument unchecked", () => {
  assert.deepEqual(parseServers(JSON.stringify([notes, { ...site, extra: true }])), [notes, site]);
  assert.equal(parseServers(JSON.stringify([{ ...notes, unit: "notes@main.service" }]))[0].unit, "notes@main.service");
  for (const [entries, problem] of [
    [{}, /JSON array/],
    [[{ ...notes, id: "../x" }], /entry 1 needs an id/],
    [[{ ...notes, id: "a b" }], /entry 1 needs an id/],
    [[{ ...notes, id: "-now" }], /entry 1 needs an id/],
    [[{ ...notes, id: "Notes" }], /entry 1 needs an id/],
    [[{ ...notes, name: " " }], /needs a name/],
    [[{ id: "x", name: "X", command: ["sh"] }], /needs a unit/],
    [[{ ...notes, unit: "../notes.service" }], /needs a unit/],
    [[{ ...notes, unit: "--now.service" }], /needs a unit/],
    [[{ ...notes, unit: "notes.timer" }], /needs a unit/],
    [[{ ...notes, unit: "notes@.service" }], /template unit needs an instance/],
    [[notes, { ...site, id: "notes" }], /"notes" is used more than once/],
    [[site, { ...site, id: "copy" }], /site-web.service is named more than once/],
  ] as const) {
    assert.throws(() => parseServers(JSON.stringify(entries)), problem);
  }
});

test("unit states map to running, starting, stopping, stopped and failed, with the reason for a failure", () => {
  const server: AppServer = notes;
  const state = (properties: Unit) => {
    const { state, detail, autoStart, autoStartNote } = serverStatus(server, properties);
    return [state, detail, autoStart, autoStartNote];
  };
  assert.deepEqual(state(missing), ["stopped", "notes-web.service is not installed.", null, "Not available for this unit (not installed)."]);
  assert.deepEqual(state({ ...running, UnitFileState: "enabled" }), ["running", undefined, true, undefined]);
  assert.deepEqual(state({ ...running, ActiveState: "activating", SubState: "start", UnitFileState: "disabled" }), ["starting", undefined, false, undefined]);
  assert.deepEqual(state({ ...running, ActiveState: "deactivating", SubState: "stop-sigterm", UnitFileState: "disabled" })[0], "stopping");
  assert.deepEqual(state({ ...stopped, UnitFileState: "static" }),
    ["stopped", undefined, null, "Its unit has no [Install] section, so it cannot start with the computer."]);
  assert.deepEqual(state({ ...stopped, ActiveState: "failed", SubState: "failed", Result: "exit-code", ExecMainStatus: "3", UnitFileState: "disabled" }),
    ["failed", "It exited with status 3.", false, undefined]);
  assert.deepEqual(state({ ...stopped, ActiveState: "activating", SubState: "auto-restart", Result: "signal", ExecMainStatus: "9", UnitFileState: "disabled" }),
    ["failed", "Restarting: it ended by signal 9.", false, undefined]);
});

test("the servers file is read on every request; without it the list is empty and a broken one is reported", async (t) => {
  assert.deepEqual((await setup(t).request("/api/app-servers")).body, []);

  const { request, write, remove } = setup(t, [notes]);
  assert.deepEqual((await request("/api/app-servers")).body, [{ id: "notes", name: "Notes", state: "stopped", detail: "notes-web.service is not installed.", autoStart: null, autoStartNote: "Not available for this unit (not installed)." }]);
  write([notes, site]);
  assert.deepEqual((await request("/api/app-servers")).body.map((server: { id: string }) => server.id), ["notes", "site"]);
  write([{ ...site, unit: "site" }]);
  const broken = await request("/api/app-servers");
  assert.equal(broken.status, 500);
  assert.equal(broken.body.error, 'The servers file is not valid: server "site" needs a unit ending in .service.');
  assert.equal((await request("/api/app-servers/site/start", "POST")).status, 500);
  write("[{");
  assert.match((await request("/api/app-servers")).body.error, /^The servers file is not valid: .*JSON/);
  write([site]);
  assert.equal((await request("/api/app-servers/notes/start", "POST")).status, 404);
  assert.equal((await request("/api/app-servers/..%2Fsite/start", "POST")).status, 404);
  remove();
  assert.deepEqual((await request("/api/app-servers")).body, []);
});

test("start, restart and stop control the named unit and report its real state", async (t) => {
  const { request, systemd } = setup(t, [notes]);
  systemd.units["notes-web.service"] = { ...stopped, UnitFileState: "disabled" };
  const started = await request("/api/app-servers/notes/start", "POST");
  assert.equal(started.status, 200);
  assert.equal(started.body.server.state, "running");
  assert.equal((await request("/api/app-servers/notes/restart", "POST")).body.server.state, "running");
  assert.equal((await request("/api/app-servers/notes/stop", "POST")).body.server.state, "stopped");
  assert.deepEqual(systemd.calls.filter(([, , verb]) => verb !== "show").map((call) => call.slice(2).join(" ")), [
    "reset-failed notes-web.service", "start notes-web.service",
    "reset-failed notes-web.service", "restart notes-web.service",
    "stop notes-web.service",
  ]);
});

test("a start that fails, or a server that does not stay up, is reported as a failure with its reason", async (t) => {
  const { request, systemd } = setup(t, [site]);
  systemd.units["site-web.service"] = { ...stopped, UnitFileState: "static" };
  systemd.failStart(() => ({ ok: false, stdout: "", stderr: "Job for site-web.service failed because the control process exited with error code." }));
  const refused = await request("/api/app-servers/site/start", "POST");
  assert.equal(refused.status, 502);
  assert.match(refused.body.error, /control process exited with error code/);
  assert.equal(refused.body.server.state, "stopped");

  systemd.failStart((unit) => {
    systemd.units[unit] = { ...systemd.units[unit], ActiveState: "failed", SubState: "failed", Result: "exit-code", ExecMainStatus: "1" };
    return { ok: true, stdout: "", stderr: "" };
  });
  const crashed = await request("/api/app-servers/site/start", "POST");
  assert.equal(crashed.status, 502);
  assert.equal(crashed.body.error, "Site did not stay running. It exited with status 1.");
  assert.equal(crashed.body.server.state, "failed");
});

test("auto-start turns on and off where the unit allows it and is refused for a static unit", async (t) => {
  const { request, systemd } = setup(t, [notes, site]);
  systemd.units["notes-web.service"] = { ...running, UnitFileState: "disabled" };
  systemd.units["site-web.service"] = { ...running, UnitFileState: "static" };
  const refused = await request("/api/app-servers/site/auto-start", "PUT", { on: true });
  assert.equal(refused.status, 409);
  assert.match(refused.body.error, /no \[Install\] section/);
  assert.equal(systemd.calls.some(([, , verb]) => verb === "enable"), false);

  assert.equal((await request("/api/app-servers/notes/auto-start", "PUT", { on: "yes" })).status, 400);
  assert.equal((await request("/api/app-servers/notes/auto-start", "PUT", { on: true })).body.autoStart, true);
  assert.equal((await request("/api/app-servers/notes/auto-start", "PUT", { on: false })).body.autoStart, false);
  assert.deepEqual(systemd.calls.filter(([, , verb]) => verb === "enable" || verb === "disable").map((call) => call.slice(2).join(" ")),
    ["enable notes-web.service", "disable notes-web.service"]);
});

test("recent logs come from the server's own unit and stay out of Relay's log", async (t) => {
  const { request, systemd, errors, logs } = setup(t, [notes]);
  assert.deepEqual((await request("/api/app-servers/notes/logs")).body, { text: "tick\ntick\n" });
  assert.deepEqual(systemd.calls.at(-1), ["journalctl", "--user", "-u", "notes-web.service", "-o", "cat", "-n", "200", "--no-pager"]);
  assert.equal(errors.mock.callCount() + logs.mock.callCount(), 0);
});

test("changes to the servers must send JSON", async (t) => {
  const { app, systemd } = setup(t, [notes]);
  const plain = await app.request("/api/app-servers/notes/stop", { method: "POST", body: "stop" });
  assert.equal(plain.status, 415);
  assert.equal(systemd.calls.some(([, , verb]) => verb === "stop"), false);
});

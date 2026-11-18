import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { setTimeout as delay } from "node:timers/promises";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { HttpIntegration, AppRequestError } from "../server/integrations/http.ts";
import { createWorkspace, type AppIntegration } from "../server/app.ts";
import { Store } from "../server/store.ts";
import type { OperationProgress, PresentCommand, SurfaceContext } from "../shared/types.ts";

const manifest = {
  version: 2, id: "rooms", name: "Room layout", description: "Inspect furniture",
  instructions: "Use furniture IDs as semantic targets.", view: { path: "/_relay/view" },
};
const operation = { name: "layout.inspect", description: "Inspect the current layout",
  inputSchema: { type: "object", properties: { zone: { type: "string" } } } };
const registration = { id: "rooms", name: "Configured rooms", serverUrl: "https://rooms.test" };

async function fixture() {
  const state = {
    operations: { operations: [operation] } as unknown,
    events: '{"type":"progress","message":"Inspecting work zone"}\n{"type":"result","result":{"data":{"count":2}}}\n',
    delayed: false,
    seen: undefined as unknown,
    closed: false,
  };
  const server = createServer(async (request, response) => {
    const url = new URL(request.url!, "http://fixture");
    const json = (body: unknown) => response.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify(body));
    if (url.pathname === "/_relay/manifest") json(manifest);
    else if (url.pathname === "/_relay/operations") json(state.operations);
    else if (url.pathname === "/_relay/call") {
      let text = "";
      for await (const part of request) text += part;
      state.seen = JSON.parse(text);
      response.on("close", () => { state.closed = true; });
      response.writeHead(200, { "Content-Type": "application/x-ndjson" });
      response.write(state.events);
      if (!state.delayed) response.end();
    } else response.writeHead(404).end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const adapter = new HttpIntegration({ id: "rooms", name: "Room layout",
    serverUrl: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, browserUrl: "https://rooms.test" });
  return { state, adapter, close: () => new Promise<void>((resolve) => {
    server.closeAllConnections(); server.close(() => resolve());
  }) };
}

async function until(check: () => boolean) {
  const end = Date.now() + 2000;
  while (!check() && Date.now() < end) await delay(5);
  assert.ok(check(), "expected state before deadline");
}
const provider = { mode: "fixture" as const, model: "scripted", configured: true };
const post = (workspace: ReturnType<typeof createWorkspace>, path: string, body: unknown) =>
  workspace.app.request(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
function harness(workspace: ReturnType<typeof createWorkspace>) {
  workspace.setHarness({ deleteSession: async () => {}, createSession: async () => "session", prompt: async () => {},
    inspect: async () => ({ status: "running", messages: [] }), interrupt: async () => {} });
}

test("v2 discovers one app, streams real progress and opens a view with no Report", async () => {
  const app = await fixture();
  try {
    assert.deepEqual(await app.adapter.discover(), { instructions: manifest.instructions, operations: [operation] });
    const progress: OperationProgress[] = [];
    assert.deepEqual(await app.adapter.call("layout.inspect", { zone: "work" }, { onProgress: (event) => progress.push(event) }),
      { data: { count: 2 } });
    assert.deepEqual(progress, [{ type: "progress", message: "Inspecting work zone" }]);
    assert.deepEqual(app.state.seen, { operation: "layout.inspect", arguments: { zone: "work" } });
    const view = await app.adapter.open("token", "https://relay.test");
    assert.equal(view.origin, "https://rooms.test");
    const url = new URL(view.url);
    assert.equal(url.searchParams.get("resourceId"), null);
    assert.equal(url.searchParams.get("token"), "token");
    assert.equal(url.searchParams.get("parentOrigin"), "https://relay.test");
    await assert.rejects(app.adapter.call("unpublished.write", {}), /not published/);
  } finally { await app.close(); }
});

function timedCall(t: test.TestContext, eventGaps: number[]) {
  const adapter = new HttpIntegration(registration, 50);
  t.mock.method(adapter, "discover", async () => ({ operations: [operation] }));
  t.mock.method(globalThis, "fetch", (_url: URL, { signal }: RequestInit) => {
    const body = new ReadableStream({
      async pull(controller) {
        const gap = eventGaps.shift();
        if (gap === undefined) {
          controller.enqueue(Buffer.from('{"type":"result","result":{"data":"finished"}}\n'));
          controller.close();
          return;
        }
        await delay(gap, undefined, { signal: signal! });
        controller.enqueue(Buffer.from('{"type":"progress","message":"Working"}\n'));
      },
    });
    return new Response(body, { headers: { "Content-Type": "application/x-ndjson" } });
  });
  return adapter.call(operation.name, {});
}

test("v2 calls outlive the request timeout while events keep arriving", async (t) => {
  assert.deepEqual(await timedCall(t, [100, 100, 100, 100]), { data: "finished" });
});

test("v2 cuts off a silent call", async (t) => {
  await assert.rejects(timedCall(t, [600]), (error) =>
    error instanceof AppRequestError && error.kind === "unavailable" && /timed out/.test(error.message));
});

test("an app unavailable at registration recovers on open and publishes its tools", async (t) => {
  let failStartup!: (error: Error) => void;
  const upstream = t.mock.method(globalThis, "fetch", (url: URL) => {
    if (!failStartup) return new Promise<Response>((_, reject) => { failStartup = reject; });
    switch (url.pathname) {
      case "/_relay/manifest": return Response.json(manifest);
      case "/_relay/operations": return Response.json({ operations: [operation] });
      default: throw new Error(`Unexpected app request: ${url.pathname}`);
    }
  });
  const registered = HttpIntegration.register(registration);
  const store = new Store(":memory:");
  const workspace = createWorkspace(store, [registered], provider);
  harness(workspace);
  const config = async () => (await (await workspace.app.request("/api/config")).json()).apps[0];
  try {
    assert.equal((await config()).protocolVersion, 2, "clients can attempt the home view");
    assert.equal(upstream.mock.callCount(), 1, "config uses registration without contacting the app");
    failStartup(new Error("Offline"));
    const home = await workspace.app.request("/api/apps/rooms/view?token=t&parentOrigin=https://relay.test");
    assert.equal(home.status, 200);
    assert.equal((await home.json()).origin, registration.serverUrl);
    assert.equal((await config()).name, manifest.name);
    const conversation = store.createConversation("Layout", "session");
    store.startRun(conversation.id, "Inspect", "desktop", "tab");
    assert.deepEqual(await workspace.toolHandler("session", "app_discover", { appId: "rooms" }),
      { instructions: manifest.instructions, operations: [operation] });
  } finally { await workspace.close(); store.close(); }
});

test("v2 rejects malformed discovery envelopes at the integration boundary", async () => {
  const app = await fixture();
  try {
    for (const operations of [null, {}, { operations: [null] },
      { operations: [{ ...operation, inputSchema: [] }] }, { operations: [operation, operation] }]) {
      app.state.operations = operations;
      await assert.rejects(app.adapter.discover(), (error) => error instanceof AppRequestError && error.kind === "protocol");
    }
  } finally { await app.close(); }
});

test("v2 requires one terminal NDJSON event and distinguishes app errors from protocol failures", async () => {
  const app = await fixture();
  try {
    for (const events of ['invalid\n', '{"type":"progress","message":"Working"}\n',
      '{"type":"result","result":{"data":1}}\n{"type":"result","result":{"data":2}}\n',
      '{"type":"result","result":{"sources":[]}}\n',
      '{"type":"result","result":{"data":1,"sources":[{"appId":"other"}]}}\n']) {
      app.state.events = events;
      await assert.rejects(app.adapter.call("layout.inspect", {}), (error) => error instanceof AppRequestError && error.kind === "protocol");
    }
    app.state.events = '{"type":"error","message":"Unknown room"}\n';
    await assert.rejects(app.adapter.call("layout.inspect", {}), (error) =>
      error instanceof AppRequestError && error.kind === "app" && error.message === "Unknown room");
  } finally { await app.close(); }
});

test("v2 abort disconnects the upstream operation without claiming remote cancellation", async () => {
  const app = await fixture();
  try {
    app.state.delayed = true;
    app.state.events = '{"type":"progress","message":"Reading layout"}\n';
    const controller = new AbortController();
    let seenProgress = false;
    const call = app.adapter.call("layout.inspect", {}, { signal: controller.signal, onProgress: () => { seenProgress = true; } });
    await until(() => seenProgress);
    controller.abort();
    await assert.rejects(call, (error) => error instanceof Error && error.name === "AbortError");
    await until(() => app.state.closed);
  } finally { await app.close(); }
});

test("workspace presents app-owned state without Reports and carries acknowledged generation forward", async () => {
  const store = new Store(":memory:");
  const integration: AppIntegration = { open: async (token) => ({ url: `https://rooms.test/?token=${token}`, origin: "https://rooms.test", native: true, sandbox: "allow-scripts allow-same-origin" }) };
  const workspace = createWorkspace(store, [{ ...manifest, protocolVersion: 2, integration }], provider);
  harness(workspace);
  const conversation = store.createConversation("Layout", "session");
  try {
    assert.equal((await workspace.app.request("/api/apps/rooms/view?token=t&parentOrigin=https://relay.test")).status, 200);
    const appContext = { appId: "rooms", viewToken: "origin-token", surface: { viewId: "room", generation: 3, state: { zone: "all" } } };
    assert.equal((await post(workspace, `/api/conversations/${conversation.id}/messages`, {
      text: "Show the desk", deviceId: "desktop", tabId: "tab", appContext,
    })).status, 202);
    const intent = { explanation: "These dimensions are synthetic centimetres.", viewId: "room", state: { zone: "work" }, targetIds: ["desk"] };
    for (const explanation of [42, " ", "x".repeat(601)]) {
      const invalid = await workspace.toolHandler("session", "app_present", { appId: "rooms", intent: { ...intent, explanation } }) as {error: string};
      assert.match(invalid.error, /Invalid app view intent/);
    }
    const presenting = workspace.toolHandler("session", "app_present", { appId: "rooms", intent });
    await until(() => store.snapshot(conversation.id)!.commands.length === 1);
    const command = store.snapshot(conversation.id)!.commands[0] as PresentCommand;
    assert.equal(command.kind, "present");
    assert.deepEqual(command.intent, intent);
    assert.equal(command.expectedGeneration, 3);
    assert.equal(command.expectedViewToken, "origin-token");
    assert.equal((await post(workspace, `/api/commands/${command.id}/ack`, { deviceId: "phone", tabId: "tab", status: "applied" })).status, 403);
    assert.equal((await post(workspace, `/api/commands/${command.id}/ack`, { deviceId: "desktop", tabId: "tab", status: "applied", viewToken: "new-token" })).status, 400);
    const context: SurfaceContext = { ...intent, generation: 4 };
    await post(workspace, `/api/commands/${command.id}/ack`, { deviceId: "desktop", tabId: "tab", status: "applied", viewToken: "new-token", context });
    assert.equal((await presenting as PresentCommand).status, "applied");
    assert.deepEqual(workspace.agentContext("session")!.currentApp, { appId: "rooms", viewToken: "new-token", surface: context });
    const second = workspace.toolHandler("session", "app_present", { appId: "rooms", intent });
    await until(() => store.snapshot(conversation.id)!.commands.length === 2);
    const next = store.snapshot(conversation.id)!.commands[1] as PresentCommand;
    assert.equal(next.expectedGeneration, 4);
    assert.equal(next.expectedViewToken, "new-token");
    await post(workspace, `/api/commands/${next.id}/ack`, { deviceId: "desktop", tabId: "tab", status: "stale", context: { viewId: "room", generation: 5 } });
    assert.equal((await second as PresentCommand).status, "stale");
    assert.deepEqual(workspace.agentContext("session")!.currentApp, { appId: "rooms", viewToken: "new-token", surface: context });
    const failed = workspace.toolHandler("session", "app_present", { appId: "rooms", intent });
    await until(() => store.snapshot(conversation.id)!.commands.length === 3);
    const rejected = store.snapshot(conversation.id)!.commands[2] as PresentCommand;
    const actual = {viewId: "room", generation: 6};
    await post(workspace, `/api/commands/${rejected.id}/ack`, {deviceId:"desktop",tabId:"tab",status:"failed",error:"Invalid filter",viewToken:"failed-view",context:actual});
    assert.equal((await failed as PresentCommand).status, "failed");
    const retry = workspace.toolHandler("session", "app_present", {appId:"rooms",intent});
    await until(() => store.snapshot(conversation.id)!.commands.length === 4);
    const corrected = store.snapshot(conversation.id)!.commands[3] as PresentCommand;
    assert.equal(corrected.expectedGeneration, 6);
    assert.equal(corrected.expectedViewToken, "failed-view");
    await post(workspace, `/api/commands/${corrected.id}/ack`, {deviceId:"desktop",tabId:"tab",status:"applied",viewToken:"corrected",context:{...intent,generation:7}});
    assert.equal((await retry as PresentCommand).status, "applied");
    assert.equal(store.snapshot(conversation.id)!.messages[0].context, undefined);
    assert.deepEqual(store.snapshot(conversation.id)!.messages[0].appContext, appContext);
  } finally { await workspace.close(); store.close(); }
});

test("workspace scopes discovery instructions, persists actual progress and aborts calls on Stop", async () => {
  const app = await fixture();
  app.state.delayed = true;
  app.state.events = '{"type":"progress","message":"Reading room"}\n';
  const store = new Store(":memory:");
  const workspace = createWorkspace(store, [
    { ...manifest, protocolVersion: 2, integration: app.adapter },
    { id: "private", name: "Private", description: "Forbidden", instructions: "DO NOT LEAK", integration: {} },
  ], provider);
  harness(workspace);
  const bot = store.saveBot({ name: "Designer", objective: "Review rooms", scope: "Layouts", appIds: ["rooms"] });
  const conversation = store.createConversation("Layout", "session", bot.id);
  try {
    await post(workspace, `/api/conversations/${conversation.id}/messages`, { text: "Inspect", deviceId: "desktop", tabId: "tab", appContext: { appId: "rooms", surface: { viewId: "room", generation: 0 } } });
    const context = workspace.agentContext("session")!;
    assert.deepEqual(context.allowedApps.map((entry) => entry.id), ["rooms"]);
    assert.ok(!JSON.stringify(context).includes("DO NOT LEAK"));
    assert.deepEqual(await workspace.toolHandler("session", "app_discover", { appId: "rooms" }), { instructions: manifest.instructions, operations: [operation] });
    assert.match((await workspace.toolHandler("session", "app_discover", { appId: "private" }) as { error: string }).error, /outside the bot/);
    const call = workspace.toolHandler("session", "app_call", { appId: "rooms", operation: "layout.inspect", arguments: {} });
    await until(() => store.snapshot(conversation.id)!.tools.some((tool) => tool.progress?.length === 1));
    const tool = store.snapshot(conversation.id)!.tools.find((entry) => entry.name === "app_call")!;
    assert.equal(tool.status, "running");
    assert.deepEqual(tool.progress, [{ type: "progress", message: "Reading room" }]);
    const run = store.activeRun(conversation.id)!;
    assert.equal((await post(workspace, `/api/runs/${run.id}/cancel`, {})).status, 200);
    await call;
    await until(() => app.state.closed);
    assert.equal(store.run(run.id)!.status, "cancelled");
    const recorded = store.snapshot(conversation.id)!.tools.find((entry) => entry.id === tool.id)!;
    assert.equal(recorded.status, "completed");
    assert.deepEqual(recorded.progress, tool.progress);
  } finally { await workspace.close(); store.close(); await app.close(); }
});

test("old stored commands normalize on read without rewriting their recorded JSON", async () => {
  const dir = await mkdtemp(join(tmpdir(), "relay-old-command-"));
  const path = join(dir, "relay.sqlite");
  let store = new Store(path);
  try {
    const conversation = store.createConversation("Old", "session");
    const run = store.startRun(conversation.id, "read", "desktop", "tab");
    const source = { appId: "old", resourceId: "r", revision: "v1", title: "Old report", sourceUrl: "https://old.test" };
    const command = store.createCommand(run, source, "content");
    store.close();
    const db = new DatabaseSync(path);
    const old = { ...command } as Record<string, unknown>;
    delete old.kind;
    const raw = JSON.stringify(old);
    db.prepare("UPDATE commands SET data = ? WHERE id = ?").run(raw, command.id);
    store = new Store(path);
    assert.equal(store.command(command.id)!.kind, "navigate");
    assert.equal(store.snapshot(conversation.id)!.commands[0].kind, "navigate");
    assert.equal(db.prepare("SELECT data FROM commands WHERE id = ?").get(command.id)!.data, raw);
    db.close();
  } finally { store.close(); await rm(dir, { recursive: true, force: true }); }
});

test("automation resets bridge generation when returning across apps or from a legacy view", () => {
  const store = new Store(":memory:");
  try {
    const conversation = store.createConversation("Across apps", "session");
    const appContext = { appId: "rooms", viewToken: "origin-token", surface: { viewId: "room", generation: 5 } };
    const run = store.startRun(conversation.id, "Compare rooms and gardens", "desktop", "tab", undefined, appContext);
    const garden = store.createPresentation(run, "garden", { viewId: "beds" });
    assert.equal(garden.expectedGeneration, 0);
    store.acknowledge(garden.id, "applied", undefined, "garden-token", { viewId: "beds", generation: 1 });
    const back = store.createPresentation(run, "rooms", { viewId: "room" });
    assert.equal(back.expectedGeneration, 0, "returning mounts a fresh bridge instead of reusing question generation");
    store.acknowledge(back.id, "applied", undefined, "rooms-token", { viewId: "room", generation: 1 });
    const stale = store.createPresentation(run, "garden", { viewId: "beds" });
    store.acknowledge(stale.id, "stale", undefined, "unapplied-token", { viewId: "beds", generation: 8 });
    assert.equal(store.createPresentation(run, "rooms", { viewId: "room" }).expectedGeneration, 1,
      "a superseded command does not replace the last applied surface");
    const source = { appId: "rooms", resourceId: "layout-notes", revision: "v1", title: "Notes", sourceUrl: "https://rooms.test/notes" };
    const legacy = store.createCommand(run, source, "content");
    store.acknowledge(legacy.id, "applied", undefined, "legacy-token");
    const semantic = store.createPresentation(run, "rooms", { viewId: "room" });
    assert.equal(semantic.expectedGeneration, 0, "a legacy view replaces the semantic bridge");
    assert.equal(semantic.expectedViewToken, "legacy-token");
    assert.deepEqual(store.run(run.id)!.appContext, appContext, "the original question context remains recorded");
  } finally { store.close(); }
});

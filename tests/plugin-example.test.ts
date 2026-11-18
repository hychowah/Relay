import test from "node:test";
import assert from "node:assert/strict";
import { createRoomLayoutApp } from "../examples/room-layout/server.ts";

test("room layout exposes operations and a native view without document APIs", async () => {
  const app = createRoomLayoutApp(["https://relay.test"]);
  const manifest = await (await app.request("/_relay/manifest")).json();
  assert.equal(manifest.version, 2);
  assert.equal(manifest.id, "room-layout");
  assert.equal((await app.request("/_relay/search")).status, 404);
  const { operations } = await (await app.request("/_relay/operations")).json();
  const response = await app.request("/_relay/call", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ operation: operations[0].name, arguments: { zone: "work" } }),
  });
  const events = (await response.text()).trim().split("\n").map((line) => JSON.parse(line));
  assert.equal(events[0].type, "progress");
  assert.deepEqual(events[1].result.data.items.map((item: { id: string }) => item.id), ["desk", "lamp"]);
  assert.deepEqual(events[1].result.data.presentation, { viewId: "room", state: { zone: "work" }, targetIds: ["desk", "lamp"] });
  const view = await app.request("/_relay/view?parentOrigin=https%3A%2F%2Frelay.test&token=demo");
  assert.equal(view.status, 200);
  assert.equal(view.headers.get("content-security-policy"), "frame-ancestors https://relay.test");
  assert.match(await view.text(), /RelayApp.connect/);
  assert.equal((await app.request("/_relay/view?parentOrigin=https%3A%2F%2Funknown.test&token=demo")).status, 403);
});

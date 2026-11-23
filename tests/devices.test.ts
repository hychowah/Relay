import test from "node:test";
import assert from "node:assert/strict";
import { Hono } from "hono";
import { addDevices } from "../server/devices.ts";
import { Store } from "../server/store.ts";

function devices() {
  const store = new Store(":memory:");
  const app = new Hono();
  const clock = { time: Date.UTC(2026, 10, 21, 12) };
  addDevices(app, store, () => clock.time);
  const send = (method: string, path: string, body: unknown) => app.request(path, {
    method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  return { store, app, clock, send };
}

const session = (url: string) => ({ active: 0, tabs: [{ appId: "browser", url }] });

test("each device keeps its last tabs, newest device first", async () => {
  const d = devices();
  assert.equal((await d.send("PUT", "/api/devices/mac-1", { name: "Mac", tabs: session("https://a.example/") })).status, 204);
  d.clock.time += 1000;
  assert.equal((await d.send("PUT", "/api/devices/win-1", { name: "Windows", tabs: session("https://b.example/") })).status, 204);
  d.clock.time += 1000;
  assert.equal((await d.send("PUT", "/api/devices/mac-1", { name: "Mac", tabs: session("https://c.example/") })).status, 204);

  const listed = await (await d.app.request("/api/devices")).json();
  assert.deepEqual(listed.map((device: { id: string; tabs: { tabs: Array<{ url: string }> } }) =>
    [device.id, device.tabs.tabs[0].url]), [["mac-1", "https://c.example/"], ["win-1", "https://b.example/"]]);
});

test("tabs that are not a tab session are refused", async () => {
  const d = devices();
  for (const body of [{ name: "Mac", tabs: { active: 0 } }, { name: 3, tabs: session("https://a.example/") }]) {
    assert.equal((await d.send("PUT", "/api/devices/mac-1", body)).status, 400);
  }
  assert.deepEqual(d.store.devices(), []);
});

test("the conversation last opened on any device is current until it goes to Trash", async () => {
  const d = devices();
  const current = async () => (await (await d.app.request("/api/current-conversation")).json()).id;
  assert.equal(await current(), null);
  assert.equal((await d.send("PUT", "/api/current-conversation", { id: "missing" })).status, 404);

  const first = d.store.createConversation("First", "session-1").id;
  const second = d.store.createConversation("Second", "session-2").id;
  assert.equal((await d.send("PUT", "/api/current-conversation", { id: first })).status, 204);
  assert.equal((await d.send("PUT", "/api/current-conversation", { id: second })).status, 204);
  assert.equal(await current(), second);

  d.store.trashConversation(second);
  assert.equal(await current(), null);
  assert.equal((await d.send("PUT", "/api/current-conversation", { id: second })).status, 404);
});

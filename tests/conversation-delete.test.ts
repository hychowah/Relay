import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Store } from "../server/store.ts";
import { createWorkspace } from "../server/app.ts";

const day = 24 * 60 * 60 * 1000;
function setup(store: Store, deleteSession: (id: string) => Promise<void>) {
  const workspace = createWorkspace(store, [], { mode: "fixture", model: "fixture", configured: true });
  workspace.setHarness({
    async createSession() { return "unused"; }, deleteSession,
    async prompt() { assert.fail("Trashed conversations cannot start work"); },
    async inspect() { return { status: "idle", messages: [] }; }, async interrupt() {},
  });
  const post = (path: string, body = {}) => workspace.app.request(path, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  return { workspace, post };
}

test("Trash hides normal and bot chat history; restore keeps the session, settings, forwards and editable memories", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-11-16T00:00:00Z") });
  const store = new Store(":memory:");
  const { workspace, post } = setup(store, async () => assert.fail("Unexpired trash must not be deleted"));
  try {
    const source = store.createConversation("Move me", "source-session");
    const bot = store.saveBot({ name: "Helper", objective: "Help", scope: "", appIds: [] });
    const target = store.createConversation("Keep me", "target-session", bot.id);
    store.setReasoningEffort(source.id, "max");
    const run = store.startRun(source.id, "Unique trash content", "device", "tab");
    const route = `/api/conversations/${source.id}`;
    assert.equal((await workspace.app.request(route, { method: "DELETE" })).status, 409);
    store.finishRun(run.id, "completed");
    store.addForward(source.id, target.id, "Handoff");
    const memory = store.saveMemory({ key: "preference", content: "Keep this memory", sourceConversationId: source.id,
      sourceMessageId: store.snapshot(source.id)!.messages[0].id });
    assert.equal((await workspace.app.request(route, { method: "DELETE" })).status, 200);
    const trashedAt = store.trash()[0].trashedAt;
    t.mock.timers.tick(1000);
    await workspace.app.request(route, { method: "DELETE" });
    assert.equal(store.trash()[0].trashedAt, trashedAt, "Repeated trash does not extend retention");
    assert.equal((await workspace.app.request("/api/trash")).status, 200);
    assert.equal((await workspace.app.request(route)).status, 404);
    assert.equal((await post(route + "/messages", { text: "No reply", deviceId: "device", tabId: "tab" })).status, 404);
    assert.equal((await post(route + "/forward", { botId: bot.id })).status, 404);
    assert.deepEqual(store.conversations("Unique trash content"), []);
    assert.deepEqual(store.searchHistory(target.id, "Unique trash content"), []);
    assert.deepEqual(store.forwards(target.id), []);
    assert.throws(() => store.readHistory(target.id, source.id), /not found/);
    assert.equal(store.saveMemory({ ...memory, content: "Edited while source is in Trash" }, memory.id).content, "Edited while source is in Trash");
    await workspace.purgeTrash();
    assert.equal((await post(route + "/restore")).status, 200);
    assert.equal(store.sessionId(source.id), "source-session");
    assert.equal(store.snapshot(source.id)!.conversation.reasoningEffort, "max");
    assert.equal(store.snapshot(source.id)!.messages[0].text, "Unique trash content");
    assert.equal(store.forwards(target.id).length, 1);
    assert.equal(store.searchHistory(target.id, "Unique trash content").length, 1);
    await workspace.app.request(`/api/conversations/${target.id}`, { method: "DELETE" });
    assert.equal(store.trash()[0].botId, bot.id);
    assert.equal((await post(`/api/conversations/${target.id}/restore`)).status, 200);
    assert.equal(store.conversation(target.id)!.botId, bot.id);
  } finally { await workspace.close(); store.close(); }
});

test("24-hour cleanup removes the agent session and dependent records, retries failure, and preserves other chats and memories", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: new Date("2026-11-16T00:00:00Z") });
  const store = new Store(":memory:");
  let fail = true;
  const removed: string[] = [];
  const { workspace, post } = setup(store, async id => {
    if (fail) throw new Error("Harness unavailable");
    removed.push(id);
  });
  try {
    const source = store.createConversation("Expired", "expired-session");
    const keep = store.createConversation("Keep", "keep-session");
    const run = store.startRun(source.id, "Expired history", "device", "tab");
    const tool = store.startTool(run.id, "app_search", {});
    const command = store.createPresentation(run, "fixture", { viewId: "main" });
    store.finishRun(run.id, "completed");
    store.saveCheckpoint(source.id, "Discard checkpoint");
    store.addForward(source.id, keep.id, "Handoff");
    const memory = store.saveMemory({ key: "preference", content: "Keep this memory", sourceConversationId: source.id,
      sourceMessageId: store.snapshot(source.id)!.messages[0].id });
    store.trashConversation(source.id);
    t.mock.timers.tick(day - 1);
    assert.deepEqual(store.expiredTrash(), []);
    await workspace.purgeTrash();
    t.mock.timers.tick(1);
    assert.equal((await post(`/api/conversations/${source.id}/restore`)).status, 410);
    await workspace.purgeTrash();
    assert.equal(store.trash().length, 1, "Failed cleanup retains records for retry");
    assert.ok(store.run(run.id));
    fail = false;
    await workspace.purgeTrash();
    assert.deepEqual(removed, ["expired-session"]);
    assert.deepEqual(store.trash(), []);
    assert.equal(store.sessionId(source.id), undefined);
    assert.equal(store.run(run.id), undefined);
    assert.equal(store.finishTool(tool.id, {}), undefined);
    assert.equal(store.command(command.id), undefined);
    assert.equal(store.checkpoint(source.id), undefined);
    assert.deepEqual(store.forwards(keep.id), []);
    assert.ok(store.snapshot(keep.id));
    const saved = store.memories().find(item => item.id === memory.id)!;
    assert.equal(saved.content, memory.content);
    assert.equal(saved.sourceConversationId, undefined);
    assert.equal(saved.sourceMessageId, undefined);
  } finally { await workspace.close(); store.close(); }
});

test("existing conversation databases migrate without data loss and retain Trash across reopening", async () => {
  const dir = await mkdtemp(join(tmpdir(), "relay-trash-"));
  const path = join(dir, "relay.sqlite");
  const old = new DatabaseSync(path);
  old.exec("CREATE TABLE conversations (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, title TEXT NOT NULL, created_at TEXT NOT NULL)");
  old.prepare("INSERT INTO conversations VALUES (?, ?, ?, ?)").run("old", "old-session", "Existing chat", "2026-11-16");
  old.close();
  let store = new Store(path);
  try {
    assert.equal(store.conversations().length, 1);
    store.trashConversation("old");
    const saved = store.trash()[0];
    store.close();
    store = new Store(path);
    assert.deepEqual(store.trash()[0], saved);
    assert.equal(store.conversations().length, 0);
    assert.equal(store.restoreConversation("old")!.title, "Existing chat");
    assert.equal(store.sessionId("old"), "old-session");
  } finally { store.close(); await rm(dir, { recursive: true, force: true }); }
});

import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Store } from "../server/store.ts";
import { createWorkspace } from "../server/app.ts";
import type { ReasoningEffort } from "../shared/types.ts";

test("conversation effort migrates old records, persists per chat, and reaches the next reply", async () => {
  const dir = await mkdtemp(join(tmpdir(), "relay-conversation-effort-"));
  const path = join(dir, "relay.sqlite");
  const old = new DatabaseSync(path);
  old.exec("CREATE TABLE conversations (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, title TEXT NOT NULL, created_at TEXT NOT NULL)");
  old.prepare("INSERT INTO conversations VALUES (?, ?, ?, ?)").run("old", "old-session", "Existing chat", "2026-11-16");
  old.close();
  let store = new Store(path);
  const provider = { mode: "deepseek" as const, model: "deepseek-flash", configured: true };
  const workspace = createWorkspace(store, [], provider);
  let workspaceClosed = false;
  let received: ReasoningEffort | null | undefined;
  let called = false;
  workspace.setHarness({
    async deleteSession() {},
    async createSession() { return "new-session"; },
    async prompt(_session, _text, _context, _appContext, effort) { received = effort; called = true; },
    async inspect() { return { messages: [], status: called ? "running" : "idle" }; },
    async interrupt() {},
  });
  const post = (route: string, body: unknown) => workspace.app.request(route, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  try {
    assert.equal(store.conversation("old")!.reasoningEffort, null);
    const bot = store.saveBot({ name: "Helper", objective: "Help", scope: "", appIds: [] });
    const other = store.createConversation("Bot chat", "bot-session", bot.id);
    const route = "/api/conversations/old/settings";
    for (const effort of ["none", "low", "high", "max", "default", null]) {
      const response = await post(route, { reasoningEffort: effort });
      assert.equal(response.status, 200);
      assert.equal((await response.json()).reasoningEffort, effort);
      assert.equal(store.conversation(other.id)!.reasoningEffort, null);
    }
    for (const effort of ["medium", "ultra", 1, {}, undefined])
      assert.equal((await post(route, { reasoningEffort: effort })).status, 400);
    assert.equal((await post("/api/conversations/missing/settings", { reasoningEffort: "low" })).status, 404);
    provider.model = "unsupported";
    assert.equal((await post(route, { reasoningEffort: "max" })).status, 400);
    provider.model = "deepseek-flash";
    await post(route, { reasoningEffort: "max" });
    const response = await post("/api/conversations/old/messages", { text: "Hello", deviceId: "test", tabId: "test" });
    assert.equal(response.status, 202);
    for (let i = 0; !called && i < 50; i++) await new Promise(resolve => setTimeout(resolve, 10));
    assert.ok(called);
    assert.equal(received, "max");
    assert.equal((await post(route, { reasoningEffort: "low" })).status, 409);
    assert.equal((await post(`/api/conversations/${other.id}/settings`, { reasoningEffort: "low" })).status, 200);
    await workspace.close();
    workspaceClosed = true;
    store.close();
    store = new Store(path);
    assert.equal(store.snapshot("old")!.conversation.reasoningEffort, "max");
    assert.equal(store.conversations().find(chat => chat.id === other.id)!.reasoningEffort, "low");
    assert.equal(store.snapshot("old")!.messages[0].text, "Hello");
  } finally {
    if (!workspaceClosed) await workspace.close();
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
});

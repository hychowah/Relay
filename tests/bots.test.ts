import test, { type TestContext } from "node:test";
import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
import { createWorkspace, type AgentHarness } from "../server/app.ts";
import { Store } from "../server/store.ts";
import type { Inspection } from "../server/harness.ts";
import type { AppContext, Bot, Conversation, Memory, Snapshot, ViewContext } from "../shared/types.ts";

async function until(condition: () => boolean) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await delay(20);
  }
  assert.fail("Expected state did not arrive.");
}

function setup(t: TestContext) {
  const store = new Store(":memory:");
  const apps = ["notes", "research"].map((appId) => ({
    id: appId, name: appId, description: "Synthetic app",
    integration: {
      async search() { return [{ appId, resourceId: "fixture", title: "Fixture", sourceUrl: "https://example.test/fixture" }]; },
      async read() { return {
        source: { appId, resourceId: "fixture", revision: "v1", title: "Fixture", sourceUrl: "https://example.test/fixture" },
        sections: [{ id: "content", title: "Content", text: "Synthetic report." }],
      }; },
    },
  }));
  const workspace = createWorkspace(store, apps, { mode: "fixture", model: "fixture", configured: true });
  const states = new Map<string, Inspection>();
  const prompts: Array<{ sessionId: string; text: string; context?: ViewContext; appContext?: AppContext }> = [];
  const harness: AgentHarness = {
    async deleteSession() {},
    async createSession() {
      const sessionId = `session-${states.size + 1}`;
      states.set(sessionId, { messages: [], status: "idle" });
      return sessionId;
    },
    async prompt(sessionId, text, context, appContext) {
      states.get(sessionId)!.status = "running";
      prompts.push({ sessionId, text, context, appContext });
    },
    async inspect(sessionId) { return states.get(sessionId)!; },
    async interrupt(sessionId) { states.get(sessionId)!.status = "idle"; },
  };
  workspace.setHarness(harness);
  t.after(async () => { await workspace.close(); store.close(); });
  const post = (path: string, body: unknown) => workspace.app.request(path, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  const snapshot = async (id: string): Promise<Snapshot> => {
    const response = await workspace.app.request(`/api/conversations/${id}`);
    assert.equal(response.status, 200);
    return response.json();
  };
  const bot = async (name: string, appIds = ["notes"]): Promise<Bot> => {
    const response = await post("/api/bots", { name, objective: `Help with ${name}`, scope: "Saved material", appIds });
    assert.equal(response.status, 201);
    return response.json();
  };
  const conversation = async (botId?: string): Promise<Conversation> => {
    const response = await post("/api/conversations", { botId });
    assert.equal(response.status, 201);
    return response.json();
  };
  const send = async (id: string, text: string, extra: Record<string, unknown> = {}) => {
    const response = await post(`/api/conversations/${id}/messages`, { text, deviceId: "desktop", tabId: "chat", ...extra });
    assert.equal(response.status, 202);
    const run = await response.json();
    const sessionId = store.sessionId(id)!;
    await until(() => prompts.some((prompt) => prompt.sessionId === sessionId && prompt.text === text));
    return { run, sessionId };
  };
  const finish = async (id: string, reply: string) => {
    const state = states.get(store.sessionId(id)!)!;
    state.messages.push({ id: `reply-${id}-${state.messages.length}`, role: "assistant", text: reply, createdAt: new Date().toISOString() });
    state.status = "idle";
    await until(() => !store.activeRun(id));
  };
  return { workspace, store, post, snapshot, bot, conversation, send, finish, prompts };
}

test("normal chats and bot chats retain session identity and enforce the current bot's app scope", async (t) => {
  const { workspace, store, post, snapshot, bot, conversation, send, prompts } = setup(t);
  const normal = await conversation();
  const helper = await bot("Notes helper");
  const botChat = await conversation(helper.id);
  assert.equal(normal.botId, null);
  assert.equal(botChat.botId, helper.id);
  assert.notEqual(store.sessionId(normal.id), store.sessionId(botChat.id));
  assert.deepEqual(await (await workspace.app.request("/api/bots")).json(), [helper]);
  const edited = await post(`/api/bots/${helper.id}`, { ...helper, objective: "Summarize saved notes" });
  assert.equal(edited.status, 200);

  const report = await (await workspace.app.request("/api/apps/research/read?resourceId=fixture")).json();
  for (const extra of [
    { appContext: { appId: "research", viewToken: "view-1" } },
    { context: { source: report.source, viewToken: "view-1", selection: "Private research" } },
  ]) {
    const denied = await post(`/api/conversations/${botChat.id}/messages`, {
      text: "Explain this", deviceId: "desktop", tabId: "chat", ...extra,
    });
    assert.equal(denied.status, 403);
  }
  assert.deepEqual((await snapshot(botChat.id)).messages, []);
  const normalRun = await send(normal.id, "Discuss anything", { appContext: { appId: "research" } });
  const botRun = await send(botChat.id, "Summarize notes", { appContext: { appId: "notes" } });
  assert.equal(prompts.find((prompt) => prompt.sessionId === botRun.sessionId)!.appContext!.appId, "notes");
  assert.deepEqual(workspace.agentContext(normalRun.sessionId)!.allowedApps.map((app) => app.id), ["notes", "research"]);
  assert.deepEqual(workspace.agentContext(botRun.sessionId)!.allowedApps.map((app) => app.id), ["notes"]);
  assert.equal(workspace.agentContext(botRun.sessionId)!.currentApp!.appId, "notes");
  assert.equal(workspace.agentContext(botRun.sessionId)!.bot!.objective, "Summarize saved notes");
  for (const name of ["app_search", "app_read", "app_navigate"]) {
    const denied = await workspace.toolHandler(botRun.sessionId, name, { ...report.source, sectionId: "content" }) as { error: string };
    assert.match(denied.error, /scope/i);
  }
  assert.equal((await workspace.toolHandler(botRun.sessionId, "app_search", { appId: "notes", query: "fixture" }) as unknown[]).length, 1);
  assert.equal((await workspace.toolHandler(normalRun.sessionId, "app_read", report.source) as { source: { appId: string } }).source.appId, "research");
  assert.equal((await snapshot(botChat.id)).commands.length, 0);
});

test("shared and bot memories are scoped, cite the current user, and preserve corrections and forgetting", async (t) => {
  const { workspace, post, snapshot, bot, conversation, send } = setup(t);
  const first = await bot("First");
  const second = await bot("Second");
  const normal = await conversation();
  const firstChat = await conversation(first.id);
  const secondChat = await conversation(second.id);
  const shared = await (await post("/api/memories", { key: "format", content: "Prefer concise prose" })).json() as Memory;
  const privateMemory = await (await post("/api/memories", { botId: second.id, key: "private task", content: "Second bot only" })).json() as Memory;
  const normalRun = await send(normal.id, "Remember my preferences");
  const firstRun = await send(firstChat.id, "Remember the launch decision");
  const secondRun = await send(secondChat.id, "Recall my task");
  const saved = await workspace.toolHandler(firstRun.sessionId, "memory_save", {
    scope: "bot", key: "launch", content: "Start with notes", sourceMessageId: "untrusted-source",
  }) as Memory;
  const currentUser = (await snapshot(firstChat.id)).messages[0];
  assert.equal(saved.sourceMessageId, currentUser.id);
  assert.equal(saved.sourceConversationId, firstChat.id);
  assert.equal(saved.botId, first.id);
  assert.deepEqual(workspace.agentContext(normalRun.sessionId)!.memories.map((memory) => memory.id), [shared.id]);
  assert.deepEqual(new Set(workspace.agentContext(firstRun.sessionId)!.memories.map((memory) => memory.id)), new Set([shared.id, saved.id]));
  assert.deepEqual(new Set(workspace.agentContext(secondRun.sessionId)!.memories.map((memory) => memory.id)), new Set([shared.id, privateMemory.id]));
  assert.deepEqual(await (await workspace.app.request(`/api/memories?botId=${first.id}`)).json(), [saved]);
  assert.deepEqual(await workspace.toolHandler(firstRun.sessionId, "memory_search", { query: "Second bot" }), []);
  assert.ok((await workspace.toolHandler(firstRun.sessionId, "memory_forget", { id: privateMemory.id }) as { error: string }).error);
  assert.ok((await workspace.toolHandler(normalRun.sessionId, "memory_save", { scope: "bot", key: "task", content: "No bot" }) as { error: string }).error);

  const correction = await post(`/api/memories/${saved.id}`, { content: "Start with research" });
  assert.equal(correction.status, 200);
  assert.equal((await correction.json()).userEdited, true);
  const overwritten = await workspace.toolHandler(firstRun.sessionId, "memory_save", { scope: "bot", key: "launch", content: "Stale decision" }) as { error: string };
  assert.match(overwritten.error, /edited/i);
  assert.equal(workspace.agentContext(firstRun.sessionId)!.memories.find((memory) => memory.id === saved.id)!.content, "Start with research");
  assert.equal((await workspace.app.request(`/api/memories/${saved.id}`, { method: "DELETE" })).status, 200);
  assert.deepEqual(await (await workspace.app.request(`/api/memories?botId=${first.id}`)).json(), []);
  const resurrected = await workspace.toolHandler(firstRun.sessionId, "memory_save", { scope: "bot", key: "launch", content: "Same old decision" }) as { error: string };
  assert.match(resurrected.error, /forgotten/i);
  assert.deepEqual(workspace.agentContext(firstRun.sessionId)!.forgottenKeys, ["launch"]);
  assert.equal(workspace.agentContext(firstRun.sessionId)!.memories.some((memory) => memory.id === saved.id), false);
});

test("forwarding retains a fixed source snapshot and handoff while history tools enforce scopes and page long messages", async (t) => {
  const { workspace, post, snapshot, bot, conversation, send, finish } = setup(t);
  const helper = await bot("Reader");
  const otherBot = await bot("Other");
  const source = await conversation();
  const longText = `needle original detail ${"x".repeat(10000)}`;
  await send(source.id, longText);
  await finish(source.id, "needle original answer");
  const original = await snapshot(source.id);
  const note = "Find the unresolved decision in this conversation.";
  const forwarded = await post(`/api/conversations/${source.id}/forward`, { botId: helper.id, note });
  assert.equal(forwarded.status, 201);
  const target = await forwarded.json() as Conversation;
  assert.equal(target.botId, helper.id);
  const targetSnapshot = await snapshot(target.id);
  assert.equal(targetSnapshot.forwards[0].note, note);
  assert.deepEqual(targetSnapshot.forwards[0].messageIds, original.messages.map((message) => message.id));
  assert.equal(targetSnapshot.messages.length, 0);
  await send(source.id, "needle later private detail");
  await finish(source.id, "Later source answer");
  const later = (await snapshot(source.id)).messages.find((message) => message.text === "needle later private detail")!;
  const neighbor = await conversation(helper.id);
  await send(neighbor.id, "needle same bot detail");
  await finish(neighbor.id, "Same bot answer");
  const foreign = await conversation(otherBot.id);
  await send(foreign.id, "needle other bot secret");
  const unrelated = await conversation();
  await send(unrelated.id, "needle unrelated normal chat");
  const { sessionId } = await send(target.id, "Review the forwarded context");
  const context = workspace.agentContext(sessionId)!;
  assert.equal(context.forwardedConversations[0].handoff, note);
  assert.equal(context.forwardedConversations[0].messageCount, original.messages.length);
  const matches = await workspace.toolHandler(sessionId, "history_search", { query: "needle" }) as Array<{ conversationId: string; messageId: string }>;
  assert.deepEqual(new Set(matches.map((match) => match.conversationId)), new Set([source.id, neighbor.id]));
  assert.equal(matches.some((match) => match.messageId === later.id), false);
  for (const id of [foreign.id, unrelated.id]) {
    assert.match((await workspace.toolHandler(sessionId, "history_read", { conversationId: id }) as { error: string }).error, /scope/i);
  }
  const page = await workspace.toolHandler(sessionId, "history_read", { conversationId: source.id, limit: 1 }) as {
    messages: Array<{ id: string; text: string; nextTextOffset?: number }>; total: number; nextOffset: number;
  };
  assert.equal(page.total, original.messages.length);
  assert.equal(page.nextOffset, 1);
  assert.equal(page.messages[0].nextTextOffset, 2000);
  let recovered = page.messages[0].text;
  let offset: number | undefined = page.messages[0].nextTextOffset;
  while (offset !== undefined) {
    const part = await workspace.toolHandler(sessionId, "history_read", { conversationId: source.id, messageId: page.messages[0].id, textOffset: offset }) as { text: string; nextTextOffset?: number };
    recovered += part.text;
    offset = part.nextTextOffset;
  }
  assert.equal(recovered, longText);
  assert.ok((await workspace.toolHandler(sessionId, "history_read", { conversationId: source.id, messageId: later.id }) as { error: string }).error);
  assert.deepEqual((await snapshot(target.id)).forwards[0].messageIds, original.messages.map((message) => message.id));
  const nextPage = await workspace.toolHandler(sessionId, "history_read", { conversationId: source.id, offset: page.nextOffset }) as { messages: Array<{ id: string }> };
  assert.deepEqual(nextPage.messages.map((message) => message.id), [original.messages[1].id]);
});

test("task checkpoints remain inspectable and are injected when the next request resumes", async (t) => {
  const { workspace, snapshot, bot, conversation, send, finish } = setup(t);
  const helper = await bot("Planner");
  const chat = await conversation(helper.id);
  const first = await send(chat.id, "Plan the remaining task");
  const checkpoint = await workspace.toolHandler(first.sessionId, "checkpoint_save", { content: "Decision: use notes. Next: compare two saved reports." });
  assert.deepEqual((await snapshot(chat.id)).checkpoint, checkpoint);
  await finish(chat.id, "Recorded the next step.");
  assert.equal(workspace.agentContext(first.sessionId), null);
  const resumed = await send(chat.id, "Continue");
  assert.equal(resumed.sessionId, first.sessionId);
  assert.deepEqual(workspace.agentContext(resumed.sessionId)!.checkpoint, checkpoint);
  const inspected = await snapshot(chat.id);
  assert.equal(inspected.messages.length, 3);
  assert.equal(inspected.messages[0].text, "Plan the remaining task");
  assert.equal(inspected.tools[0].name, "checkpoint_save");
  assert.deepEqual(inspected.tools[0].output, checkpoint);
});

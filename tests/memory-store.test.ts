import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Store } from "../server/store.ts";
import type { Message } from "../shared/types.ts";

const botInput = (name: string) => ({ name, objective: "Help research", scope: "Saved reports", appIds: ["research"] });
const message = (id: string, text: string, role: Message["role"] = "user"): Message => ({
  id, text, role, createdAt: new Date().toISOString(),
});

test("legacy records migrate additively and bot memory, forwards and checkpoint survive reopening", async () => {
  const directory = await mkdtemp(join(tmpdir(), "relay-memory-"));
  const path = join(directory, "relay.sqlite");
  const legacy = new DatabaseSync(path);
  legacy.exec(`
    CREATE TABLE conversations (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, title TEXT NOT NULL, created_at TEXT NOT NULL);
    CREATE TABLE messages (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id), data TEXT NOT NULL);
    INSERT INTO conversations VALUES ('old', 'session-old', 'Earlier chat', '2026-11-01');
  `);
  const original = message("old-message", "Remember the earlier detail");
  legacy.prepare("INSERT INTO messages VALUES (?, ?, ?)").run(original.id, "old", JSON.stringify(original));
  legacy.close();
  let store = new Store(path);
  try {
    assert.equal(store.conversation("old")!.botId, null);
    assert.equal(store.sessionId("old"), "session-old");
    assert.deepEqual(store.snapshot("old")!.messages, [original]);
    const bot = store.saveBot(botInput("Research"));
    const conversation = store.createConversation("Bot chat", "bot-session", bot.id);
    store.message(conversation.id, message("preference", "Use tables"));
    const memory = store.saveMemory({ botId: bot.id, key: "format", content: "Use tables", sourceConversationId: conversation.id, sourceMessageId: "preference" }, undefined, true);
    const forgotten = store.saveMemory({ botId: bot.id, key: "earlier-goal", content: "An obsolete goal" });
    store.forgetMemory(forgotten.id);
    const forward = store.addForward("old", conversation.id, "Follow up this research");
    const checkpoint = store.saveCheckpoint(conversation.id, "Compare the remaining reports");
    store.close();
    store = new Store(path);
    assert.deepEqual(store.bot(bot.id), bot);
    assert.deepEqual(store.memories(bot.id), [memory]);
    assert.deepEqual(store.forgottenKeys(conversation.id), ["earlier-goal"]);
    const snapshot = store.snapshot(conversation.id)!;
    assert.deepEqual(snapshot.forwards, [forward]);
    assert.deepEqual(snapshot.checkpoint, checkpoint);
    assert.equal(snapshot.conversation.botId, bot.id);
    assert.deepEqual(store.readHistory(conversation.id, "old").messages, [original]);
    assert.equal(store.createConversation("New normal chat", "normal-session").botId, null);
  } finally {
    store.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("history stays within a bot or normal-chat scope and direct forwards grant only captured messages", () => {
  const store = new Store(":memory:");
  try {
    const botA = store.saveBot(botInput("A"));
    const botB = store.saveBot(botInput("B"));
    const normal = store.createConversation("Normal", "normal");
    const otherNormal = store.createConversation("Other normal", "other-normal");
    const a = store.createConversation("Bot A", "a", botA.id);
    const aSibling = store.createConversation("Bot A sibling", "a-sibling", botA.id);
    const b = store.createConversation("Bot B", "b", botB.id);
    store.message(normal.id, message("normal", "common normal detail"));
    store.message(otherNormal.id, message("other-normal", "common other detail"));
    store.message(a.id, message("a", "common A secret"));
    store.message(aSibling.id, message("a-sibling", "common A sibling"));
    store.message(b.id, message("b", "common B secret"));
    assert.deepEqual(store.searchHistory(a.id, "common").map((match) => match.message.id).sort(), ["a", "a-sibling"]);
    assert.deepEqual(store.searchHistory(normal.id, "common").map((match) => match.message.id).sort(), ["normal", "other-normal"]);
    assert.throws(() => store.readHistory(a.id, b.id), /outside this scope/);
    assert.throws(() => store.readHistory(a.id, normal.id), /outside this scope/);

    // A -> normal -> B must not grant B access to A.
    store.addForward(a.id, normal.id);
    const grant = store.addForward(normal.id, b.id, "Use this existing situation");
    assert.deepEqual(grant.messageIds, ["normal"]);
    store.message(normal.id, message("later", "common future private detail"));
    assert.deepEqual(store.readHistory(b.id, normal.id).messages.map((item) => item.id), ["normal"]);
    assert.equal(store.historyMessage(b.id, normal.id, "normal")!.text, "common normal detail");
    assert.equal(store.historyMessage(b.id, normal.id, "later"), undefined);
    assert.deepEqual(store.searchHistory(b.id, "common").map((match) => match.message.id).sort(), ["b", "normal"]);
    assert.throws(() => store.readHistory(b.id, a.id), /outside this scope/);
    assert.throws(() => store.historyMessage(b.id, a.id, "a"), /outside this scope/);
    assert.throws(() => store.readHistory(b.id, otherNormal.id), /outside this scope/);
    assert.equal(store.searchHistory(b.id, "future").length, 0);
    assert.deepEqual(store.conversations("B secret").map((conversation) => conversation.id), [b.id]);
    assert.deepEqual(store.conversations("Bot A sibling").map((conversation) => conversation.id), [aSibling.id]);

    for (let index = 0; index < 12; index++) store.message(a.id, message(`page-${index}`, `Page ${index}`));
    const first = store.readHistory(aSibling.id, a.id, 0, 10);
    assert.equal(first.total, 13);
    assert.equal(first.messages.length, 10);
    assert.equal(first.nextOffset, 10);
    const second = store.readHistory(aSibling.id, a.id, first.nextOffset, 10);
    assert.equal(second.messages.length, 3);
    assert.equal(second.nextOffset, undefined);
  } finally {
    store.close();
  }
});

test("shared preferences and bot notes respect corrections, sources and forgetting", () => {
  const store = new Store(":memory:");
  try {
    const botA = store.saveBot(botInput("A"));
    const botB = store.saveBot(botInput("B"));
    const normal = store.createConversation("Normal", "normal");
    const a = store.createConversation("A", "a", botA.id);
    const b = store.createConversation("B", "b", botB.id);
    store.message(a.id, message("source-a", "Prefer short answers and prioritize risk"));
    store.message(a.id, message("assistant-a", "Acknowledged", "assistant"));
    store.message(b.id, message("source-b", "A different task"));
    const source = { sourceConversationId: a.id, sourceMessageId: "source-a" };
    const shared = store.saveMemory({ key: "answer-format", content: "Short answers", ...source }, undefined, true);
    const privateNote = store.saveMemory({ botId: botA.id, key: " Research   Goal ", content: "Prioritize risk", ...source }, undefined, true);
    assert.deepEqual(store.visibleMemories(normal.id).map((memory) => memory.id), [shared.id]);
    assert.deepEqual(store.visibleMemories(a.id).map((memory) => memory.id), [shared.id, privateNote.id]);
    assert.deepEqual(store.visibleMemories(b.id).map((memory) => memory.id), [shared.id]);
    assert.throws(() => store.saveMemory({ botId: botB.id, key: "leak", content: "Foreign bot fact", ...source }, undefined, true), /another scope/);
    assert.throws(() => store.saveMemory({ key: "bad-source", content: "Invalid", sourceConversationId: a.id, sourceMessageId: "source-b" }, undefined, true), /does not belong/);
    assert.throws(() => store.saveMemory({ key: "assistant-source", content: "Invalid", sourceConversationId: a.id, sourceMessageId: "assistant-a" }, undefined, true), /source user message/);
    assert.throws(() => store.saveMemory({ key: "missing-source", content: "Invalid" }, undefined, true), /source user message/);

    const corrected = store.saveMemory({ key: shared.key, content: "Give enough detail" }, shared.id);
    assert.equal(corrected.userEdited, true);
    assert.equal(corrected.sourceMessageId, "source-a");
    assert.throws(() => store.saveMemory({ key: shared.key, content: "Short answers", ...source }, shared.id, true), /edited by the user/);
    assert.throws(() => store.saveMemory({ key: shared.key, content: "Short answers", ...source }, undefined, true), /edited by the user/);
    assert.equal(store.visibleMemories(b.id)[0].content, "Give enough detail");

    store.forgetMemory(privateNote.id);
    assert.deepEqual(store.forgottenKeys(a.id), ["research goal"]);
    assert.deepEqual(store.forgottenKeys(b.id), []);
    assert.throws(() => store.saveMemory({ botId: botA.id, key: privateNote.key, content: privateNote.content, ...source }, undefined, true), /forgotten/);
    assert.throws(() => store.saveMemory({ botId: botA.id, key: " RESEARCH   GOAL ", content: privateNote.content, ...source }, undefined, true), /forgotten/);
    const restored = store.saveMemory({ botId: botA.id, key: privateNote.key, content: "Manually restored" });
    assert.equal(restored.userEdited, true);
    assert.deepEqual(store.forgottenKeys(a.id), []);
    store.forgetMemory(shared.id);
    assert.deepEqual(store.forgottenKeys(a.id), [shared.key]);
    assert.deepEqual(store.forgottenKeys(b.id), [shared.key]);
    assert.equal(store.memories().length, 0);
  } finally {
    store.close();
  }
});

import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type {
  Conversation,
  TrashedConversation,
  Message,
  Run,
  Snapshot,
  ToolRecord,
  ViewCommand,
  NavigateCommand,
  PresentCommand,
  Source,
  Report,
  ViewIntent,
  SurfaceContext,
  OperationProgress,
  ViewContext,
  AppContext,
  ViewState,
  Bot,
  BotInput,
  Memory,
  MemoryInput,
  Forward,
  Checkpoint,
  HistoryMatch,
  HistoryPage,
  ReasoningEffort,
} from "../shared/types.ts";

export interface SavedRun extends Run {
  deviceId: string;
  tabId: string;
  context?: ViewContext;
  appContext?: AppContext;
  navigationViewToken?: string;
  navigationSurface?: { appId: string; context?: SurfaceContext };
}

/** A Browser page address with its counts; lastVisit is in epoch milliseconds. */
export interface BrowserPage {
  url: string;
  title: string;
  visits: number;
  typed: number;
  lastVisit: number;
}

/**
 * Text the user highlighted on a page. A web page finds it again by the text
 * and the text around it, so it shows wherever that text is on the page; a
 * PDF also keeps where its lines are drawn.
 */
export interface Highlight {
  id: string;
  text: string;
  prefix: string;
  suffix: string;
  /** PDF only: one [page, x, y, width, height] for each highlighted line. */
  marks?: number[][];
  /** One of [highlightColors]; yellow when absent. */
  color?: string;
}

/**
 * The colours a highlight can have. The Flutter app draws each in its own
 * shade, kept in step in page_highlights.js, BrowserPDF.swift and
 * highlight_menu.dart.
 */
export const highlightColors = ["yellow", "green", "blue", "pink", "purple"];

/** How much one stored-data category holds. */
export interface StoredUsage {
  items: number;
  bytes: number;
}

export interface Device {
  id: string;
  name: string;
  /** The device's tab session as JSON, as its client saved it. */
  tabs: string;
  updatedAt: number;
}

export class Store {
  private db: DatabaseSync;

  constructor(path: string) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL, title TEXT NOT NULL, created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id), data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS captures (
        message_id TEXT PRIMARY KEY REFERENCES messages(id), png BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS runs (
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id), status TEXT NOT NULL, data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS tools (
        id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id), data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS commands (
        id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id), data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS reports (
        app_id TEXT NOT NULL, resource_id TEXT NOT NULL, revision TEXT NOT NULL, data TEXT NOT NULL,
        PRIMARY KEY (app_id, resource_id, revision)
      );
      CREATE TABLE IF NOT EXISTS bots (id TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS memories (
        id TEXT PRIMARY KEY, bot_id TEXT REFERENCES bots(id), key TEXT NOT NULL, data TEXT NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS memory_scope_key ON memories (COALESCE(bot_id, ''), key);
      CREATE TABLE IF NOT EXISTS forgotten_memories (
        scope TEXT NOT NULL, key TEXT NOT NULL, PRIMARY KEY (scope, key)
      );
      CREATE TABLE IF NOT EXISTS forwards (
        id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES conversations(id),
        target_id TEXT NOT NULL REFERENCES conversations(id), data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS checkpoints (
        conversation_id TEXT PRIMARY KEY REFERENCES conversations(id), data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS browser_pages (
        url TEXT PRIMARY KEY, title TEXT NOT NULL, visits INTEGER NOT NULL, typed INTEGER NOT NULL,
        last_visit INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS highlights (
        id TEXT PRIMARY KEY, url TEXT NOT NULL, data TEXT NOT NULL, created_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS highlights_url ON highlights(url);
      CREATE TABLE IF NOT EXISTS stored_data_cleanup (category TEXT PRIMARY KEY, days INTEGER);
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, tabs TEXT NOT NULL, updated_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS current_conversation (
        only INTEGER PRIMARY KEY CHECK (only = 1), id TEXT NOT NULL
      );
    `);
    const columns = this.db.prepare("PRAGMA table_info(conversations)").all();
    if (!columns.some((column) => column.name === "bot_id")) {
      this.db.exec("ALTER TABLE conversations ADD COLUMN bot_id TEXT REFERENCES bots(id)");
    }
    if (!columns.some((column) => column.name === "reasoning_effort")) {
      this.db.exec("ALTER TABLE conversations ADD COLUMN reasoning_effort TEXT");
    }
    if (!columns.some((column) => column.name === "trashed_at")) {
      this.db.exec("ALTER TABLE conversations ADD COLUMN trashed_at TEXT");
    }
  }

  close() {
    this.db.close();
  }

  conversations(query = ""): Conversation[] {
    return this.db
      .prepare(
        `SELECT id, title, bot_id AS botId, reasoning_effort AS reasoningEffort, created_at AS createdAt FROM conversations
        WHERE trashed_at IS NULL AND (instr(lower(title), ?) > 0 OR EXISTS (
          SELECT 1 FROM messages WHERE messages.conversation_id = conversations.id
          AND instr(lower(json_extract(messages.data, '$.text')), ?) > 0
        )) ORDER BY rowid DESC`,
      )
      .all(query.trim().toLowerCase(), query.trim().toLowerCase()) as unknown as Conversation[];
  }

  conversation(id: string, includeTrash = false): Conversation | undefined {
    return this.db.prepare(
      "SELECT id, title, bot_id AS botId, reasoning_effort AS reasoningEffort, created_at AS createdAt FROM conversations WHERE id = ? AND (? OR trashed_at IS NULL)",
    ).get(id, Number(includeTrash)) as unknown as Conversation | undefined;
  }

  trash(): TrashedConversation[] {
    return this.db.prepare(`SELECT id, title, bot_id AS botId, reasoning_effort AS reasoningEffort,
      created_at AS createdAt, trashed_at AS trashedAt FROM conversations
      WHERE trashed_at IS NOT NULL ORDER BY trashed_at DESC`).all() as unknown as TrashedConversation[];
  }

  trashConversation(id: string) {
    this.db.prepare("UPDATE conversations SET trashed_at = COALESCE(trashed_at, ?) WHERE id = ?")
      .run(new Date().toISOString(), id);
  }

  restoreConversation(id: string): Conversation | undefined {
    this.db.prepare("UPDATE conversations SET trashed_at = NULL WHERE id = ? AND trashed_at > ?")
      .run(id, new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString());
    return this.conversation(id);
  }

  expiredTrash(): Array<{ id: string; sessionId: string }> {
    return this.db.prepare("SELECT id, session_id AS sessionId FROM conversations WHERE trashed_at <= ?")
      .all(new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()) as unknown as Array<{ id: string; sessionId: string }>;
  }

  bots(): Bot[] {
    return this.db.prepare("SELECT data FROM bots ORDER BY rowid")
      .all().map((row) => JSON.parse(row.data as string));
  }

  bot(id: string): Bot | undefined {
    const row = this.db.prepare("SELECT data FROM bots WHERE id = ?").get(id);
    return row ? JSON.parse(row.data as string) : undefined;
  }

  saveBot(input: BotInput, id?: string): Bot {
    const existing = id ? this.bot(id) : undefined;
    if (id && !existing) throw new Error("Bot not found");
    const now = new Date().toISOString();
    const bot: Bot = {
      ...input, appIds: [...input.appIds], id: id ?? randomUUID(),
      createdAt: existing?.createdAt ?? now, updatedAt: now,
    };
    this.db.prepare("INSERT INTO bots VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data")
      .run(bot.id, JSON.stringify(bot));
    return bot;
  }

  createConversation(
    title: string, sessionId: string, botId: string | null = null, reasoningEffort: ReasoningEffort | null = null,
  ): Conversation {
    const conversation = {
      id: randomUUID(),
      title,
      botId,
      reasoningEffort,
      createdAt: new Date().toISOString(),
    };
    this.db
      .prepare("INSERT INTO conversations (id, session_id, title, created_at, bot_id, reasoning_effort) VALUES (?, ?, ?, ?, ?, ?)")
      .run(conversation.id, sessionId, title, conversation.createdAt, botId, reasoningEffort);
    return conversation;
  }

  sessionId(conversationId: string): string | undefined {
    return this.db
      .prepare("SELECT session_id FROM conversations WHERE id = ?")
      .get(conversationId)?.session_id as string | undefined;
  }

  setReasoningEffort(id: string, effort: ReasoningEffort | null): Conversation {
    this.requireConversation(id);
    this.db.prepare("UPDATE conversations SET reasoning_effort = ? WHERE id = ?").run(effort, id);
    return this.conversation(id)!;
  }

  renameConversation(id: string, title: string) {
    this.db
      .prepare("UPDATE conversations SET title = ? WHERE id = ?")
      .run(title, id);
  }

  deleteConversation(id: string) {
    this.db.exec("BEGIN");
    try {
      this.db.prepare("DELETE FROM tools WHERE run_id IN (SELECT id FROM runs WHERE conversation_id = ?)").run(id);
      this.db.prepare("DELETE FROM commands WHERE run_id IN (SELECT id FROM runs WHERE conversation_id = ?)").run(id);
      this.db.prepare("DELETE FROM runs WHERE conversation_id = ?").run(id);
      this.db.prepare("DELETE FROM captures WHERE message_id IN (SELECT id FROM messages WHERE conversation_id = ?)").run(id);
      this.db.prepare("DELETE FROM messages WHERE conversation_id = ?").run(id);
      this.db.prepare("DELETE FROM checkpoints WHERE conversation_id = ?").run(id);
      this.db.prepare("DELETE FROM forwards WHERE source_id = ? OR target_id = ?").run(id, id);
      this.db.prepare(`UPDATE memories SET data = json_remove(data, '$.sourceConversationId', '$.sourceMessageId')
        WHERE json_extract(data, '$.sourceConversationId') = ?`).run(id);
      this.db.prepare("DELETE FROM conversations WHERE id = ?").run(id);
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  memories(botId: string | null = null): Memory[] {
    return this.db.prepare("SELECT data FROM memories WHERE bot_id IS ? ORDER BY rowid")
      .all(botId).map((row) => JSON.parse(row.data as string));
  }

  visibleMemories(conversationId: string): Memory[] {
    const conversation = this.requireConversation(conversationId);
    return conversation.botId === null
      ? this.memories()
      : [...this.memories(), ...this.memories(conversation.botId)];
  }

  saveMemory(input: MemoryInput, id?: string, fromAgent = false): Memory {
    const row = id ? this.db.prepare("SELECT data FROM memories WHERE id = ?").get(id) : undefined;
    const existing: Memory | undefined = row ? JSON.parse(row.data as string) : undefined;
    if (id && !existing) throw new Error("Memory not found");
    const botId = input.botId === undefined ? existing?.botId ?? null : input.botId;
    if (botId !== null && !this.bot(botId)) throw new Error("Bot not found");
    const key = input.key.trim().toLowerCase().replace(/\s+/g, " ");
    if (!key || !input.content.trim()) throw new Error("Memory key and content are required");
    if (existing && (existing.botId !== botId || existing.key !== key)) {
      throw new Error("Memory scope and stable key cannot change");
    }
    const sameKey = this.memories(botId).find((memory) => memory.key === key);
    const previous = existing ?? sameKey;
    if (fromAgent && previous?.userEdited) throw new Error("This memory was edited by the user");
    if (fromAgent && this.db.prepare("SELECT key FROM forgotten_memories WHERE scope = ? AND key = ?")
      .get(botId ?? "", key)) throw new Error("This memory was forgotten by the user");
    const sourceConversationId = input.sourceConversationId ?? previous?.sourceConversationId;
    const sourceMessageId = input.sourceMessageId ?? previous?.sourceMessageId;
    if (fromAgent && (!input.sourceConversationId || !input.sourceMessageId)) {
      throw new Error("Agent memory requires a source user message");
    }
    if (sourceConversationId) {
      const source = this.conversation(sourceConversationId, true);
      if (!source) throw new Error("Conversation not found");
      if (botId !== null && source.botId !== botId) throw new Error("Memory source belongs to another scope");
    }
    if (sourceMessageId) {
      const sourceRow = this.db.prepare("SELECT conversation_id, data FROM messages WHERE id = ?").get(sourceMessageId);
      if (!sourceRow || sourceRow.conversation_id !== sourceConversationId) {
        throw new Error("Memory source message does not belong to its conversation");
      }
      if (fromAgent && (JSON.parse(sourceRow.data as string) as Message).role !== "user") {
        throw new Error("Agent memory requires a source user message");
      }
    }
    const now = new Date().toISOString();
    const memory: Memory = {
      id: previous?.id ?? randomUUID(), botId, key, content: input.content,
      sourceConversationId, sourceMessageId,
      createdAt: previous?.createdAt ?? now, updatedAt: now,
      userEdited: !fromAgent || previous?.userEdited === true,
    };
    this.db.exec("BEGIN");
    try {
      this.db.prepare("INSERT INTO memories VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data")
        .run(memory.id, botId, key, JSON.stringify(memory));
      if (!fromAgent) this.db.prepare("DELETE FROM forgotten_memories WHERE scope = ? AND key = ?")
        .run(botId ?? "", key);
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
    return memory;
  }

  forgetMemory(id: string) {
    const row = this.db.prepare("SELECT bot_id, key FROM memories WHERE id = ?").get(id);
    if (!row) throw new Error("Memory not found");
    this.db.exec("BEGIN");
    try {
      this.db.prepare("INSERT OR IGNORE INTO forgotten_memories VALUES (?, ?)").run(row.bot_id ?? "", row.key);
      this.db.prepare("DELETE FROM memories WHERE id = ?").run(id);
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  /** Adds one visit, or one address-bar open, to the page's row. Either may arrive first. */
  countBrowserPage(url: string, at: number, kind: "visit" | "typed", title = "") {
    const visit = kind === "visit" ? 1 : 0;
    this.db.prepare(`INSERT INTO browser_pages VALUES (?, ?, ?, ?, ?) ON CONFLICT(url) DO UPDATE SET
      visits = visits + excluded.visits, typed = typed + excluded.typed,
      title = CASE excluded.title WHEN '' THEN title ELSE excluded.title END,
      last_visit = CASE excluded.visits WHEN 0 THEN last_visit ELSE excluded.last_visit END`)
      .run(url, title, visit, 1 - visit, at);
  }

  retitleBrowserPage(url: string, title: string) {
    this.db.prepare("UPDATE browser_pages SET title = ? WHERE url = ?").run(title, url);
  }

  browserPages(): BrowserPage[] {
    return this.db.prepare("SELECT url, title, visits, typed, last_visit AS lastVisit FROM browser_pages ORDER BY rowid")
      .all() as unknown as BrowserPage[];
  }

  /** Forgets the given pages, or every page. */
  forgetBrowserPages(urls?: string[]) {
    if (!urls) {
      this.db.exec("DELETE FROM browser_pages");
      return;
    }
    const forget = this.db.prepare("DELETE FROM browser_pages WHERE url = ?");
    this.db.exec("BEGIN");
    try {
      for (const url of urls) forget.run(url);
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  forgetBrowserPagesBefore(at: number) {
    this.db.prepare("DELETE FROM browser_pages WHERE last_visit < ?").run(at);
  }

  /** What the history holds, or only the pages last visited before [before]. */
  browserPagesUsage(before = Infinity) {
    return this.db.prepare(`SELECT COUNT(*) AS items,
      COALESCE(SUM(LENGTH(CAST(url AS BLOB)) + LENGTH(CAST(title AS BLOB))), 0) AS bytes
      FROM browser_pages WHERE last_visit < ?`).get(before) as unknown as StoredUsage;
  }

  /** The highlights made at a page address, oldest first. */
  highlights(url: string): Highlight[] {
    return this.db.prepare("SELECT id, data FROM highlights WHERE url = ? ORDER BY created_at, rowid").all(url)
      .map((row) => ({ ...JSON.parse(row.data as string), id: row.id as string }));
  }

  addHighlight(url: string, { id, ...data }: Highlight, at: number) {
    this.db.prepare("INSERT OR REPLACE INTO highlights VALUES (?, ?, ?, ?)").run(id, url, JSON.stringify(data), at);
  }

  /** Whether the highlight [id] was there to change. */
  recolorHighlight(id: string, color: string) {
    return this.db.prepare("UPDATE highlights SET data = json_set(data, '$.color', ?) WHERE id = ?")
      .run(color, id).changes > 0;
  }

  forgetHighlight(id: string) {
    this.db.prepare("DELETE FROM highlights WHERE id = ?").run(id);
  }

  /** Forgets every highlight, or those made before [before]. */
  forgetHighlights(before?: number) {
    if (before === undefined) this.db.exec("DELETE FROM highlights");
    else this.db.prepare("DELETE FROM highlights WHERE created_at < ?").run(before);
  }

  /** What the highlights hold, or only those made before [before]. */
  highlightsUsage(before = Infinity) {
    return this.db.prepare(`SELECT COUNT(*) AS items,
      COALESCE(SUM(LENGTH(CAST(url AS BLOB)) + LENGTH(CAST(data AS BLOB))), 0) AS bytes
      FROM highlights WHERE created_at < ?`).get(before) as unknown as StoredUsage;
  }

  saveDevice(id: string, name: string, tabs: string, at: number) {
    this.db.prepare(`INSERT INTO devices VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
      name = excluded.name, tabs = excluded.tabs, updated_at = excluded.updated_at`).run(id, name, tabs, at);
  }

  /** Every device's last saved tabs, most recently updated first. */
  devices(): Device[] {
    return this.db.prepare("SELECT id, name, tabs, updated_at AS updatedAt FROM devices ORDER BY updated_at DESC")
      .all() as unknown as Device[];
  }

  setCurrentConversation(id: string) {
    this.db.prepare(`INSERT INTO current_conversation VALUES (1, ?)
      ON CONFLICT(only) DO UPDATE SET id = excluded.id`).run(id);
  }

  /** The conversation last opened on any device, unless it has since gone to Trash. */
  currentConversation(): string | undefined {
    const row = this.db.prepare("SELECT id FROM current_conversation").get();
    return row && this.conversation(row.id as string) ? row.id as string : undefined;
  }

  /** The days a stored-data category is kept: null for ever, undefined when never chosen. */
  cleanupDays(category: string): number | null | undefined {
    const row = this.db.prepare("SELECT days FROM stored_data_cleanup WHERE category = ?").get(category);
    return row ? row.days as number | null : undefined;
  }

  setCleanupDays(category: string, days: number | null) {
    this.db.prepare(`INSERT INTO stored_data_cleanup VALUES (?, ?)
      ON CONFLICT(category) DO UPDATE SET days = excluded.days`).run(category, days);
  }

  forgottenKeys(conversationId: string): string[] {
    const conversation = this.requireConversation(conversationId);
    return this.db.prepare("SELECT DISTINCT key FROM forgotten_memories WHERE scope = '' OR scope = ? ORDER BY key")
      .all(conversation.botId ?? "").map((row) => row.key as string);
  }

  addForward(sourceId: string, targetId: string, note = ""): Forward {
    const source = this.requireConversation(sourceId);
    this.requireConversation(targetId);
    if (sourceId === targetId) throw new Error("Choose another conversation to forward");
    const forward: Forward = {
      id: randomUUID(), sourceConversationId: sourceId, targetConversationId: targetId,
      sourceTitle: source.title, note, createdAt: new Date().toISOString(),
      messageIds: this.db.prepare("SELECT id FROM messages WHERE conversation_id = ? ORDER BY rowid")
        .all(sourceId).map((row) => row.id as string),
    };
    this.db.prepare("INSERT INTO forwards VALUES (?, ?, ?, ?)")
      .run(forward.id, sourceId, targetId, JSON.stringify(forward));
    return forward;
  }

  forwards(conversationId: string): Forward[] {
    return this.db.prepare(`SELECT forwards.data FROM forwards JOIN conversations ON conversations.id = forwards.source_id
      WHERE target_id = ? AND conversations.trashed_at IS NULL ORDER BY forwards.rowid`)
      .all(conversationId).map((row) => JSON.parse(row.data as string));
  }

  searchHistory(requesterConversationId: string, query: string): HistoryMatch[] {
    const requester = this.requireConversation(requesterConversationId);
    const term = query.trim().toLowerCase();
    if (!term) return [];
    const rows = this.db.prepare(`
      SELECT messages.data, conversations.id, conversations.title FROM messages
      JOIN conversations ON conversations.id = messages.conversation_id
      WHERE conversations.trashed_at IS NULL AND (conversations.bot_id IS ? OR EXISTS (
        SELECT 1 FROM forwards, json_each(forwards.data, '$.messageIds') AS forwarded
        WHERE forwards.target_id = ? AND forwards.source_id = conversations.id AND forwarded.value = messages.id
      )) AND instr(lower(json_extract(messages.data, '$.text')), ?) > 0
      ORDER BY messages.rowid DESC LIMIT 30
    `).all(requester.botId, requesterConversationId, term);
    return rows.map((row) => {
      const message = JSON.parse(row.data as string) as Message;
      const start = Math.max(0, message.text.toLowerCase().indexOf(term) - 80);
      return {
        conversationId: row.id as string, conversationTitle: row.title as string,
        message, snippet: message.text.slice(start, start + 320),
      };
    });
  }

  readHistory(requesterId: string, targetId: string, offset = 0, limit = 10): HistoryPage {
    const requester = this.requireConversation(requesterId);
    const conversation = this.requireConversation(targetId);
    const directForwards = this.forwards(requesterId).filter((forward) => forward.sourceConversationId === targetId);
    const sameScope = requester.botId === conversation.botId;
    if (!sameScope && !directForwards.length) throw new Error("Conversation is outside this scope");
    const start = Math.max(0, Math.trunc(offset) || 0);
    const size = Math.min(50, Math.max(1, Math.trunc(limit) || 10));
    const access = `conversation_id = ? AND (? OR EXISTS (
      SELECT 1 FROM forwards, json_each(forwards.data, '$.messageIds') AS forwarded
      WHERE forwards.target_id = ? AND forwards.source_id = messages.conversation_id AND forwarded.value = messages.id
    ))`;
    const parameters = [targetId, sameScope ? 1 : 0, requesterId];
    const total = this.db.prepare(`SELECT count(*) AS total FROM messages WHERE ${access}`)
      .get(...parameters)!.total as number;
    const page = this.db.prepare(`SELECT data FROM messages WHERE ${access} ORDER BY rowid LIMIT ? OFFSET ?`)
      .all(...parameters, size, start).map((row) => JSON.parse(row.data as string) as Message);
    return {
      conversation, messages: page, total,
      ...(start + page.length < total ? { nextOffset: start + page.length } : {}),
    };
  }

  historyMessage(requesterId: string, targetId: string, messageId: string): Message | undefined {
    const requester = this.requireConversation(requesterId);
    const target = this.requireConversation(targetId);
    const directForwards = this.forwards(requesterId).filter((forward) => forward.sourceConversationId === targetId);
    const sameScope = requester.botId === target.botId;
    if (!sameScope && !directForwards.length) throw new Error("Conversation is outside this scope");
    if (!sameScope && !directForwards.some((forward) => forward.messageIds.includes(messageId))) {
      return undefined;
    }
    const row = this.db.prepare("SELECT data FROM messages WHERE conversation_id = ? AND id = ?").get(targetId, messageId);
    return row ? JSON.parse(row.data as string) : undefined;
  }

  checkpoint(conversationId: string): Checkpoint | undefined {
    const row = this.db.prepare("SELECT data FROM checkpoints WHERE conversation_id = ?").get(conversationId);
    return row ? JSON.parse(row.data as string) : undefined;
  }

  saveCheckpoint(conversationId: string, content: string): Checkpoint {
    this.requireConversation(conversationId);
    const checkpoint = { content, updatedAt: new Date().toISOString() };
    this.db.prepare("INSERT INTO checkpoints VALUES (?, ?) ON CONFLICT(conversation_id) DO UPDATE SET data = excluded.data")
      .run(conversationId, JSON.stringify(checkpoint));
    return checkpoint;
  }

  private requireConversation(id: string): Conversation {
    const conversation = this.conversation(id);
    if (!conversation) throw new Error("Conversation not found");
    return conversation;
  }

  message(conversationId: string, message: Message) {
    this.db
      .prepare(
        "INSERT INTO messages VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data",
      )
      .run(message.id, conversationId, JSON.stringify(message));
  }

  startRun(
    conversationId: string,
    text: string,
    deviceId: string,
    tabId: string,
    context?: ViewContext,
    appContext?: AppContext,
    capture?: Uint8Array,
  ): SavedRun {
    const run: SavedRun = {
      id: randomUUID(),
      conversationId,
      deviceId,
      tabId,
      context,
      appContext,
      status: "running",
      startedAt: new Date().toISOString(),
    };
    this.db.exec("BEGIN");
    try {
      const messageId = randomUUID();
      this.message(conversationId, {
        id: messageId,
        role: "user",
        ...(capture ? {hasCapture: true} : {}),
        text,
        context,
        appContext,
        createdAt: run.startedAt,
      });
      if (capture) this.db.prepare("INSERT INTO captures VALUES (?, ?)").run(messageId, capture);
      this.db
        .prepare("INSERT INTO runs VALUES (?, ?, ?, ?)")
        .run(run.id, conversationId, run.status, JSON.stringify(run));
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
    return run;
  }

  capture(conversationId: string, messageId: string): Uint8Array<ArrayBuffer> | undefined {
    return this.db.prepare(`SELECT png FROM captures
      JOIN messages ON messages.id = captures.message_id
      JOIN conversations ON conversations.id = messages.conversation_id
      WHERE captures.message_id = ? AND conversations.id = ? AND conversations.trashed_at IS NULL`)
      .get(messageId, conversationId)?.png as Uint8Array<ArrayBuffer> | undefined;
  }

  run(id: string): SavedRun | undefined {
    const row = this.db.prepare("SELECT data FROM runs WHERE id = ?").get(id);
    return row ? JSON.parse(row.data as string) : undefined;
  }

  activeRun(conversationId: string): SavedRun | undefined {
    const row = this.db
      .prepare(
        "SELECT data FROM runs WHERE conversation_id = ? AND status = 'running'",
      )
      .get(conversationId);
    return row ? JSON.parse(row.data as string) : undefined;
  }

  activeSessionRun(sessionId: string): SavedRun | undefined {
    const row = this.db
      .prepare(
        "SELECT runs.data FROM runs JOIN conversations ON conversations.id = runs.conversation_id WHERE conversations.session_id = ? AND runs.status = 'running'",
      )
      .get(sessionId);
    return row ? JSON.parse(row.data as string) : undefined;
  }

  finishRun(
    id: string,
    status: Run["status"],
    error?: string,
    usage?: Record<string, number>,
  ) {
    const run = this.run(id);
    if (!run || run.status !== "running") return;
    Object.assign(run, {
      status,
      error,
      usage,
      finishedAt: new Date().toISOString(),
    });
    this.db
      .prepare("UPDATE runs SET status = ?, data = ? WHERE id = ?")
      .run(status, JSON.stringify(run), id);
    if (status !== "completed") {
      const rows = this.db.prepare("SELECT id FROM tools WHERE run_id = ?").all(id);
      for (const row of rows) this.finishTool(row.id as string, {
        error: error ?? `The request was ${status}.`,
      });
    }
  }

  recover() {
    const rows = this.db
      .prepare("SELECT id FROM runs WHERE status = 'running'")
      .all();
    for (const row of rows) {
      this.finishRun(
        row.id as string,
        "interrupted",
        "Relay stopped before this run finished. Send a new message to continue.",
      );
      this.failPendingCommands(
        row.id as string,
        "The originating run was interrupted.",
      );
    }
  }

  startTool(runId: string, name: string, input: unknown): ToolRecord {
    const record: ToolRecord = {
      id: randomUUID(),
      runId,
      name,
      input,
      output: null,
      status: "running",
      createdAt: new Date().toISOString(),
    };
    this.db
      .prepare("INSERT INTO tools VALUES (?, ?, ?)")
      .run(record.id, runId, JSON.stringify(record));
    return record;
  }

  finishTool(id: string, output: unknown): ToolRecord | undefined {
    const row = this.db.prepare("SELECT data FROM tools WHERE id = ?").get(id);
    if (!row) return;
    const record: ToolRecord = JSON.parse(row.data as string);
    if (record.status !== "running") return record;
    Object.assign(record, { status: "completed", output });
    this.db.prepare("UPDATE tools SET data = ? WHERE id = ?")
      .run(JSON.stringify(record), id);
    return record;
  }

  recordProgress(id: string, progress: OperationProgress) {
    const row = this.db.prepare("SELECT data FROM tools WHERE id = ?").get(id);
    if (!row) return;
    const record: ToolRecord = JSON.parse(row.data as string);
    if (record.status !== "running") return;
    record.progress = [...(record.progress ?? []), progress];
    this.db.prepare("UPDATE tools SET data = ? WHERE id = ?").run(JSON.stringify(record), id);
  }

  createPresentation(run: SavedRun, appId: string, intent: ViewIntent): PresentCommand {
    const current = this.run(run.id) ?? run;
    const previous = current.navigationSurface
      ? current.navigationSurface.appId === appId ? current.navigationSurface.context : undefined
      : run.appContext?.appId === appId ? run.appContext.surface : undefined;
    const command: PresentCommand = {
      kind: "present", id: randomUUID(), runId: run.id, deviceId: run.deviceId, tabId: run.tabId,
      expectedViewToken: current.navigationViewToken ?? run.context?.viewToken ?? run.appContext?.viewToken ?? null,
      appId, intent, expectedGeneration: previous?.generation ?? 0, status: "pending",
    };
    this.db.prepare("INSERT INTO commands VALUES (?, ?, ?)").run(command.id, run.id, JSON.stringify(command));
    return command;
  }

  createCommand(
    run: SavedRun,
    source: Source,
    sectionId: string,
    viewState?: ViewState,
    highlightIds?: string[],
  ): NavigateCommand {
    const currentRun = this.run(run.id) ?? run;
    const command: NavigateCommand = {
      kind: "navigate",
      id: randomUUID(),
      runId: run.id,
      deviceId: run.deviceId,
      tabId: run.tabId,
      expectedViewToken:
        currentRun.navigationViewToken ?? run.context?.viewToken ?? run.appContext?.viewToken ?? null,
      source,
      sectionId,
      viewState,
      highlightIds,
      status: "pending",
    };
    this.db
      .prepare("INSERT INTO commands VALUES (?, ?, ?)")
      .run(command.id, command.runId, JSON.stringify(command));
    return command;
  }

  command(id: string): ViewCommand | undefined {
    const row = this.db
      .prepare("SELECT data FROM commands WHERE id = ?")
      .get(id);
    return row ? this.normalizeCommand(JSON.parse(row.data as string)) : undefined;
  }

  private normalizeCommand(command: ViewCommand): ViewCommand {
    return "kind" in command ? command : { ...command as object, kind: "navigate" } as ViewCommand;
  }

  acknowledge(
    id: string,
    status: ViewCommand["status"],
    error?: string,
    viewToken?: string,
    context?: SurfaceContext,
  ): ViewCommand | undefined {
    const command = this.command(id);
    if (!command || command.status !== "pending") return command;
    Object.assign(command, { status, error, ...(command.kind === "present" && context ? { context } : {}) });
    this.db
      .prepare("UPDATE commands SET data = ? WHERE id = ?")
      .run(JSON.stringify(command), id);
    if (status === "applied" || (status === "failed" && command.kind === "present" && context && viewToken)) {
      const run = this.run(command.runId)!;
      if (viewToken !== undefined) run.navigationViewToken = viewToken;
      if (command.kind === "present" && context) run.navigationSurface = { appId: command.appId, context };
      if (command.kind === "navigate") run.navigationSurface = { appId: command.source.appId };
      this.db.prepare("UPDATE runs SET data = ? WHERE id = ?")
        .run(JSON.stringify(run), run.id);
    }
    return command;
  }

  failPendingCommands(runId: string, error: string) {
    const rows = this.db
      .prepare("SELECT data FROM commands WHERE run_id = ?")
      .all(runId);
    for (const row of rows) {
      const command = JSON.parse(row.data as string) as ViewCommand;
      this.acknowledge(command.id, "failed", error);
    }
  }

  saveReport(report: Report) {
    const { appId, resourceId, revision } = report.source;
    this.db
      .prepare("INSERT OR IGNORE INTO reports VALUES (?, ?, ?, ?)")
      .run(appId, resourceId, revision, JSON.stringify(report));
  }

  report(
    appId: string,
    resourceId: string,
    revision: string,
  ): Report | undefined {
    const row = this.db
      .prepare(
        "SELECT data FROM reports WHERE app_id = ? AND resource_id = ? AND revision = ?",
      )
      .get(appId, resourceId, revision);
    return row ? JSON.parse(row.data as string) : undefined;
  }

  snapshot(conversationId: string): Snapshot | undefined {
    const conversation = this.conversation(conversationId);
    if (!conversation) return undefined;
    const read = <T>(sql: string): T[] =>
      this.db
        .prepare(sql)
        .all(conversationId)
        .map((row) => JSON.parse(row.data as string));
    return {
      conversation,
      forwards: this.forwards(conversationId),
      checkpoint: this.checkpoint(conversationId),
      messages: read<Message>(
        "SELECT data FROM messages WHERE conversation_id = ? ORDER BY rowid",
      ),
      runs: read<Run>(
        "SELECT data FROM runs WHERE conversation_id = ? ORDER BY rowid",
      ),
      tools: read<ToolRecord>(
        "SELECT tools.data FROM tools JOIN runs ON tools.run_id = runs.id WHERE runs.conversation_id = ? ORDER BY tools.rowid",
      ),
      commands: read<ViewCommand>(
        "SELECT commands.data FROM commands JOIN runs ON commands.run_id = runs.id WHERE runs.conversation_id = ? ORDER BY commands.rowid",
      ).map((command) => this.normalizeCommand(command)),
    };
  }
}

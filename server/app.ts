import { Hono } from "hono";
import { HTTPException } from "hono/http-exception";
import { setTimeout as delay } from "node:timers/promises";
import type {
  Report,
  AppContext,
  AppView,
  Resource,
  ViewState,
  ViewContext,
  WorkspaceConfig,
  ProviderSettings, ProviderMode, ProviderModel, ProviderModelRequest,
  ProviderUpdate,
  BotInput,
  Memory,
  Operation, OperationResult, OperationProgress, ViewIntent, SurfaceContext, ReasoningEffort,
} from "../shared/types.ts";
import type { Harness } from "./harness.ts";
import { AppRequestError } from "./integrations/http.ts";
import type { ToolName } from "./agent-tools.ts";
import { Store, type SavedRun } from "./store.ts";
import { isProviderMode, reasoningEfforts, supportsImageInput, supportsReasoningEffort } from "../shared/provider.ts";

export interface AppIntegration {
  search?(query: string): Promise<Resource[]>;
  read?(resourceId: string, revision?: string): Promise<Report>;
  discover?(signal?: AbortSignal): Promise<{ instructions?: string; operations: Operation[] }>;
  // Request cancellation disconnects upstream work without asserting remote completion.
  call?(operation: string, args: Record<string, unknown>, options: { signal?: AbortSignal; onProgress?: (progress: OperationProgress) => void }): Promise<OperationResult>;
  open?(token: string, parentOrigin: string): Promise<AppView>;
  view?(
    report: Report,
    token: string,
    parentOrigin: string,
  ): Promise<AppView>;
}

export interface RegisteredApp {
  id: string;
  name: string;
  description: string;
  instructions?: string;
  resourceId?: string;
  protocolVersion?: 2;
  capabilities?: Record<string, boolean>;
  integration: AppIntegration;
}

export type AgentHarness = Pick<
  Harness,
  "createSession" | "deleteSession" | "prompt" | "inspect" | "interrupt"
>;

export interface ProviderControls {
  get(mode?: ProviderMode): ProviderSettings;
  models(input: ProviderModelRequest, signal?: AbortSignal): Promise<ProviderModel[]>;
  update(input: ProviderUpdate): Promise<ProviderSettings>;
}

const textField = (value: unknown, name: string): string => {
  if (typeof value !== "string" || !value.trim())
    throw new HTTPException(400, { message: `${name} is required.` });
  return value;
};

const jsonObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

function viewIntent(value: unknown, appId: string): ViewIntent {
  if (!jsonObject(value)) throw new HTTPException(400, { message: "intent is required." });
  textField(value.viewId, "viewId");
  if ((value.explanation !== undefined && (typeof value.explanation !== "string" || !value.explanation.trim() || value.explanation.length > 600)) ||
    (value.state !== undefined && !jsonObject(value.state)) ||
    (value.targetIds !== undefined && (!Array.isArray(value.targetIds) || value.targetIds.some((id) => typeof id !== "string"))) ||
    (value.source !== undefined && (!jsonObject(value.source) || value.source.appId !== appId ||
      ["resourceId", "revision", "title", "sourceUrl"].some((key) => typeof (value.source as Record<string, unknown>)[key] !== "string"))))
    throw new HTTPException(400, { message: "Invalid app view intent." });
  return value as unknown as ViewIntent;
}

function surfaceContext(value: unknown, appId: string): SurfaceContext {
  const intent = viewIntent(value, appId);
  const context = value as SurfaceContext;
  if (!Number.isSafeInteger(context.generation) || context.generation < 0 ||
    (context.selection !== undefined && typeof context.selection !== "string"))
    throw new HTTPException(400, { message: "Invalid app view context." });
  return { ...intent, generation: context.generation };
}

const publicReport = ({ source, sections }: Report): Report => ({
  source,
  sections,
});

export function createWorkspace(
  store: Store,
  apps: () => RegisteredApp[],
  provider: WorkspaceConfig["provider"],
  providerControls?: ProviderControls,
) {
  const app = new Hono();
  const tasks = new Set<Promise<void>>();
  const admissions = new Map<string, Promise<void>>();
  const cancelling = new Set<string>();
  let trashCleanup: Promise<void> | undefined;
  const controllers = new Map<string, AbortController>();
  let harness: AgentHarness;
  let stopping = false;
  let changingProvider = false;

  async function purgeTrash() {
    if (trashCleanup) return trashCleanup;
    if (stopping || changingProvider) return;
    const task = (async () => {
      for (const conversation of store.expiredTrash()) {
        if (stopping) break;
        try {
          await harness.deleteSession(conversation.sessionId);
          store.deleteConversation(conversation.id);
        } catch {
          console.warn("Trash cleanup could not finish; it will retry on the next pass.");
        }
      }
    })();
    trashCleanup = task;
    tasks.add(task);
    try { await task; }
    finally { tasks.delete(task); trashCleanup = undefined; }
  }

  function reasoningEffort(effort: unknown): ReasoningEffort | null {
    if (effort !== null && !reasoningEfforts.includes(effort as ReasoningEffort))
      throw new HTTPException(400, { message: "Choose a supported thinking effort." });
    if (effort !== null && effort !== "default" && !supportsReasoningEffort(provider.mode, provider.model))
      throw new HTTPException(400, { message: "This model does not support thinking effort." });
    return effort as ReasoningEffort | null;
  }

  function integration(appId: string) {
    const entry = apps().find((item) => item.id === appId);
    if (!entry)
      throw new HTTPException(404, { message: "App is not registered." });
    return entry.integration;
  }

  function botFor(conversationId: string) {
    const id = store.conversation(conversationId)?.botId;
    return id ? store.bot(id) : undefined;
  }

  function appScope(conversationId: string) {
    const bot = botFor(conversationId);
    return (appId: string) => !bot || bot.appIds.includes(appId);
  }

  function allowedApp(conversationId: string, appId: string) {
    if (!appScope(conversationId)(appId))
      throw new HTTPException(403, { message: "This app is outside the bot's scope." });
    return integration(appId);
  }

  function matchingMemories(conversationId: string, query = ""): Memory[] {
    const words = query.toLowerCase().split(/\s+/).filter(Boolean);
    return store.visibleMemories(conversationId)
      .filter((memory) => words.every((word) => `${memory.key} ${memory.content}`.toLowerCase().includes(word)))
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  function agentContext(sessionId: string) {
    const run = store.activeSessionRun(sessionId);
    if (!run) return null;
    const snapshot = store.snapshot(run.conversationId)!;
    const bot = botFor(run.conversationId);
    const inScope = appScope(run.conversationId);
    const registered = apps().filter((entry) => inScope(entry.id));
    const view = run.navigationSurface ? undefined : run.context;
    const currentApp: AppContext | undefined = run.navigationSurface
      ? { appId: run.navigationSurface.appId, viewToken: run.navigationViewToken, surface: run.navigationSurface.context }
      : run.appContext;
    let remaining = 6000;
    const memories = matchingMemories(run.conversationId).filter((memory) => {
      const size = memory.key.length + memory.content.length;
      if (size > remaining) return false;
      remaining -= size;
      return true;
    });
    return {
      conversationId: run.conversationId,
      bot: bot ?? null,
      allowedApps: registered
        .map(({ id, name, description, protocolVersion }) => ({ id, name, description, protocolVersion })),
      activeAppInstructions: registered.find((entry) => entry.protocolVersion !== 2 &&
        entry.id === (currentApp?.appId ?? view?.source.appId))?.instructions,
      currentView: view && inScope(view.source.appId)
        ? { ...view, selection: view.selection?.slice(0, 4000) } : undefined,
      currentApp: currentApp && inScope(currentApp.appId) ? currentApp : undefined,
      memories,
      memoryCount: store.visibleMemories(run.conversationId).length,
      forgottenKeys: store.forgottenKeys(run.conversationId),
      checkpoint: snapshot.checkpoint,
      forwardedConversations: snapshot.forwards.map((forward) => {
        const ids = [...new Set([...forward.messageIds.slice(0, 2), ...forward.messageIds.slice(-2)])];
        return {
          sourceConversationId: forward.sourceConversationId,
          title: forward.sourceTitle,
          handoff: forward.note,
          messageCount: forward.messageIds.length,
          excerpts: ids.map((id) => {
            const message = store.historyMessage(run.conversationId, forward.sourceConversationId, id)!;
            return { id, role: message.role, text: message.text.slice(0, 1000) };
          }),
        };
      }),
    };
  }

  async function readReport(
    appId: string,
    resourceId: string,
    revision?: string,
  ) {
    if (revision) {
      const report = store.report(appId, resourceId, revision);
      if (report) return report;
    }
    const adapter = integration(appId);
    if (!adapter.read) throw new HTTPException(400, { message: "This app does not publish saved reports." });
    const report = await adapter.read(resourceId, revision);
    if (revision && report.source.revision !== revision)
      throw new HTTPException(409, {
        message:
          "This report version is no longer available. Open the report again.",
      });
    store.saveReport(report);
    return report;
  }

  type ToolContext = { run: SavedRun; input: Record<string, unknown>; toolId: string; signal?: AbortSignal };
  type ToolHandler = (context: ToolContext) => unknown;

  function appTool(handler: (context: ToolContext & { appId: string; adapter: AppIntegration }) => unknown): ToolHandler {
    return (context) => {
      const appId = textField(context.input.appId, "appId");
      const adapter = allowedApp(context.run.conversationId, appId);
      return handler({ ...context, appId, adapter });
    };
  }

  const handlers: Record<ToolName, ToolHandler> = {
    history_search({ run, input }) {
      return store.searchHistory(run.conversationId, textField(input.query, "query"))
        .slice(0, 12).map(({ message, ...match }) => ({ ...match, messageId: message.id, role: message.role, createdAt: message.createdAt }));
    },
    history_read({ run, input }) {
      const targetId = textField(input.conversationId, "conversationId");
      if (typeof input.messageId === "string") {
        const message = store.historyMessage(run.conversationId, targetId, input.messageId);
        if (!message) throw new Error("Message is unavailable in this conversation's scope.");
        const start = Math.max(0, Math.trunc(Number(input.textOffset)) || 0);
        return { ...message, text: message.text.slice(start, start + 8000),
          ...(message.text.length > start + 8000 ? { nextTextOffset: start + 8000 } : {}) };
      } else {
        const page = store.readHistory(run.conversationId, targetId, Number(input.offset) || 0, Math.min(10, Number(input.limit) || 10));
        return { ...page, messages: page.messages.map((message) => ({ ...message, text: message.text.slice(0, 2000),
          ...(message.text.length > 2000 ? { nextTextOffset: 2000 } : {}) })) };
      }
    },
    memory_search({ run, input }) {
      return matchingMemories(run.conversationId, typeof input.query === "string" ? input.query : "").slice(0, 20);
    },
    memory_save({ run, input }) {
      const botId = store.conversation(run.conversationId)!.botId;
      if (!["shared", "bot"].includes(String(input.scope)) || (input.scope === "bot" && !botId))
        throw new Error("Choose shared preferences or the current bot's memory.");
      const source = store.snapshot(run.conversationId)!.messages.findLast((message) => message.role === "user")!;
      return store.saveMemory({
        botId: input.scope === "bot" ? botId : null,
        key: textField(input.key, "key").slice(0, 100),
        content: textField(input.content, "content").slice(0, 2000),
        sourceConversationId: run.conversationId, sourceMessageId: source.id,
      }, undefined, true);
    },
    memory_forget({ run, input }) {
      const memory = store.visibleMemories(run.conversationId).find((item) => item.id === input.id);
      if (!memory) throw new Error("Memory is outside this conversation's scope.");
      store.forgetMemory(memory.id);
      return { forgotten: true, key: memory.key };
    },
    checkpoint_save({ run, input }) {
      return store.saveCheckpoint(run.conversationId, textField(input.content, "content").slice(0, 4000));
    },
    app_discover: appTool(({ adapter, signal }) => {
      if (!adapter.discover) throw new Error("This app uses Relay v1 tools.");
      return adapter.discover(signal);
    }),
    app_call: appTool(({ input, adapter, signal, toolId }) => {
      if (!adapter.call) throw new Error("This app does not publish operations.");
      if (!jsonObject(input.arguments)) throw new Error("arguments must be a JSON object.");
      return adapter.call(textField(input.operation, "operation"), input.arguments, {
        signal, onProgress: (progress) => store.recordProgress(toolId, progress),
      });
    }),
    app_present: appTool(async ({ run, input, appId, adapter }) => {
      if (!adapter.open) throw new Error("This app uses Relay v1 navigation.");
      const intent = viewIntent(input.intent, appId);
      if (store.run(run.id)?.status !== "running" || cancelling.has(run.id))
        throw new Error("The request is no longer running.");
      const command = store.createPresentation(run, appId, intent);
      for (let attempt = 0; attempt < 50; attempt++) {
        if (stopping || store.command(command.id)?.status !== "pending") break;
        await delay(100);
      }
      return store.command(command.id);
    }),
    app_search: appTool(({ input, adapter }) => {
      if (!adapter.search) throw new Error("This app does not publish v1 search.");
      return adapter.search(
        typeof input.query === "string" ? input.query : "",
      );
    }),
    app_read: appTool(async ({ input, appId }) => {
      return publicReport(
        await readReport(
          appId,
          textField(input.resourceId, "resourceId"),
          typeof input.revision === "string" ? input.revision : undefined,
        ),
      );
    }),
    app_navigate: appTool(async ({ run, input, appId }) => {
      const report = await readReport(
        appId,
        textField(input.resourceId, "resourceId"),
        textField(input.revision, "revision"),
      );
      const sectionId =
        typeof input.sectionId === "string"
          ? input.sectionId
          : (report.sections.find((section) => section.id === "content")
              ?.id ?? report.sections[0]?.id);
      if (store.run(run.id)?.status !== "running" || cancelling.has(run.id))
        throw new Error("The request is no longer running.");
      if (!report.sections.some((section) => section.id === sectionId))
        throw new Error(
          "The requested section does not exist in this report snapshot.",
        );
      if (input.highlightIds !== undefined &&
        (!Array.isArray(input.highlightIds) || input.highlightIds.some((id) =>
          typeof id !== "string" || !report.sections.some((section) => section.id === id))))
        throw new Error("A requested highlight does not exist in this report snapshot.");
      const command = store.createCommand(
        run,
        report.source,
        sectionId!,
        input.viewState as ViewState | undefined,
        input.highlightIds as string[] | undefined,
      );
      for (let attempt = 0; attempt < 50; attempt++) {
        if (stopping || store.command(command.id)?.status !== "pending")
          break;
        await delay(100);
      }
      return store.command(command.id);
    }),
  };

  async function toolHandler(
    sessionId: string,
    name: string,
    raw: unknown,
  ): Promise<unknown> {
    const run = store.activeSessionRun(sessionId);
    if (!run) throw new Error("No active Relay request for this session.");
    const input = raw as Record<string, unknown>;
    const tool = store.startTool(run.id, name, input);
    let output: unknown;
    const signal = controllers.get(run.id)?.signal;
    try {
      if (cancelling.has(run.id) || signal?.aborted) throw new Error("The request was cancelled.");
      if (!Object.hasOwn(handlers, name)) throw new Error("Tool is not enabled.");
      output = await handlers[name as ToolName]({ run, input, toolId: tool.id, signal });
    } catch (error) {
      output = {
        error: error instanceof Error ? error.message : "App operation failed.",
        ...(error instanceof AppRequestError ? { kind: error.kind } : {}),
      };
    }
    store.finishTool(tool.id, output);
    return output;
  }

  async function execute(
    runId: string,
    sessionId: string,
    text: string,
    context?: ViewContext,
    appContext?: AppContext,
    image?: string,
  ) {
    try {
      const baseline = (await harness.inspect(sessionId)).usage ?? {};
      if (
        stopping ||
        cancelling.has(runId) ||
        store.run(runId)?.status !== "running"
      )
        return;
      const conversation = store.conversation(store.run(runId)!.conversationId)!;
      const admission = harness.prompt(sessionId, text, context, appContext, conversation.reasoningEffort, image);
      admissions.set(runId, admission);
      try {
        await admission;
      } finally {
        admissions.delete(runId);
      }
      while (
        !stopping &&
        !cancelling.has(runId) &&
        store.run(runId)?.status === "running"
      ) {
        const state = await harness.inspect(sessionId);
        const run = store.run(runId)!;
        if (cancelling.has(runId) || run.status !== "running") return;
        const usage =
          state.usage &&
          Object.fromEntries(
            Object.entries(state.usage).map(([key, value]) => [
              key,
              value - (baseline[key] ?? 0),
            ]),
          );
        for (const message of state.messages) {
          if (message.role === "assistant")
            store.message(run.conversationId, message);
        }
        if (state.status === "error") {
          store.finishRun(
            runId,
            "failed",
            state.error ?? "The agent could not finish this request.",
            usage,
          );
          store.failPendingCommands(runId, "The agent request failed.");
          return;
        }
        if (state.status === "idle") {
          store.finishRun(runId, "completed", undefined, usage);
          return;
        }
        await delay(400);
      }
    } catch (error) {
      if (cancelling.has(runId)) return;
      store.finishRun(
        runId,
        "failed",
        error instanceof Error ? error.message : "Agent request failed.",
      );
      store.failPendingCommands(runId, "The agent request failed.");
    }
  }

  app.use("/api/*", async (c, next) => {
    c.header("Cache-Control", "no-store");
    if (
      c.req.method === "POST" &&
      !c.req.header("content-type")?.startsWith("application/json")
    ) {
      throw new HTTPException(415, { message: "Send JSON." });
    }
    await next();
  });

  app.onError((error, c) => {
    if (error instanceof AppRequestError)
      return c.json({ error: error.message }, error.status);
    if (error instanceof HTTPException)
      return c.json({ error: error.message }, error.status);
    if (error instanceof SyntaxError)
      return c.json({ error: "Invalid JSON." }, 400);
    return c.json({ error: error.message || "Request failed." }, 502);
  });

  app.get("/api/config", (c) =>
    c.json({
      provider: {...provider, supportsImageInput: supportsImageInput(provider.mode), supportsReasoningEffort: supportsReasoningEffort(provider.mode, provider.model)},
      apps: apps().map(({ id, name, description, resourceId, protocolVersion, capabilities }) => ({
        id,
        name,
        description,
        resourceId,
        protocolVersion,
        capabilities,
      })),
    }),
  );
  app.get("/api/conversations", (c) => c.json(store.conversations(c.req.query("q"))));
  // URL kept: installed Flutter updaters call it before restarting.
  app.get("/api/desktop/busy", (c) => {
    const deviceId = c.req.query("deviceId"), tabId = c.req.query("tabId");
    if (!deviceId || !tabId) throw new HTTPException(400, {message: "Provide the desktop device and tab."});
    const busy = changingProvider || store.conversations().some((conversation) => {
      const run = store.activeRun(conversation.id);
      return run?.deviceId === deviceId && run.tabId === tabId;
    });
    return c.json({busy});
  });
  app.get("/api/trash", (c) => c.json(store.trash()));

  function botInput(body: Record<string, unknown>): BotInput {
    const registered = apps();
    if (!Array.isArray(body.appIds) || body.appIds.some((id) => typeof id !== "string" || !registered.some((entry) => entry.id === id)))
      throw new HTTPException(400, { message: "Choose registered apps for this bot." });
    return {
      name: textField(body.name, "Name").trim().slice(0, 80),
      objective: textField(body.objective, "Objective").trim().slice(0, 4000),
      scope: typeof body.scope === "string" ? body.scope.trim().slice(0, 4000) : "",
      appIds: [...new Set(body.appIds as string[])],
    };
  }
  app.get("/api/bots", (c) => c.json(store.bots()));
  app.post("/api/bots", async (c) => c.json(store.saveBot(botInput(await c.req.json())), 201));
  app.post("/api/bots/:id", async (c) => {
    if (!store.bot(c.req.param("id"))) throw new HTTPException(404, { message: "Bot not found." });
    return c.json(store.saveBot(botInput(await c.req.json()), c.req.param("id")));
  });
  app.get("/api/memories", (c) => c.json(store.memories(c.req.query("botId") || null)));
  app.post("/api/memories", async (c) => {
    const body = await c.req.json();
    if (body.botId && !store.bot(body.botId)) throw new HTTPException(404, { message: "Bot not found." });
    return c.json(store.saveMemory({ botId: body.botId || null, key: textField(body.key, "Name").slice(0, 100),
      content: textField(body.content, "Memory").slice(0, 2000) }), 201);
  });
  app.post("/api/memories/:id", async (c) => {
    const body = await c.req.json();
    const memory = [null, ...store.bots().map((bot) => bot.id)]
      .flatMap((botId) => store.memories(botId)).find((item) => item.id === c.req.param("id"));
    if (!memory) throw new HTTPException(404, { message: "Memory not found." });
    return c.json(store.saveMemory({ ...memory, content: textField(body.content, "Memory").slice(0, 2000) }, memory.id));
  });
  app.delete("/api/memories/:id", (c) => {
    store.forgetMemory(c.req.param("id"));
    return c.json({ forgotten: true });
  });

  app.get("/api/settings/provider", (c) => {
    if (!providerControls)
      throw new HTTPException(503, {
        message: "Provider settings are unavailable.",
      });
    const mode = c.req.query("mode");
    if (mode && !isProviderMode(mode))
      throw new HTTPException(400, {message: "Choose a supported provider."});
    return c.json(providerControls.get(mode as ProviderMode | undefined));
  });
  app.post("/api/settings/provider/models", async (c) => {
    if (!providerControls) throw new HTTPException(503, {message: "Provider settings are unavailable."});
    const origin = c.req.header("origin");
    if (origin && origin !== new URL(c.req.url).origin)
      throw new HTTPException(403, {message: "Open settings from Relay to load models."});
    const input = await c.req.json<ProviderModelRequest>();
    if (!input || !isProviderMode(input.mode) || (input.apiKey !== undefined && typeof input.apiKey !== "string"))
      throw new HTTPException(400, {message: "Choose a provider and enter its API key as text."});
    c.header("Cache-Control", "no-store");
    const models = await providerControls.models(input, c.req.raw.signal);
    return c.json({models: models.map(model => ({...model,
      supportsReasoningEffort: supportsReasoningEffort(input.mode, model.id)}))});
  });
  app.post("/api/settings/provider", async (c) => {
    if (!providerControls)
      throw new HTTPException(503, {
        message: "Provider settings are unavailable.",
      });
    const origin = c.req.header("origin");
    if (origin && origin !== new URL(c.req.url).origin)
      throw new HTTPException(403, {
        message: "Open settings from Relay to change the provider.",
      });
    const input = await c.req.json<ProviderUpdate>();
    if (stopping)
      throw new HTTPException(503, { message: "Relay is stopping." });
    if (changingProvider || tasks.size)
      throw new HTTPException(409, {
        message:
          "Wait for current replies or settings changes to finish, then save again.",
      });
    changingProvider = true;
    try {
      const settings = await providerControls.update(input);
      Object.assign(provider, {
        mode: settings.mode,
        model:
          settings.mode === "fixture"
            ? "Scripted local fixture"
            : settings.model,
        configured: settings.mode === "fixture" || settings.hasKey,
      });
      return c.json(settings);
    } finally {
      changingProvider = false;
    }
  });

  app.post("/api/conversations", async (c) => {
    const body = await c.req.json();
    if (changingProvider)
      throw new HTTPException(409, {
        message: "Provider settings are being applied. Try again in a moment.",
      });
    const title =
      typeof body.title === "string" && body.title.trim()
        ? body.title.trim().slice(0, 100)
        : "New conversation";
    if (body.botId && !store.bot(body.botId)) throw new HTTPException(404, { message: "Bot not found." });
    const effort = body.reasoningEffort === undefined ? null : reasoningEffort(body.reasoningEffort);
    return c.json(
      store.createConversation(title, await harness.createSession(title), body.botId || null, effort),
      201,
    );
  });

  app.post("/api/conversations/:id/forward", async (c) => {
    const sourceId = c.req.param("id");
    const source = store.snapshot(sourceId);
    if (!source) throw new HTTPException(404, { message: "Conversation not found." });
    const body = await c.req.json();
    const bot = store.bot(textField(body.botId, "Bot"));
    if (!bot) throw new HTTPException(404, { message: "Bot not found." });
    if (changingProvider || store.activeRun(sourceId)) throw new HTTPException(409, { message: "Wait for the current reply or settings change before forwarding." });
    const title = `${source.conversation.title.slice(0, 65)} → ${bot.name.slice(0, 25)}`;
    const target = store.createConversation(title, await harness.createSession(title), bot.id);
    store.addForward(sourceId, target.id, typeof body.note === "string" ? body.note.trim().slice(0, 4000) : "");
    return c.json(target, 201);
  });

  app.get("/api/conversations/:id", (c) => {
    const snapshot = store.snapshot(c.req.param("id"));
    if (!snapshot)
      throw new HTTPException(404, { message: "Conversation not found." });
    return c.json(snapshot);
  });

  app.get("/api/conversations/:id/messages/:messageId/capture", (c) => {
    const png = store.capture(c.req.param("id"), c.req.param("messageId"));
    if (!png) throw new HTTPException(404, { message: "Screenshot not found." });
    return c.body(png, 200, { "Content-Type": "image/png" });
  });

  app.delete("/api/conversations/:id", (c) => {
    const id = c.req.param("id");
    if (store.activeRun(id))
      throw new HTTPException(409, { message: "Stop or finish the current reply before moving the conversation to Trash." });
    store.trashConversation(id);
    return c.json({ trashed: true });
  });

  app.post("/api/conversations/:id/restore", (c) => {
    const conversation = store.restoreConversation(c.req.param("id"));
    if (!conversation) throw new HTTPException(410, { message: "This conversation's restore period has ended." });
    return c.json(conversation);
  });

  app.post("/api/conversations/:id/settings", async (c) => {
    const id = c.req.param("id");
    const body = await c.req.json();
    if (!store.conversation(id)) throw new HTTPException(404, { message: "Conversation not found." });
    const effort = reasoningEffort(body?.reasoningEffort);
    if (changingProvider || store.activeRun(id))
      throw new HTTPException(409, { message: "Wait for the current reply or settings change to finish." });
    return c.json(store.setReasoningEffort(id, effort));
  });

  app.post("/api/conversations/:id/messages", async (c) => {
    const id = c.req.param("id");
    const body = await c.req.json();
    const sessionId = store.sessionId(id);
    if (!sessionId || !store.conversation(id))
      throw new HTTPException(404, { message: "Conversation not found." });
    if (stopping)
      throw new HTTPException(503, { message: "Relay is stopping." });
    if (changingProvider)
      throw new HTTPException(409, {
        message: "Provider settings are being applied. Try again in a moment.",
      });
    const text = textField(body.text, "Message").trim();
    const deviceId = textField(body.deviceId, "deviceId");
    const tabId = textField(body.tabId, "tabId");
    const context = body.context as ViewContext | undefined;
    const appContext = body.appContext as AppContext | undefined;
    let image: string | undefined;
    if (body.capture !== undefined) {
      if (!supportsImageInput(provider.mode))
        throw new HTTPException(400, {message: "Choose Claude or OpenAI to send a screenshot."});
      const capture = body.capture;
      if (!jsonObject(capture)) throw new HTTPException(400, {message: "Invalid screenshot."});
      allowedApp(id, textField(capture.appId, "Screenshot app"));
      if (typeof capture.png !== "string" || capture.png.length > 8 * 1024 * 1024 ||
          !capture.png.startsWith("iVBORw0KGgo") || !/^[A-Za-z0-9+/]+={0,2}$/.test(capture.png))
        throw new HTTPException(400, {message: "Use a smaller PNG screenshot."});
      image = capture.png;
    }
    if (appContext) {
      allowedApp(id, textField(appContext.appId, "appId"));
      if (appContext.viewToken !== undefined)
        textField(appContext.viewToken, "viewToken");
      if (appContext.surface !== undefined) surfaceContext(appContext.surface, appContext.appId);
    }
    if (context) {
      textField(context.viewToken, "viewToken");
      if (
        !context.source ||
        !store.report(
          context.source.appId,
          context.source.resourceId,
          context.source.revision,
        )
      ) {
        throw new HTTPException(400, {
          message: "Open a saved report before using it as context.",
        });
      }
      allowedApp(id, context.source.appId);
    }
    if (store.activeRun(id))
      throw new HTTPException(409, {
        message: "Wait for the current reply or cancel it first.",
      });
    if (!store.snapshot(id)!.messages.length)
      store.renameConversation(id, text.slice(0, 80));
    const run = store.startRun(id, text, deviceId, tabId, context, appContext,
      image ? Buffer.from(image, "base64") : undefined);
    controllers.set(run.id, new AbortController());
    const task = execute(run.id, sessionId, text, context, appContext, image);
    tasks.add(task);
    void task.finally(() => { tasks.delete(task); controllers.delete(run.id); });
    return c.json(run, 202);
  });

  app.post("/api/runs/:id/cancel", async (c) => {
    const run = store.run(c.req.param("id"));
    if (!run) throw new HTTPException(404, { message: "Run not found." });
    if (run.status === "running") {
      cancelling.add(run.id);
      controllers.get(run.id)?.abort();
      store.failPendingCommands(run.id, "The request was cancelled.");
      try {
        await admissions.get(run.id);
        await harness.interrupt(store.sessionId(run.conversationId)!);
        store.finishRun(run.id, "cancelled");
      } catch (error) {
        store.finishRun(
          run.id,
          "interrupted",
          "The agent did not confirm cancellation.",
        );
        throw error;
      } finally {
        cancelling.delete(run.id);
      }
    }
    return c.json(store.run(run.id));
  });

  app.post("/api/commands/:id/ack", async (c) => {
    const command = store.command(c.req.param("id"));
    if (!command)
      throw new HTTPException(404, { message: "View command not found." });
    const body = await c.req.json();
    if (body.deviceId !== command.deviceId || body.tabId !== command.tabId) {
      throw new HTTPException(403, {
        message: "This view command belongs to another browser tab.",
      });
    }
    if (!["applied", "stale", "failed"].includes(body.status))
      throw new HTTPException(400, { message: "Invalid navigation result." });
    if (body.viewToken !== undefined) textField(body.viewToken, "viewToken");
    const context = command.kind === "present" && body.context !== undefined
      ? surfaceContext(body.context, command.appId) : undefined;
    if (command.kind === "present" && body.status === "applied" && (!context || !body.viewToken))
      throw new HTTPException(400, { message: "Applied presentation requires resulting context and viewToken." });
    return c.json(
      store.acknowledge(
        command.id,
        body.status,
        typeof body.error === "string" ? body.error : undefined,
        body.viewToken,
        context,
      ),
    );
  });

  app.get("/api/apps/:id/search", async (c) => {
    const adapter = integration(c.req.param("id"));
    if (!adapter.search) throw new HTTPException(400, { message: "This app does not publish v1 search." });
    return c.json(await adapter.search(c.req.query("q") ?? ""));
  });
  app.get("/api/apps/:id/read", async (c) =>
    c.json(
      publicReport(
        await readReport(
          c.req.param("id"),
          textField(c.req.query("resourceId"), "resourceId"),
        ),
      ),
    ),
  );
  app.get("/api/apps/:id/report", async (c) =>
    c.json(
      publicReport(
        await readReport(
          c.req.param("id"),
          textField(c.req.query("resourceId"), "resourceId"),
          textField(c.req.query("revision"), "revision"),
        ),
      ),
    ),
  );
  app.get("/api/apps/:id/view", async (c) => {
    const id = c.req.param("id");
    const adapter = integration(id);
    const token = textField(c.req.query("token"), "token");
    if (!c.req.query("resourceId") && !c.req.query("revision") && adapter.open)
      return c.json(await adapter.open(token, textField(c.req.query("parentOrigin"), "parentOrigin")));
    const resourceId = textField(c.req.query("resourceId"), "resourceId");
    const revision = textField(c.req.query("revision"), "revision");
    if (!adapter.view) throw new HTTPException(400, { message: "This app does not publish a saved view." });
    const report = await readReport(id, resourceId, revision);
    return c.json(await adapter.view(report, token, textField(c.req.query("parentOrigin"), "parentOrigin")));
  });

  return {
    app,
    purgeTrash,
    toolHandler,
    agentContext,
    setHarness(value: AgentHarness) {
      harness = value;
    },
    async close() {
      stopping = true;
      for (const controller of controllers.values()) controller.abort();
      const runs = store
        .conversations()
        .flatMap((item) => store.activeRun(item.id) ?? []);
      for (const run of runs) {
        store.finishRun(
          run.id,
          "interrupted",
          "Relay stopped before this run finished.",
        );
        store.failPendingCommands(run.id, "Relay stopped.");
      }
      await Promise.allSettled(admissions.values());
      await Promise.allSettled(
        runs.map((run) =>
          harness.interrupt(store.sessionId(run.conversationId)!),
        ),
      );
      await Promise.allSettled(tasks);
    },
  };
}

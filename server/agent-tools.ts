import { Schema } from "effect";

export const agentTools = {
  app_discover: {
    description: "Discover instructions and app-defined operations for the selected or explicitly requested allowed app. JSON Schema describes app-owned arguments.",
    input: Schema.Struct({ appId: Schema.String }),
  },
  app_call: {
    description: "Call a published operation using its discovered JSON Schema. Results may include sources, a PNG for vision-capable models, and app-owned presentation intents. Relay records reported progress and supports cooperative cancellation.",
    input: Schema.Struct({ appId: Schema.String, operation: Schema.String,
      arguments: Schema.Record(Schema.String, Schema.Unknown) }),
  },
  app_present: {
    description: "Show the evidence being discussed using an app-owned view and published semantic targets on the originating device. Briefly explain why before calling; use the same view to focus a detail and group related targets. Source evidence is optional. Only applied confirms render and animation completion. Do not retry stale presentations after manual interaction. For apps whose discovery instructions support explanations, supply intent.explanation: one or two short, factual plain-text sentences (at most 600 characters) explaining the highlighted evidence. It appears beside the first target, or the view if no targets. This tool does not draw or mark points resolved.",
    input: Schema.Struct({ appId: Schema.String, intent: Schema.Struct({
      viewId: Schema.String,
      explanation: Schema.optional(Schema.String),
      state: Schema.optional(Schema.Record(Schema.String, Schema.Unknown)),
      targetIds: Schema.optional(Schema.Array(Schema.String)),
      source: Schema.optional(Schema.Struct({ appId: Schema.String, resourceId: Schema.String,
        revision: Schema.String, title: Schema.String, sourceUrl: Schema.String })),
    }) }),
  },
  app_search: {
    description: "Search an allowed app for source identities. Use its integration query syntax; empty query lists resources.",
    input: Schema.Struct({ appId: Schema.String, query: Schema.String }),
  },
  app_read: {
    description: "Read a saved app resource, preserving its source and revision.",
    input: Schema.Struct({
      appId: Schema.String,
      resourceId: Schema.String,
      revision: Schema.optional(Schema.String),
    }),
  },
  app_navigate: {
    description: "Present a meaningful app view on the originating device. Optional highlightIds name published report.sections IDs to emphasize. Use selected meaningful views while working and finish at the relevant evidence with field highlights when the app publishes targets. Only status applied confirms navigation and requested highlights; pending, stale, or failed do not.",
    input: Schema.Struct({
      appId: Schema.String,
      resourceId: Schema.String,
      revision: Schema.String,
      sectionId: Schema.optional(Schema.String),
      highlightIds: Schema.optional(Schema.Array(Schema.String)),
      viewState: Schema.optional(
        Schema.Struct({
          query: Schema.optional(Schema.String),
          filters: Schema.optional(Schema.Record(Schema.String, Schema.String)),
          language: Schema.optional(Schema.String),
        }),
      ),
    }),
  },
  history_search: {
    description: "Search accessible original conversations by words, including explicitly forwarded messages. Use for details missing after compaction. Returns source message IDs and snippets.",
    input: Schema.Struct({ query: Schema.String }),
  },
  history_read: {
    description: "Read accessible original messages, paginated by offset/limit. For a long message, supply messageId and textOffset to recover its remaining text. Forwarded access stops at the forwarded snapshot.",
    input: Schema.Struct({
      conversationId: Schema.String,
      offset: Schema.optional(Schema.Number),
      limit: Schema.optional(Schema.Number),
      messageId: Schema.optional(Schema.String),
      textOffset: Schema.optional(Schema.Number),
    }),
  },
  memory_search: {
    description: "Find current shared preferences and this bot's memories by words. Empty query lists recent notes. Current notes override conflicting old conversation details.",
    input: Schema.Struct({ query: Schema.optional(Schema.String) }),
  },
  memory_save: {
    description: "Remember a concise lasting preference (shared) or task decision (bot). Reuse an existing stable key to correct it. Only save information supported by the latest user turn, never facts rediscovered only in old or forwarded history. Do not store changing app facts. User-edited and forgotten keys are protected.",
    input: Schema.Struct({
      scope: Schema.Literals(["shared", "bot"]),
      key: Schema.String,
      content: Schema.String,
    }),
  },
  memory_forget: {
    description: "Forget a visible memory by ID when the user requests it. Prevents automatic recreation under the same key; the archive is retained.",
    input: Schema.Struct({ id: Schema.String }),
  },
  checkpoint_save: {
    description: "Replace this conversation's compact task checkpoint: goal, completed work, decisions, unresolved issues, next action. Use for unfinished multi-step tasks; no automatic scheduling or restart is implied.",
    input: Schema.Struct({ content: Schema.String }),
  },
};

export type ToolName = keyof typeof agentTools;

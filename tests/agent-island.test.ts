import assert from "node:assert/strict";
import test from "node:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { load } from "cheerio";
import AgentIsland, { agentActivity, toolLabel } from "../web/AgentIsland.tsx";
import type { Snapshot, ToolRecord } from "../shared/types.ts";

const apps = [{ id: "research", name: "Research Web", description: "Synthetic" }];
const source = { appId: "research", resourceId: "#/hand/products", revision: "v1", title: "Hand catalog", sourceUrl: "http://example.test/#/hand/products" };
function snapshot(status: "running" | "completed" = "running"): Snapshot {
  return {
    conversation: { id: "conversation", title: "Hands", botId: null, createdAt: "2026-01-01T00:00:00Z" },
    messages: [], tools: [], commands: [], forwards: [],
    runs: [{ id: "run", conversationId: "conversation", status, startedAt: "2026-01-01T00:00:00Z" }],
  };
}
const search: ToolRecord = { id: "search", runId: "run", name: "app_search", input: { appId: "research", query: "hands" }, output: null, createdAt: "2026-01-01T00:00:01Z", status: "running" };

test("island reports actual running operations, without treating legacy completed tools as running", () => {
  const state = snapshot();
  state.tools = [search];
  assert.equal(agentActivity(state, apps, "device", "tab").label, "Searching Research Web");
  state.tools = [{ ...search, status: undefined }];
  assert.equal(agentActivity(state, apps, "device", "tab").label, "Thinking through your question");
  state.tools.push({ ...search, id: "read", name: "app_read", output: { source } });
  assert.equal(agentActivity(state, apps, "device", "tab").label, "Reading Hand catalog");
  assert.equal(toolLabel({ ...search, name: "app_read", input: { appId: "research", resourceId: "#/internal-route" } }, apps), "Reading Research Web");
});

test("model completion distinguishes pending or unapplied app views from confirmed results", () => {
  const state = snapshot("completed");
  state.messages = [{ id: "answer", role: "assistant", text: "**Alpha** has 16 DoF.", createdAt: "2026-01-01T00:00:02Z" }];
  state.commands = [{ kind: "navigate", id: "command", runId: "run", deviceId: "device", tabId: "tab", expectedViewToken: null, source, sectionId: "content", status: "pending" }];
  assert.equal(agentActivity(state, apps, "device", "tab").label, "Answer ready · view pending");
  assert.equal(agentActivity(state, apps, "device", "tab").phase, "attention");
  assert.equal(agentActivity(state, apps, "device", "tab").detail, "Alpha has 16 DoF.");
  assert.equal(agentActivity(state, apps, "another-device", "tab").label, "Answer ready");
  state.commands[0].status = "stale";
  assert.equal(agentActivity(state, apps, "device", "tab").label, "Answer ready · view not applied");
  state.commands[0].status = "applied";
  assert.equal(agentActivity(state, apps, "device", "tab").label, "Answer ready");
  assert.equal(agentActivity(state, apps, "device", "tab").phase, "ready");
});

test("working island always exposes Stop and conversation expansion without a guessed percentage", () => {
  const $ = load(renderToStaticMarkup(createElement(AgentIsland, { label: toolLabel(search, apps), detail: "Expand conversation for details", working: true, onExpand() {}, onStop() {} })));
  assert.equal($("button[aria-label='Expand conversation']").length, 1);
  assert.equal($("button.island-stop").text(), "Stop");
  assert.equal($("[role='status']").text(), "Searching Research Web");
  assert.equal($("progress, [role='progressbar']").length, 0);
});


test("v2 operation progress and source-optional presentation name the real app activity", () => {
  const state = snapshot();
  state.tools = [{ ...search, name: "app_call", progress: [{ type: "progress", message: "Inspecting furniture dimensions" }] }];
  assert.equal(agentActivity(state, apps, "device", "tab").label, "Inspecting furniture dimensions");
  state.commands = [{ kind: "present", id: "command", runId: "run", deviceId: "device", tabId: "tab", expectedViewToken: null, appId: "research", expectedGeneration: 0, intent: { viewId: "room" }, status: "pending" }];
  assert.equal(agentActivity(state, apps, "device", "tab").label, "Opening Research Web");
});

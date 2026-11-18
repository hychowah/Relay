import type { Snapshot, ToolRecord, WorkspaceConfig } from "../shared/types.ts";

function inputOf(tool: ToolRecord) {
  return (tool.input && typeof tool.input === "object" ? tool.input : {}) as Record<string, unknown>;
}

export function toolLabel(tool: ToolRecord, apps: WorkspaceConfig["apps"]) {
  const input = inputOf(tool);
  const app = apps.find((item) => item.id === input.appId)?.name || "app";
  const output = tool.output as { source?: { title?: string } } | null;
  const resource = output?.source?.title || app;
  if (tool.name === "app_discover") return `Discovering ${app}`;
  if (tool.name === "app_call") return tool.progress?.at(-1)?.message || `Working in ${app}`;
  if (tool.name === "app_present") return `Presenting ${app}`;
  if (tool.name === "app_search") return `Searching ${app}`;
  if (tool.name === "app_read") return `Reading ${resource}`;
  if (tool.name === "app_navigate") return `Opening ${resource}`;
  if (tool.name.startsWith("history_")) return "Reviewing conversation history";
  if (tool.name.startsWith("memory_")) return "Updating memory";
  return "Working on your question";
}

type Activity = { label: string; detail: string; working: boolean; phase: "idle" | "working" | "ready" | "attention" };

export function agentActivity(snapshot: Snapshot | undefined, apps: WorkspaceConfig["apps"], deviceId: string, tabId: string): Activity {
  const run = snapshot?.runs.at(-1);
  if (!run || !snapshot) return { label: "Ask Relay", detail: "Chat about this app", working: false, phase: "idle" };
  const commands = snapshot.commands.filter((command) => command.runId === run.id && command.deviceId === deviceId && command.tabId === tabId);
  const command = commands.at(-1);
  const commandTitle = command?.kind === "present" ? command.intent.source?.title || apps.find((app) => app.id === command.appId)?.name || command.intent.viewId : command?.source.title;
  const tool = snapshot.tools.findLast((item) => item.runId === run.id && item.status === "running");
  if (run.status === "running") {
    return {
      label: command?.status === "pending" ? `Opening ${commandTitle}` : tool ? toolLabel(tool, apps) : "Thinking through your question",
      detail: command?.status === "pending" ? "Waiting for the app view" : "Expand conversation for details",
      working: true,
      phase: "working",
    };
  }
  if (run.status !== "completed") return {
    label: run.status === "cancelled" ? "Stopped" : run.status === "interrupted" ? "Interrupted" : "Could not finish",
    detail: run.error || "Open the conversation to continue",
    working: false,
    phase: "attention",
  };
  const answer = snapshot.messages.findLast((message) => message.role === "assistant" && message.createdAt >= run.startedAt)?.text;
  return {
    label: command?.status === "pending" ? "Answer ready · view pending" : command?.status === "failed" || command?.status === "stale" ? "Answer ready · view not applied" : "Answer ready",
    detail: answer?.replace(/[#*_`>\[\]]/g, "").replace(/\s+/g, " ").slice(0, 180) || "Open the conversation to see the result",
    working: false,
    phase: command && command.status !== "applied" ? "attention" : "ready",
  };
}

export default function AgentIsland({ label, detail, working, phase = working ? "working" : "idle", onExpand, onStop }: {
  label: string; detail: string; working: boolean; phase?: Activity["phase"]; onExpand: () => void; onStop: () => void;
}) {
  return <div className={`agent-island ${working ? "is-working" : ""}`} data-phase={phase}>
    <button className="island-expand" onClick={onExpand} aria-label="Expand conversation" aria-expanded="false" aria-controls="relay-conversation">
      <span className="island-symbol" aria-hidden="true">{phase === "ready" ? "✓" : phase === "attention" ? "·" : "✳"}</span>
      <span className="island-copy"><strong role="status" aria-live="polite"><span className="island-status" key={label}>{label}</span></strong><span>{detail}</span></span>
      <span className="island-chevron" aria-hidden="true">⌃</span>
    </button>
    {working && <button className="island-stop" onClick={onStop}>Stop</button>}
  </div>;
}

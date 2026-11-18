import MessageContent from "./MessageContent.tsx";
import type {
  Message,
  Report,
  Run,
  Snapshot,
  Source,
  ToolRecord,
  ViewCommand,
  ViewContext,
} from "../shared/types.ts";

export interface Turn {
  id: string;
  messages: Message[];
  runs: Run[];
  tools: ToolRecord[];
  commands: ViewCommand[];
}

export function conversationTurns(snapshot: Snapshot): Turn[] {
  const turns: Turn[] = [];
  for (const message of snapshot.messages) {
    if (message.role === "user" || !turns.length)
      turns.push({
        id: message.id,
        messages: [],
        runs: [],
        tools: [],
        commands: [],
      });
    turns.at(-1)!.messages.push(message);
  }
  const runTurns = new Map<string, Turn>();
  for (const run of snapshot.runs) {
    const turn =
      turns.findLast((item) => item.messages[0].createdAt <= run.startedAt) ||
      turns[0];
    if (!turn) continue;
    turn.runs.push(run);
    runTurns.set(run.id, turn);
  }
  for (const tool of snapshot.tools) runTurns.get(tool.runId)?.tools.push(tool);
  for (const command of snapshot.commands)
    runTurns.get(command.runId)?.commands.push(command);
  return turns;
}

export function turnSources(tools: ToolRecord[]) {
  const sources = new Map<string, Source>();
  for (const tool of tools) {
    const output = tool.output as (Partial<Report> & { sources?: Source[] }) | null;
    if (tool.name === "app_call" && Array.isArray(output?.sources)) {
      for (const source of output.sources) sources.set(JSON.stringify([source.appId, source.resourceId, source.revision]), source);
    }
    if (
      tool.name !== "app_read" ||
      !output?.source ||
      !Array.isArray(output.sections)
    )
      continue;
    const source = output.source;
    sources.set(
      JSON.stringify([source.appId, source.resourceId, source.revision]),
      source,
    );
  }
  return [...sources.values()];
}

// Only restore evidence that this turn actually showed, at the same revision.
export function sourceFocus(commands: ViewCommand[], source: Source): Pick<ViewContext, "sectionId" | "highlightIds"> | undefined {
  for (const command of [...commands].reverse()) {
    const shown = command.kind === "present" ? command.intent.source : command.source;
    if (command.status !== "applied" || !shown || shown.appId !== source.appId || shown.resourceId !== source.resourceId || shown.revision !== source.revision) continue;
    const ids = command.kind === "present" ? command.intent.targetIds : command.highlightIds;
    return { sectionId: command.kind === "present" ? ids?.[0] : command.sectionId, highlightIds: ids };
  }
}

export default function ResponseTurn({
  turn,
  knownSources = [],
  onOpenSource,
}: {
  turn: Turn;
  knownSources?: Source[];
  onOpenSource: (source: Source, focus?: Pick<ViewContext, "sectionId" | "highlightIds">) => void;
}) {
  const sources = turnSources(turn.tools);
  const citationSources = [
    ...sources,
    ...knownSources.filter(
      (known) =>
        !sources.some(
          (source) =>
            source.appId === known.appId &&
            source.resourceId === known.resourceId,
        ),
    ),
  ];
  const latestRun = turn.runs.at(-1);
  function messageItem(message: Message) {
    return (
      <article
        key={message.id}
        id={`message-${message.id}`}
        className={`message ${message.role}`}
      >
        <div className="message-meta">
          <span>{message.role === "user" ? "You" : "Relay · Response"}</span>
          <time>
            {new Date(message.createdAt).toLocaleTimeString([], {
              hour: "2-digit",
              minute: "2-digit",
            })}
          </time>
        </div>
        <div
          className={`message-text${message.role === "assistant" ? " markdown" : ""}`}
        >
          {message.role === "assistant" ? (
            <MessageContent
              text={message.text}
              sources={citationSources}
              onOpenSource={(source) => onOpenSource(source, sourceFocus(turn.commands, source))}
            />
          ) : (
            message.text
          )}
        </div>
        {message.context && (
          <div className="message-context">
            ▤ {message.context.source.title}
            {message.context.selection && " · selection"}
          </div>
        )}
      </article>
    );
  }
  return (
    <section className="response-turn" aria-label="Question and response">
      {turn.messages
        .filter((message) => message.role === "user")
        .map(messageItem)}
      {(!!turn.tools.length || !!turn.commands.length) && (
        <details className="tool-activity response-activity">
          <summary>
            <span>
              {latestRun?.status === "running"
                ? "Working"
                : latestRun?.status === "completed"
                  ? "Completed"
                  : "Activity"}
            </span>
            <span className="activity-count">
              {turn.tools.length} tool{" "}
              {turn.tools.length === 1 ? "call" : "calls"}
            </span>
          </summary>
          <div className="activity-records">
            {turn.tools.map((tool) => (
              <details key={tool.id} className="tool-record">
                <summary>
                  {tool.name}
                  <time>
                    {new Date(tool.createdAt).toLocaleTimeString([], {
                      hour: "2-digit",
                      minute: "2-digit",
                    })}
                  </time>
                </summary>
                <div className="tool-label">INPUT</div>
                <pre>{JSON.stringify(tool.input, null, 2)}</pre>
                {!!tool.progress?.length && <><div className="tool-label">PROGRESS</div><ul>{tool.progress.map((progress, index) => <li key={index}>{progress.message}</li>)}</ul></>}
                <div className="tool-label">RESULT</div>
                <pre>{JSON.stringify(tool.output, null, 2)}</pre>
              </details>
            ))}
            {turn.commands.map((command) => (
              <div
                className={`command-status ${command.status}`}
                key={command.id}
              >
                {command.kind === "present" ? "App presentation" : "View navigation"}: {command.status}
                {command.error && ` · ${command.error}`}
              </div>
            ))}
          </div>
        </details>
      )}
      {sources.length > 0 && (
        <details className="source-citations">
          <summary>
            {sources.length} {sources.length === 1 ? "source" : "sources"} ·
            open cited snapshots
          </summary>
          <div className="source-list">
            {sources.map((source) => (
              <button
                key={JSON.stringify([
                  source.appId,
                  source.resourceId,
                  source.revision,
                ])}
                onClick={() => onOpenSource(source, sourceFocus(turn.commands, source))}
                title={`Open saved revision ${source.revision}`}
              >
                <span>▤</span>
                <span>{source.title}</span>
                <span>↗</span>
              </button>
            ))}
          </div>
        </details>
      )}
      {turn.messages
        .filter((message) => message.role === "assistant")
        .map(messageItem)}
      {latestRun?.status === "completed" &&
        turn.messages.some((message) => message.role === "assistant") && (
          <div className="response-complete">Response complete</div>
        )}
      {turn.runs
        .filter((run) =>
          ["failed", "interrupted", "cancelled"].includes(run.status),
        )
        .map((run) => (
          <div className="run-notice" key={run.id}>
            {run.status === "cancelled"
              ? "Run stopped."
              : run.status === "interrupted"
                ? "Run interrupted. Send a new message to continue."
                : `Run failed: ${run.error || "Unknown error"}`}
          </div>
        ))}
    </section>
  );
}

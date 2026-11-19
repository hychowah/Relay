import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import type { AppContext, Report, ViewContext } from "../../shared/types.ts";

type WireMessage = {
  role: string;
  content?: unknown;
  tool_calls?: Array<{ id: string; function: { name: string } }>;
};

// Scripted responses for the local demo and harness tests.
export async function startFixtureProvider(
  apps: () => Array<{ id: string; name: string }>,
) {
  const requests: Array<{
    tools: string[];
    messages: WireMessage[];
    reasoning_effort?: string;
  }> = [];
  const server = createServer(async (request, response) => {
    try {
      let body = "";
      for await (const part of request) body += part;
      const input = JSON.parse(body);
      const messages: WireMessage[] = input.messages;
      requests.push({
        tools: (input.tools ?? []).map((tool: any) => tool.function.name),
        messages,
        ...(input.reasoning_effort ? { reasoning_effort: input.reasoning_effort } : {}),
      });
      const lastUser = messages.findLastIndex(
        (message) => message.role === "user",
      );
      const round = messages.slice(lastUser + 1);
      const toolReplies = round.filter((message) => message.role === "tool");
      const calls = round.flatMap((message) => message.tool_calls ?? []);
      const replies = calls.map((call, index) => {
        try {
          return {
            name: call.function.name,
            data: JSON.parse(String(toolReplies[index]?.content ?? "{}")),
          };
        } catch {
          return { name: call.function.name, data: {} };
        }
      });
      const userText = String(messages[lastUser]?.content ?? "");
      const match = userText.match(
        /<relay_context>([\s\S]*?)<\/relay_context>/,
      );
      const context: ViewContext | undefined = match
        ? JSON.parse(match[1])
        : undefined;
      const appMatch = userText.match(
        /<relay_app_context>([\s\S]*?)<\/relay_app_context>/,
      );
      const appContext: AppContext | undefined = appMatch
        ? JSON.parse(appMatch[1])
        : undefined;
      const activeAppId = appContext?.appId ?? context?.source.appId ?? apps()[0]?.id;
      const find = userText
        .replace(
          /<relay_(?:app_)?context>[\s\S]*?<\/relay_(?:app_)?context>/g,
          "",
        )
        .match(/^Find:\s*([^\n]*)/im);
      const viewState = context?.viewState ?? appContext?.viewState;
      const query = find?.[1]?.trim() ?? viewState?.query ?? "";
      const search = replies.find((reply) => reply.name === "app_search")?.data;
      const items = Array.isArray(search)
        ? search
        : (search?.resources ?? search?.results ?? []);
      const target =
        (!find ? context?.source : undefined) ?? items[0]?.source ?? items[0];
      const report = replies.find((reply) => reply.name === "app_read")?.data;
      const section: Report["sections"][number] | undefined =
        report?.sections?.find(
          (item: Report["sections"][number]) =>
            !find && item.id === context?.sectionId,
        ) ??
        report?.sections?.find(
          (item: Report["sections"][number]) => item.id !== "content",
        ) ??
        report?.sections?.[0];
      const navigations = replies.filter(
        (reply) => reply.name === "app_navigate",
      ).map((reply) => reply.data);
      const navigation = navigations.at(-1);
      const highlightIds = (report?.sections ?? [])
        .filter((item: Report["sections"][number]) => section && item.id.startsWith(`${section.id}-`))
        .map((item: Report["sections"][number]) => item.id);
      let tool: { name: string; arguments: string } | undefined;
      if (activeAppId && !target && !search)
        tool = {
          name: "app_search",
          arguments: JSON.stringify({ appId: activeAppId, query }),
        };
      else if (target && !report)
        tool = {
          name: "app_read",
          arguments: JSON.stringify({
            appId: target.appId ?? activeAppId,
            resourceId: target.resourceId,
            revision: target.revision,
          }),
        };
      else if (report?.source && (!navigation ||
        (highlightIds.length && navigations.length === 1 && navigation.status === "applied")))
        tool = {
          name: "app_navigate",
          arguments: JSON.stringify({
            appId: report.source.appId,
            resourceId: report.source.resourceId,
            revision: report.source.revision,
            ...(section ? { sectionId: highlightIds.length && !navigation
              ? (report.sections.find((item: Report["sections"][number]) => item.id === "content")?.id ?? section.id)
              : section.id } : {}),
            ...(highlightIds.length && navigation ? { highlightIds } : {}),
            ...(viewState ? { viewState } : {}),
          }),
        };
      const appName = (id: string) => apps().find(app => app.id === id)?.name ?? id;
      let text = activeAppId
        ? `Scripted demonstration — ${appName(activeAppId)}\n\nNo matching saved resource was available.`
        : "No apps are registered.";
      const failure = report?.error ?? search?.error;
      if (typeof failure === "string") text += ` ${failure.slice(0, 500)}`;
      if (report?.source) {
        const sectionText =
          section?.text?.trim() ??
          "This resource has no readable section text.";
        const excerpt =
          sectionText.length > 1600
            ? `${sectionText.slice(0, 1600)}…`
            : sectionText;
        text = `Scripted demonstration — ${appName(report.source.appId)}\n\n${section?.title ?? "Saved resource"} (excerpt):\n${excerpt}\n\n[${report.source.title}](${report.source.sourceUrl}) · revision ${report.source.revision}.\n\n${navigation?.status === "applied" ? "The resource view opened on this device." : `View request: ${navigation?.status ?? "unavailable"}.`}`;
      }
      if (appContext?.surface) {
        const discovery = replies.find((reply) => reply.name === "app_discover")?.data;
        const result = replies.find((reply) => reply.name === "app_call")?.data;
        const presentation = replies.find((reply) => reply.name === "app_present")?.data;
        const operation = discovery?.operations?.[0];
        tool = undefined;
        if (!discovery) tool = { name: "app_discover", arguments: JSON.stringify({ appId: activeAppId }) };
        else if (operation && !result) {
          const args = Object.fromEntries(Object.entries(operation.inputSchema?.properties ?? {})
            .filter(([, schema]) => (schema as Record<string, unknown>).default !== undefined)
            .map(([name, schema]) => [name, (schema as Record<string, unknown>).default]));
          tool = { name: "app_call", arguments: JSON.stringify({ appId: activeAppId, operation: operation.name, arguments: args }) };
        } else if (result?.data?.presentation && !presentation)
          tool = { name: "app_present", arguments: JSON.stringify({ appId: activeAppId, intent: result.data.presentation }) };
        text = `Scripted demonstration — ${activeAppId}\n\n${JSON.stringify(result?.data ?? discovery?.error ?? "No operation result.", null, 2)}\n\nView request: ${presentation?.status ?? "not requested"}.`;
      }
      if (!context && !appContext && !find) {
        tool = undefined;
        text = "Scripted demonstration — your conversation is saved. Choose a live provider in Model connection for an AI reply.";
      }
      if (userText.includes("<template>\n## Objective")) {
        tool = undefined;
        text = `## Objective
- Fixture compaction: continue the saved conversation.
## Requirements
- Use current Relay context and retrieve original details when needed.
## Decisions
- (none)
## Work State
### Completed
- Previous conversation turns are recorded.
### Active
- Continue the user's task.
### Blocked
- (none)
## Next Move
1. Answer the next user message using current memory and original history.
## Relevant Files
- (none)
## Important Context
- This is a scripted transport test, not a semantic summary.`;
      }
      response.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
      });
      const chunk = (delta: unknown, finish: string | null = null) =>
        response.write(
          `data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: Math.floor(Date.now() / 1000), model: "relay-fixture", choices: [{ index: 0, delta, finish_reason: finish }], ...(finish ? { usage: { prompt_tokens: 100, completion_tokens: 30, total_tokens: 130 } } : {}) })}\n\n`,
        );
      if (tool)
        chunk({
          role: "assistant",
          tool_calls: [
            {
              index: 0,
              id: `fixture_${calls.length}`,
              type: "function",
              function: tool,
            },
          ],
        });
      else {
        chunk({
          role: "assistant",
          content: text.slice(0, Math.ceil(text.length / 2)),
        });
        await new Promise((resolve) => setTimeout(resolve, 60));
        chunk({ content: text.slice(Math.ceil(text.length / 2)) });
      }
      chunk({}, tool ? "tool_calls" : "stop");
      response.end("data: [DONE]\n\n");
    } catch {
      response.writeHead(500).end("Fixture request failed");
    }
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    url: `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1`,
    requests,
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  };
}

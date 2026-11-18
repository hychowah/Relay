import assert from "node:assert/strict";
import test from "node:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { load } from "cheerio";
import MessageContent, { citedSource } from "../web/MessageContent.tsx";
import ResponseTurn, { conversationTurns, sourceFocus } from "../web/ResponseTurn.tsx";
import type { Snapshot, Source } from "../shared/types.ts";

const source: Source = {
  appId: "research",
  resourceId: "comparison",
  revision: "v1",
  title: "Synthetic comparison",
  sourceUrl: "https://research.example/#/hand/comparison",
};

function markdown(text: string, sources: Source[] = []) {
  return load(
    renderToStaticMarkup(
      createElement(MessageContent, {
        text,
        sources,
        onOpenSource: () => {},
      }),
    ),
  );
}

test("assistant responses render GFM tables, emphasis, lists and code as readable elements", () => {
  const $ = markdown(`## Comparison

| Option | Evidence | Status |
| --- | --- | --- |
| Alpha | **Saved research** | Ready |
| Beta | Follow-up required | Pending |

**Next steps**

1. Read the report.
2. Compare the assumptions.

- Check the source.
- Keep the version.

\`\`\`ts
const selected = "Alpha";
\`\`\`

| Metric | Value |
| --- | ---: |
| Coverage | 12 |
`);
  assert.equal($("table").length, 2);
  assert.equal($(".markdown-table[tabindex='0']").length, 2);
  assert.equal($("thead th").length, 5);
  assert.equal($("tbody tr").length, 3);
  assert.equal($("tbody strong").text(), "Saved research");
  assert.equal($("ol > li").length, 2);
  assert.equal($("ul > li").length, 2);
  assert.equal($("pre code.language-ts").text(), 'const selected = "Alpha";\n');
});

test("source citations open known app routes while unsafe or unknown local links cannot navigate", () => {
  const $ = markdown(
    `[Saved report](${source.sourceUrl})

[Route](#/hand/comparison), \`#/hand/comparison\`, [Relative](/#/hand/comparison)

[External](https://example.com/docs) [Unsafe](javascript:alert%281%29) [Local](/settings)

<script>alert('unsafe')</script>
<img src=x onerror=alert(1)>
`,
    [source],
  );
  assert.equal($("button.inline-source").length, 4);
  assert.equal($("a").length, 1);
  assert.equal($("a").attr("href"), "https://example.com/docs");
  assert.equal($("a").attr("rel"), "noopener noreferrer");
  assert.equal($("a").attr("target"), "_blank");
  assert.equal($("script, img, [onerror]").length, 0);
  assert.ok($.text().includes("Unsafe"));
  assert.equal(citedSource("#/hand/comparison", [source]), source);
  const fixtureSource = { ...source, sourceUrl: "/api/fixtures/comparison" };
  assert.equal(
    citedSource(fixtureSource.sourceUrl, [fixtureSource]),
    fixtureSource,
  );
  assert.equal(
    citedSource("javascript:alert(1)", [
      { ...source, sourceUrl: "javascript:alert(1)" },
    ]),
    undefined,
  );
  assert.equal(
    citedSource("#/hand/comparison", [
      source,
      { ...source, appId: "another-app" },
    ]),
    undefined,
  );
});

test("existing history groups collapsed activity and sources with their own response", () => {
  const snapshot: Snapshot = {
    conversation: {
      id: "conversation",
      title: "Synthetic",
      createdAt: "2026-01-01T00:00:00Z",
      botId: null,
    },
    messages: [
      {
        id: "q1",
        role: "user",
        text: "**Keep my text literal**",
        createdAt: "2026-01-01T00:00:00Z",
      },
      {
        id: "a1",
        role: "assistant",
        text: "**First response**",
        createdAt: "2026-01-01T00:00:01Z",
      },
      {
        id: "q2",
        role: "user",
        text: "Follow up",
        createdAt: "2026-01-01T00:01:00Z",
      },
      {
        id: "a2",
        role: "assistant",
        text: "Second response",
        createdAt: "2026-01-01T00:01:01Z",
      },
    ],
    runs: [
      {
        id: "r1",
        conversationId: "conversation",
        status: "completed",
        startedAt: "2026-01-01T00:00:00Z",
      },
      {
        id: "r2",
        conversationId: "conversation",
        status: "completed",
        startedAt: "2026-01-01T00:01:00Z",
      },
    ],
    tools: [
      {
        id: "t1",
        runId: "r1",
        name: "app_read",
        input: {},
        output: { source, sections: [] },
        createdAt: "2026-01-01T00:00:00Z",
      },
      {
        id: "t2",
        runId: "r2",
        name: "app_search",
        input: {},
        output: [],
        createdAt: "2026-01-01T00:01:00Z",
      },
    ],
    commands: [],
    forwards: [],
  };
  const turns = conversationTurns(snapshot);
  assert.equal(turns.length, 2);
  assert.deepEqual(
    turns.map((turn) => turn.tools.map((tool) => tool.id)),
    [["t1"], ["t2"]],
  );
  const first = load(
    renderToStaticMarkup(
      createElement(ResponseTurn, { turn: turns[0], onOpenSource: () => {} }),
    ),
  );
  const second = load(
    renderToStaticMarkup(
      createElement(ResponseTurn, { turn: turns[1], onOpenSource: () => {} }),
    ),
  );
  assert.equal(first(".message.user strong").length, 0);
  assert.equal(
    first(".message.user .message-text").text(),
    "**Keep my text literal**",
  );
  assert.equal(first(".message.assistant strong").text(), "First response");
  assert.equal(first(".source-list button").length, 1);
  assert.equal(second(".source-citations").length, 0);
  assert.equal(first("details[open]").length, 0);
  assert.ok(
    first(".tool-activity summary").first().text().includes("Completed"),
  );
  assert.equal(first(".response-complete").text(), "Response complete");
  const children = first(".response-turn").children().toArray();
  assert.ok(
    children.indexOf(first(".tool-activity")[0]) <
      children.indexOf(first(".message.assistant")[0]),
  );
  assert.ok(
    children.indexOf(first(".source-citations")[0]) <
      children.indexOf(first(".message.assistant")[0]),
  );
});

test("v2 operation evidence, real progress and source-less presentation remain inspectable", () => {
  const turn = {
    id: "question", messages: [], runs: [],
    tools: [{ id: "operation", runId: "run", name: "app_call", input: { operation: "layout.inspect" }, output: { data: {}, sources: [source] }, status: "completed" as const, progress: [{ type: "progress" as const, message: "Inspecting furniture dimensions" }], createdAt: "2026-01-01T00:00:00Z" }],
    commands: [{ kind: "present" as const, id: "presentation", runId: "run", appId: "room", intent: { viewId: "layout" }, expectedGeneration: 0, deviceId: "desktop", tabId: "tab", expectedViewToken: "home", status: "applied" as const }],
  };
  const $ = load(renderToStaticMarkup(createElement(ResponseTurn, { turn, onOpenSource() {} })));
  assert.equal($(".tool-record li").text(), "Inspecting furniture dimensions");
  assert.equal($(".source-list button").text(), `▤${source.title}↗`);
  assert.equal($(".command-status").text(), "App presentation: applied");
});


test("citations restore only successfully presented targets from the same source revision", () => {
  const command = { kind: "present" as const, id: "shown", runId: "run", appId: source.appId,
    intent: { viewId: source.resourceId, source, targetIds: ["price", "dof"] }, expectedGeneration: 0,
    deviceId: "desktop", tabId: "tab", expectedViewToken: "home", status: "applied" as const };
  assert.deepEqual(sourceFocus([command], source), { sectionId: "price", highlightIds: ["price", "dof"] });
  assert.equal(sourceFocus([{ ...command, status: "failed" }], source), undefined);
  assert.equal(sourceFocus([command], { ...source, revision: "different" }), undefined);
  assert.deepEqual(sourceFocus([command, { ...command, status: "stale", intent: { ...command.intent, targetIds: ["other"] } }], source)?.highlightIds, ["price", "dof"]);
});

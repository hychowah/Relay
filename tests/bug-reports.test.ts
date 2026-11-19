import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createWorkspace } from "../server/app.ts";
import { addBugReports } from "../server/bug-reports.ts";
import { Store } from "../server/store.ts";

test("bug reports save the recording with the server's conversation and without API keys", async () => {
  const dir = await mkdtemp(join(tmpdir(), "relay-bug-reports-"));
  const store = new Store(":memory:");
  const workspace = createWorkspace(store, [], { mode: "fixture", model: "fixture", configured: true });
  addBugReports(workspace.app, dir, store);
  const conversation = store.createConversation("Desk question", "session-1", null);
  const post = (body: unknown) => workspace.app.request("/api/bug-reports", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  try {
    const response = await post({
      description: "Stop did nothing",
      conversationId: conversation.id,
      screenshot: Buffer.from("png bytes").toString("base64"),
      events: [
        { type: "action", name: "send" },
        { type: "request", method: "POST", path: "/api/settings/provider", body: { mode: "deepseek", apiKey: "sk-private" } },
      ],
    });
    assert.equal(response.status, 201);
    const { id, file } = await response.json() as { id: string; file: string };
    assert.equal(file, `bug-reports/${id}.json`);
    assert.deepEqual((await readdir(dir)).sort(), [`${id}.json`, `${id}.png`]);
    const text = await readFile(join(dir, `${id}.json`), "utf8");
    assert.doesNotMatch(text, /sk-private/);
    const report = JSON.parse(text);
    assert.equal(report.description, "Stop did nothing");
    assert.equal(report.events[1].body.apiKey, "[redacted]");
    assert.equal(report.screenshot, `${id}.png`);
    assert.equal(report.serverConversation.conversation.title, "Desk question");
    assert.equal(await readFile(join(dir, `${id}.png`), "utf8"), "png bytes");

    assert.equal((await post({ events: [] })).status, 400);
  } finally {
    await workspace.close();
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
});

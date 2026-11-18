import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { Harness } from "../server/harness.ts";

test("real OpenCode retains originals through two compactions and reinjects current memory and checkpoint", { timeout: 45_000 }, async () => {
  await mkdir(resolve("tmp"), { recursive: true });
  const directory = await mkdtemp(resolve("tmp/compaction-test-"));
  let memory = "Initial preference: answer briefly.";
  let checkpoint = "Initial task: collect examples.";
  let harness: Harness | undefined;
  try {
    harness = await Harness.start({
      dataDir: directory,
      mode: "fixture",
      model: "relay-fixture",
      reasoningEffort: "low",
      contextHandler: () => ({
        memories: [{ key: "answer-format", content: memory }],
        checkpoint: { content: checkpoint },
      }),
      toolHandler: async () => assert.fail("Normal chat must not call app tools"),
    });
    const session = await harness.createSession("Compaction evidence");
    const settle = async () => {
      for (let attempt = 0; attempt < 150; attempt++) {
        const state = await harness!.inspect(session);
        assert.notEqual(state.status, "error", state.error);
        if (state.status === "idle") return state;
        await delay(50);
      }
      assert.fail("The local provider turn did not settle");
    };
    const original = "Original detail: the example identifier is relay-482. " + "Retained historical material. ".repeat(500);
    await harness.prompt(session, original, undefined, undefined, "max");
    const initial = await settle();
    const originalMessages = initial.messages;
    assert.equal(originalMessages[0].text, original);

    for (let round = 1; round <= 2; round++) {
      memory = `Corrected preference ${round}: use readable paragraphs.`;
      checkpoint = `Current checkpoint ${round}: compare the remaining examples.`;
      const receipt = await harness["request"](`/api/session/${session}/compact`, {});
      assert.equal(receipt.data.type, "compaction");
      let completed = false;
      for (let attempt = 0; attempt < 150; attempt++) {
        const archive = await harness["request"](`/api/session/${session}/message?order=asc&limit=200`);
        const compactions = archive.data.filter((row: any) => row.type === "compaction");
        const active = await harness["request"]("/api/session/active");
        assert.ok(!compactions.some((row: any) => row.status === "failed"), JSON.stringify(compactions));
        if (compactions.filter((row: any) => row.status === "completed").length === round && !active.data[session]) {
          completed = true;
          assert.match(compactions.at(-1).summary, /## Objective/);
          break;
        }
        await delay(50);
      }
      assert.ok(completed, `Compaction ${round} did not finish`);
      const requestsBefore = harness["fixture"]!.requests.length;
      await harness.prompt(session, `Continue normally after compaction ${round}.`, undefined, undefined, "max");
      const continued = await settle();
      const requests = harness["fixture"]!.requests.slice(requestsBefore).filter((request) => request.tools.length > 0);
      assert.ok(requests.length > 0, "Continuation reached the actual local provider");
      for (const request of requests) {
        const system = request.messages.filter((message) => message.role === "system").map((message) => String(message.content)).join("\n");
        assert.ok(system.includes(memory), "Latest corrected memory was reinjected");
        assert.ok(system.includes(checkpoint), "Latest task checkpoint was reinjected");
      }
      for (const message of originalMessages) {
        assert.deepEqual(continued.messages.find((candidate) => candidate.id === message.id), message);
      }
    }
    const compactionRequests = harness["fixture"]!.requests.filter((request) => request.messages.some((message) =>
      message.role === "user" && String(message.content).includes("<template>\n## Objective")));
    assert.equal(compactionRequests.length, 2);
    assert.ok(harness["fixture"]!.requests.every((request) => request.reasoning_effort === "max"), "Thinking effort reaches conversation and compaction model requests");
  } finally {
    await harness?.close();
    await rm(directory, { recursive: true, force: true });
  }
});

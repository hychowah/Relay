import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { Harness } from "../server/harness.ts";

test("DeepSeek adapter sends every supported thinking effort and clears it on provider default", { timeout: 45_000 }, async () => {
  await mkdir(resolve("tmp"), { recursive: true });
  const dir = await mkdtemp(resolve("tmp/effort-wire-test-"));
  let harness: Harness | undefined;
  let session: string | undefined;
  let originals: string[] = [];
  try {
    for (const reasoningEffort of ["default", "none", "low", "high", "max", "default"] as const) {
      harness = await Harness.start({
        dataDir: dir,
        mode: "fixture",
        model: "deepseek-flash",
        reasoningEffort,
        toolHandler: async () => assert.fail("Normal chat must not call app tools"),
      });
      session ??= await harness.createSession("Thinking effort");
      const firstTurn = originals.length === 0;
      await harness.prompt(session, firstTurn ? "Find: saved notes" : `Use thinking setting ${reasoningEffort}.`);
      let state = await harness.inspect(session);
      for (let attempt = 0; state.status === "running" && attempt < 150; attempt++) {
        await new Promise((resolveWait) => setTimeout(resolveWait, 50));
        state = await harness.inspect(session);
      }
      assert.equal(state.status, "idle", state.error);
      if (firstTurn) assert.match(state.messages.at(-1)!.text, /No apps are registered/);
      assert.deepEqual(state.messages.slice(0, originals.length).map((message) => message.id), originals);
      originals = state.messages.map((message) => message.id);
      const requests = harness["fixture"]!.requests;
      assert.ok(requests.length > 0);
      for (const request of requests)
        assert.equal(request.reasoning_effort, reasoningEffort === "default" ? undefined : reasoningEffort);
      await harness.close();
      harness = undefined;
    }
  } finally {
    await harness?.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test("conversation effort stays isolated across simultaneous sessions and can return to defaults", { timeout: 30_000 }, async () => {
  const dir = await mkdtemp(resolve("tmp/conversation-effort-wire-"));
  const harness = await Harness.start({
    dataDir: dir, mode: "fixture", model: "deepseek-flash", reasoningEffort: "high",
    toolHandler: async () => assert.fail("Normal chat must not call app tools"),
  });
  try {
    const sessions = await Promise.all([harness.createSession("Fast"), harness.createSession("Thorough")]);
    const settle = async (session: string) => {
      for (let i = 0; i < 150; i++) {
        const state = await harness.inspect(session);
        assert.notEqual(state.status, "error", state.error);
        if (state.status === "idle") return;
        await new Promise((resolveWait) => setTimeout(resolveWait, 50));
      }
      assert.fail("Conversation did not settle");
    };
    await Promise.all(sessions.map((session, i) => harness.prompt(session, `Isolated effort ${i}`, undefined, undefined, i ? "max" : "low")));
    await Promise.all(sessions.map(settle));
    for (let i = 0; i < 2; i++) {
      const requests = harness["fixture"]!.requests.filter((request) => request.messages.some((message) => message.role === "user" && message.content === `Isolated effort ${i}`));
      assert.ok(requests.length > 0);
      assert.ok(requests.every((request) => request.reasoning_effort === (i ? "max" : "low")));
    }
    for (const effort of ["default", "none", null] as const) {
      const before = harness["fixture"]!.requests.length;
      await harness.prompt(sessions[0], `Switch effort to ${effort}`, undefined, undefined, effort);
      await settle(sessions[0]);
      const requests = harness["fixture"]!.requests.slice(before);
      assert.ok(requests.length > 0);
      assert.ok(requests.every((request) => request.reasoning_effort === (effort === "default" ? undefined : effort ?? "high")));
    }
    await harness.deleteSession(sessions[0]);
    await assert.rejects(harness.inspect(sessions[0]), /404/);
    await harness.deleteSession(sessions[0]);
    assert.equal((await harness.inspect(sessions[1])).status, "idle");
  } finally {
    await harness.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test(
  "real OpenCode exposes only Relay tools, refreshes context, and restores after restart",
  { timeout: 45_000 },
  async () => {
    await mkdir(resolve("tmp"), { recursive: true });
    const dir = await mkdtemp(resolve("tmp/harness-test-"));
    const source = {
      appId: "notes",
      resourceId: "fixture",
      revision: "v1",
      title: "Fixture report",
      sourceUrl: "https://fixture.test/report",
    };
    const calls: string[] = [];
    let pauseRead = false;
    let releaseRead: () => void = () => {};
    let readStarted: () => void = () => {};
    let memory = "Prefer concise tables.";
    const options = {
      dataDir: dir,
      mode: "fixture" as const,
      model: "relay-fixture",
      apps: () => [{ id: source.appId, name: "Notes" }],
      contextHandler: () => ({ memories: [{ key: "format", content: memory }] }),
      toolHandler: async (_session: string, name: string, _input: unknown) => {
        calls.push(name);
        if (name === "app_search") return [source];
        if (name === "app_read") {
          if (pauseRead) {
            readStarted();
            await new Promise<void>((resolveRead) => {
              releaseRead = resolveRead;
            });
          }
          return {
            source,
            sections: [
              {
                id: "risks",
                title: "Risks",
                text: "Customer concentration risk.",
              },
            ],
          };
        }
        return { status: "pending", source };
      },
    };
    let harness: Harness | undefined;
    try {
      harness = await Harness.start(options);
      const session = await harness.createSession("Fixture question");
      const context = {
        source,
        viewToken: "device-tab-1",
        selection: "Concentration",
      };
      await harness.prompt(
        session,
        "Explain this and open its report.",
        context,
      );
      let result = await harness.inspect(session);
      for (
        let attempt = 0;
        result.status === "running" && attempt < 100;
        attempt++
      ) {
        await new Promise((resolveWait) => setTimeout(resolveWait, 100));
        result = await harness.inspect(session);
      }
      assert.equal(result.status, "idle");
      assert.deepEqual(calls, ["app_read", "app_navigate"]);
      assert.deepEqual(result.messages[0].context, context);
      assert.match(result.messages.at(-1)!.text, /Customer concentration risk/);
      assert.match(
        result.messages.at(-1)!.text,
        /https:\/\/fixture.test\/report/,
      );
      assert.match(result.messages.at(-1)!.text, /pending/);
      assert.doesNotMatch(result.messages.at(-1)!.text, /view opened/);
      assert.ok(result.usage!.input > 0);
      const requests = harness["fixture"]!.requests;
      assert.ok(requests.length >= 3);
      assert.ok(requests.every((request) => request.reasoning_effort === undefined), "Default preserves the provider's thinking behavior");
      for (const request of requests)
        assert.deepEqual([...request.tools].sort(), [
          "app_call",
          "app_discover",
          "app_navigate",
          "app_present",
          "app_read",
          "app_search",
          "checkpoint_save",
          "history_read",
          "history_search",
          "memory_forget",
          "memory_save",
          "memory_search",
        ]);
      assert.ok(requests.every(({ messages }) => messages.some((message) =>
        message.role === "system" && String(message.content).includes(memory))));
      const messageIds = result.messages.map((message) => message.id);
      // A prior provider selection survives the runtime. Recording it does not
      // contact that provider; the following turn must use the new fixture config.
      await harness["request"](`/api/session/${session}/model`, {
        model: { providerID: "retired-provider", id: "retired-model" },
      });
      await harness.close();
      memory = "Prefer short paragraphs.";
      harness = await Harness.start({ ...options, reasoningEffort: "max" });
      const restored = await harness.inspect(session);
      assert.equal(restored.status, "idle");
      assert.deepEqual(
        restored.messages.map((message) => message.id),
        messageIds,
      );
      assert.deepEqual(restored.messages[0].context, context);
      assert.equal(
        (await harness["request"](`/api/session/${session}`)).data.model
          .providerID,
        "retired-provider",
      );
      await harness.prompt(
        session,
        "Continue with the newly configured provider.",
        context,
        undefined,
        "low",
      );
      let continued = await harness.inspect(session);
      for (
        let attempt = 0;
        continued.status === "running" && attempt < 100;
        attempt++
      ) {
        await new Promise((resolveWait) => setTimeout(resolveWait, 50));
        continued = await harness.inspect(session);
      }
      assert.equal(continued.status, "idle");
      assert.match(
        continued.messages.at(-1)!.text,
        /Customer concentration risk/,
      );
      const selectedModel = (
        await harness["request"](`/api/session/${session}`)
      ).data.model;
      assert.equal(selectedModel.providerID, "fixture");
      assert.equal(selectedModel.id, "relay-fixture");
      assert.ok(
        harness["fixture"]!.requests.length > 0,
        "The restored conversation made real requests to the local provider",
      );
      assert.ok(harness["fixture"]!.requests.every((request) => request.reasoning_effort === "low"), "Conversation effort overrides the connection on every tool step after restart");
      assert.ok(harness["fixture"]!.requests.every(({ messages }) => messages.some((message) =>
        message.role === "system" && String(message.content).includes(memory))));
      assert.deepEqual(
        continued.messages
          .slice(0, messageIds.length)
          .map((message) => message.id),
        messageIds,
      );
      await harness.interrupt(session); // An idle cancellation is a supported no-op.
      pauseRead = true;
      const started = new Promise<void>((resolveStarted) => {
        readStarted = resolveStarted;
      });
      const cancellationSession = await harness.createSession("Cancellation");
      await harness.prompt(cancellationSession, "Read this report.", context);
      await started;
      assert.equal(
        (await harness.inspect(cancellationSession)).status,
        "running",
      );
      await harness.interrupt(cancellationSession);
      releaseRead();
      const interrupted = await harness.inspect(cancellationSession);
      assert.equal(interrupted.status, "idle");
      assert.equal(
        interrupted.messages.filter((message) => message.role === "assistant")
          .length,
        0,
      );

      // Reproduce the observed upstream pagination contract: a streamed row
      // changes in place while a later cursor page gains the idle event.
      const originalRequest = harness["request"].bind(harness);
      let rowSettled = false;
      const user = {
        id: "msg_user",
        type: "user",
        text: "Explain this.",
        time: { created: 1 },
      };
      const assistant = (text: string) => ({
        id: "msg_answer",
        type: "assistant",
        content: [{ type: "text", text }],
        time: { created: 2 },
      });
      const idle = {
        id: "msg_idle",
        type: "idle",
        outcome: "succeeded",
        time: { created: 3 },
      };
      harness["pending"].set("pagination-race", user.id);
      harness["request"] = async (path: string, data?: unknown) => {
        if (path === "/api/session/active")
          return {
            data: rowSettled ? {} : { "pagination-race": { type: "running" } },
          };
        if (path.includes("pagination-race/message")) {
          if (path.includes("cursor=")) {
            rowSettled = true;
            return { data: [idle], cursor: {} };
          }
          return rowSettled
            ? {
                data: [user, assistant("Customer concentration risk."), idle],
                cursor: {},
              }
            : { data: [user, assistant("")], cursor: { next: "tail" } };
        }
        if (path === "/api/session/pagination-race")
          return {
            data: {
              tokens: {
                input: 1,
                output: 1,
                reasoning: 0,
                cache: { read: 0, write: 0 },
              },
            },
          };
        return originalRequest(path, data);
      };
      try {
        assert.equal(
          (await harness.inspect("pagination-race")).status,
          "running",
        );
        const stable = await harness.inspect("pagination-race");
        assert.equal(stable.status, "idle");
        assert.match(
          stable.messages.at(-1)!.text,
          /Customer concentration risk/,
        );
      } finally {
        harness["request"] = originalRequest;
      }
    } finally {
      releaseRead();
      await harness?.close();
      await rm(dir, { recursive: true, force: true });
    }
  },
);

test(
  "configured app demo searches its own app and preserves selected section, revision and view state",
  { timeout: 30_000 },
  async () => {
    await mkdir(resolve("tmp"), { recursive: true });
    const dir = await mkdtemp(resolve("tmp/harness-app-test-"));
    const source = {
      appId: "field-notes",
      resourceId: "pose-study",
      revision: "v7",
      title: "Pose study",
      sourceUrl: "https://notes.test/pose",
    };
    const calls: Array<{ name: string; input: any }> = [];
    const harness = await Harness.start({
      dataDir: dir,
      mode: "fixture",
      model: "relay-fixture",
      apps: () => [
        { id: "field-notes", name: "Field Notes" },
        { id: "lab-archive", name: "Lab Archive" },
      ],
      toolHandler: async (_sessionId, name, input) => {
        const args = input as Record<string, string>;
        calls.push({ name, input });
        assert.ok(["field-notes", "lab-archive"].includes(args.appId));
        if (name === "app_search") return [{ ...source, appId: args.appId }];
        if (name === "app_read")
          return {
            source: {
              ...source,
              appId: args.appId,
              revision: args.revision ?? "v7",
            },
            sections: [
              {
                id: "content",
                title: "Overview",
                text: "Whole resource overview.",
              },
              {
                id: "methods",
                title: "Methods",
                text: "Recorded method detail. ".repeat(200),
              },
              {
                id: "findings",
                title: "Findings",
                text: "Selected publication findings.",
              },
            ],
          };
        return { status: "applied", source };
      },
    });
    const settle = async (session: string) => {
      let state = await harness.inspect(session);
      for (
        let attempt = 0;
        state.status === "running" && attempt < 100;
        attempt++
      ) {
        await new Promise((resolveWait) => setTimeout(resolveWait, 50));
        state = await harness.inspect(session);
      }
      assert.equal(state.status, "idle");
      return state;
    };
    try {
      const searched = await harness.createSession("Find notes");
      await harness.prompt(searched, "Find: kinematics");
      const searchResult = await settle(searched);
      assert.deepEqual(
        calls.map(({ name }) => name),
        ["app_search", "app_read", "app_navigate"],
      );
      assert.deepEqual(calls[0].input, {
        appId: "field-notes",
        query: "kinematics",
      });
      assert.equal(calls[2].input.sectionId, "methods");
      const excerpt = searchResult.messages.at(-1)!.text;
      assert.match(excerpt, /Scripted demonstration — Field Notes/);
      assert.match(excerpt, /Recorded method detail/);
      assert.ok(
        excerpt.length < 2100,
        "Large app sections produce bounded excerpts",
      );

      calls.length = 0;
      const selected = await harness.createSession("Selected notes");
      const context = {
        source: { ...source, revision: "v3" },
        viewToken: "selected-view",
        sectionId: "findings",
        viewState: {
          query: "pose",
          filters: { category: "robotics" },
          language: "zh",
        },
      };
      await harness.prompt(selected, "Show this selected section.", context);
      const selectionResult = await settle(selected);
      assert.deepEqual(
        calls.map(({ name }) => name),
        ["app_read", "app_navigate"],
      );
      assert.equal(
        calls.find(({ name }) => name === "app_read")!.input.revision,
        "v3",
      );
      assert.deepEqual(calls[1].input, {
        appId: "field-notes",
        resourceId: "pose-study",
        revision: "v3",
        sectionId: "findings",
        viewState: context.viewState,
      });
      assert.deepEqual(selectionResult.messages[0].context, context);
      assert.match(
        selectionResult.messages.at(-1)!.text,
        /Selected publication findings/,
      );
      assert.match(selectionResult.messages.at(-1)!.text, /revision v3/);

      calls.length = 0;
      const appHome = await harness.createSession("App home search");
      const appContext = {
        appId: "lab-archive",
        viewToken: "app-home",
        viewState: {
          query: "old query",
          filters: { year: "2026" },
          language: "en",
        },
      };
      await harness.prompt(appHome, "Find: actuators", undefined, appContext);
      const appResult = await settle(appHome);
      assert.deepEqual(calls[0].input, {
        appId: "lab-archive",
        query: "actuators",
      });
      assert.deepEqual(calls[2].input.viewState, appContext.viewState);
      assert.equal(calls[2].input.appId, "lab-archive");
      assert.deepEqual(appResult.messages[0].appContext, appContext);
      assert.equal(appResult.messages[0].context, undefined);
    } finally {
      await harness.close();
      await rm(dir, { recursive: true, force: true });
    }
  },
);

test("real harness presents an initial native view then final published field targets", { timeout: 30_000 }, async () => {
  const dir = await mkdtemp(resolve("tmp/harness-highlight-test-"));
  const source = {
    appId: "field-notes", resourceId: "study", revision: "v1",
    title: "Synthetic study", sourceUrl: "https://notes.test/study",
  };
  const calls: Array<{ name: string; input: any }> = [];
  const harness = await Harness.start({
    dataDir: dir, mode: "fixture", model: "relay-fixture",
    apps: () => [{ id: "field-notes", name: "Field Notes" }],
    toolHandler: async (_session, name, input) => {
      calls.push({ name, input });
      if (name === "app_search") return [source];
      if (name === "app_read") return { source, sections: [
        { id: "content", title: "Overview", text: "Synthetic overview." },
        { id: "sample", title: "Sample", text: "Recorded sample evidence." },
        { id: "sample-measurement", title: "Measurement", text: "Published value A." },
        { id: "sample-condition", title: "Condition", text: "Published qualification B." },
      ] };
      return { status: "applied", source };
    },
  });
  try {
    const session = await harness.createSession("Visible evidence");
    await harness.prompt(session, "Find: sample", undefined, { appId: "field-notes" });
    let state = await harness.inspect(session);
    for (let attempt = 0; state.status === "running" && attempt < 150; attempt++) {
      await new Promise((done) => setTimeout(done, 50));
      state = await harness.inspect(session);
    }
    assert.equal(state.status, "idle", state.error);
    assert.deepEqual(calls.map(({ name }) => name), ["app_search", "app_read", "app_navigate", "app_navigate"]);
    assert.equal(calls[2].input.sectionId, "content");
    assert.equal(calls[2].input.highlightIds, undefined);
    assert.equal(calls[3].input.sectionId, "sample");
    assert.deepEqual(calls[3].input.highlightIds, ["sample-measurement", "sample-condition"]);
    assert.match(state.messages.at(-1)!.text, /Recorded sample evidence/);
    assert.match(state.messages.at(-1)!.text, /view opened on this device/);
  } finally {
    await harness.close();
    await rm(dir, { recursive: true, force: true });
  }
});

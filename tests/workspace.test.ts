import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { setTimeout as delay } from "node:timers/promises";
import { createWorkspace, type AgentHarness } from "../server/app.ts";
import { Store } from "../server/store.ts";
import type { Inspection } from "../server/harness.ts";

const fixtureResourceId = "room-plan";
function roomReport() {
  return {
    source: {
      appId: "rooms", resourceId: fixtureResourceId, revision: "v1",
      title: "Room plan", sourceUrl: "https://rooms.test/plans/room-plan",
    },
    sections: [
      { id: "furniture", title: "Furniture", text: "Desk and lamp" },
      { id: "desk", title: "Desk", text: "By the window" },
      { id: "lamp", title: "Lamp", text: "On the desk" },
    ],
  };
}

async function until(condition: () => boolean) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await delay(20);
  }
  assert.fail("Expected state did not arrive.");
}

function setup(store: Store, mode: "fixture" | "anthropic" = "fixture") {
  const workspace = createWorkspace(
    store,
    [
      {
        id: "rooms",
        name: "Rooms",
        description: "Fixture",
        integration: { read: async () => roomReport() },
      },
    ],
    { mode, model: "fixture", configured: true },
  );
  let state: Inspection = {
    messages: [],
    status: "idle",
    usage: { input: 10 },
  };
  const harness: AgentHarness = {
    async deleteSession() {},
    async createSession() {
      return "session-1";
    },
    async prompt() {
      state = { ...state, status: "running" };
    },
    async inspect() {
      return state;
    },
    async interrupt() {
      state = { ...state, status: "idle" };
    },
  };
  workspace.setHarness(harness);
  const post = (path: string, body: unknown) =>
    workspace.app.request(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  return {
    workspace,
    post,
    complete() {
      state = {
        messages: [
          {
            id: "assistant-1",
            role: "assistant",
            text: "A sourced response.",
            createdAt: new Date().toISOString(),
          },
        ],
        status: "idle",
        usage: { input: 40 },
      };
    },
  };
}

test("a screenshot is admitted only with image input and recorded with its question", async () => {
  for (const mode of ["fixture", "anthropic"] as const) {
    const store = new Store(":memory:");
    const { workspace, post, complete } = setup(store, mode);
    try {
      const { id } = await (await post("/api/conversations", {})).json();
      const response = await post(`/api/conversations/${id}/messages`, {
        text: "What is shown?", deviceId: "mac", tabId: "tab",
        capture: {appId: "rooms", png: "iVBORw0KGgo="},
      });
      assert.equal(response.status, mode === "fixture" ? 400 : 202);
      if (mode === "anthropic") {
        const message = store.snapshot(id)!.messages[0];
        assert.equal(message.hasCapture, true);
        const saved = await workspace.app.request(`/api/conversations/${id}/messages/${message.id}/capture`);
        assert.equal(saved.headers.get("Content-Type"), "image/png");
        assert.deepEqual(Buffer.from(await saved.arrayBuffer()), Buffer.from("iVBORw0KGgo=", "base64"));
        complete();
      } else {
        assert.equal(store.snapshot(id)!.messages.length, 0);
      }
    } finally {
      await workspace.close();
      store.close();
    }
  }
});

test("background run persists context, exact report and device-confirmed navigation across reopening", async () => {
  const dir = await mkdtemp(join(tmpdir(), "relay-store-"));
  const path = join(dir, "relay.sqlite");
  let store = new Store(path);
  const { workspace, post, complete } = setup(store);
  let workspaceClosed = false;
  try {
    const conversation = await (await post("/api/conversations", {})).json();
    const report = await (
      await workspace.app.request(
        `/api/apps/rooms/read?resourceId=${fixtureResourceId}`,
      )
    ).json();
    const context = {
      source: report.source,
      viewToken: "view-a",
      sectionId: "furniture",
      selection: "Desk and lamp",
    };
    const response = await post(
      `/api/conversations/${conversation.id}/messages`,
      { text: "Explain this", deviceId: "desktop", tabId: "tab-a", context },
    );
    assert.equal(response.status, 202);
    const run = await response.json();
    await delay(10);
    const navigation = workspace.toolHandler("session-1", "app_navigate", {
      ...report.source,
      sectionId: "furniture",
      highlightIds: ["desk", "lamp"],
    });
    await until(() => store.snapshot(conversation.id)!.commands.length === 1);
    const command = store.snapshot(conversation.id)!.commands[0];
    assert.equal(command.kind, "navigate");
    assert.equal(command.status, "pending");
    assert.deepEqual(command.highlightIds, ["desk", "lamp"]);
    const started = store.snapshot(conversation.id)!.tools[0];
    assert.equal(started.status, "running");
    assert.equal(started.output, null);
    assert.equal(command.expectedViewToken, context.viewToken);
    assert.equal(
      (
        await post(`/api/commands/${command.id}/ack`, {
          deviceId: "phone",
          tabId: "other",
          status: "applied",
        })
      ).status,
      403,
    );
    assert.equal(store.command(command.id)!.status, "pending");
    await post(`/api/commands/${command.id}/ack`, {
      deviceId: "desktop",
      tabId: "tab-a",
      status: "applied",
    });
    assert.equal(((await navigation) as { status: string }).status, "applied");
    const finished = store.snapshot(conversation.id)!.tools;
    assert.equal(finished.length, 1);
    assert.equal(finished[0].id, started.id);
    assert.equal(finished[0].status, "completed");
    complete();
    await until(() => store.run(run.id)!.status === "completed");
    assert.equal(store.run(run.id)!.usage!.input, 30);
    await workspace.close();
    workspaceClosed = true;
    store.close();
    store = new Store(path);
    const recovered = store.snapshot(conversation.id)!;
    assert.deepEqual(recovered.messages[0].context, context);
    assert.equal(recovered.messages[1].text, "A sourced response.");
    assert.equal(recovered.commands[0].status, "applied");
    assert.equal(recovered.commands[0].kind, "navigate");
    assert.deepEqual(recovered.commands[0].highlightIds, ["desk", "lamp"]);
    assert.equal(
      store.report(
        "rooms",
        report.source.resourceId,
        report.source.revision,
      )!.source.revision,
      report.source.revision,
    );
  } finally {
    if (!workspaceClosed) await workspace.close();
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test("unavailable app, cancellation and interrupted recovery preserve accurate status without replay", async () => {
  const store = new Store(":memory:");
  const { workspace, post } = setup(store);
  try {
    const conversation = await (await post("/api/conversations", {})).json();
    const first = await (
      await post(`/api/conversations/${conversation.id}/messages`, {
        text: "Read a report",
        deviceId: "desktop",
        tabId: "tab-a",
      })
    ).json();
    await delay(10);
    const result = await workspace.toolHandler("session-1", "app_read", {
      appId: "missing",
      resourceId: "none",
    });
    assert.deepEqual(result, { error: "App is not registered." });
    assert.equal(store.run(first.id)!.status, "running");
    const report = roomReport();
    const pending = store.createCommand(
      store.run(first.id)!,
      report.source,
      "furniture",
    );
    assert.equal((await post(`/api/runs/${first.id}/cancel`, {})).status, 200);
    assert.equal(store.run(first.id)!.status, "cancelled");
    assert.equal(store.command(pending.id)!.status, "failed");
    const interrupted = store.startRun(
      conversation.id,
      "Another question",
      "phone",
      "tab-b",
    );
    const stale = store.createCommand(interrupted, report.source, "furniture");
    store.recover();
    assert.equal(store.run(interrupted.id)!.status, "interrupted");
    assert.equal(store.command(stale.id)!.status, "failed");
    assert.equal(store.snapshot(conversation.id)!.messages.length, 2);
  } finally {
    await workspace.close();
    store.close();
  }
});

test("simultaneous submissions admit one run per conversation", async () => {
  const store = new Store(":memory:");
  const { workspace, post } = setup(store);
  try {
    const conversation = await (await post("/api/conversations", {})).json();
    const responses = await Promise.all(
      [1, 2].map((number) =>
        post(`/api/conversations/${conversation.id}/messages`, {
          text: `Question ${number}`,
          deviceId: "desktop",
          tabId: "tab-a",
        }),
      ),
    );
    assert.deepEqual(
      responses.map((response) => response.status).sort(),
      [202, 409],
    );
    assert.equal(store.snapshot(conversation.id)!.runs.length, 1);
  } finally {
    await workspace.close();
    store.close();
  }
});

test("cancellation before and during prompt admission cannot queue work after the interrupt", async () => {
  for (const stage of ["inspection", "admission"]) {
    const store = new Store(":memory:");
    const { workspace, post } = setup(store);
    const calls: string[] = [];
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    workspace.setHarness({
      async deleteSession() {},
      async createSession() {
        return "session-1";
      },
      async inspect() {
        if (stage === "inspection") await gate;
        return { messages: [], status: "running" };
      },
      async prompt() {
        calls.push("admitting");
        await gate;
        calls.push("admitted");
      },
      async interrupt() {
        calls.push("interrupted");
      },
    });
    try {
      const conversation = await (await post("/api/conversations", {})).json();
      const run = await (
        await post(`/api/conversations/${conversation.id}/messages`, {
          text: "Question",
          deviceId: "desktop",
          tabId: "tab-a",
        })
      ).json();
      if (stage === "admission") await until(() => calls.includes("admitting"));
      const cancel = post(`/api/runs/${run.id}/cancel`, {});
      await delay(10);
      if (stage === "admission") {
        assert.equal(
          (
            await post(`/api/conversations/${conversation.id}/messages`, {
              text: "Too early",
              deviceId: "desktop",
              tabId: "tab-a",
            })
          ).status,
          409,
        );
        assert.deepEqual(calls, ["admitting"]);
      }
      release();
      assert.equal((await cancel).status, 200);
      await workspace.close();
      assert.equal(store.run(run.id)!.status, "cancelled");
      assert.deepEqual(
        calls,
        stage === "inspection"
          ? ["interrupted"]
          : ["admitting", "admitted", "interrupted"],
      );
    } finally {
      release();
      await workspace.close();
      store.close();
    }
  }
});

test("source-less app context persists and scopes whole-resource navigation to its originating view", async () => {
  const store = new Store(":memory:");
  const { workspace, post } = setup(store);
  let captured: unknown[] | undefined;
  let running = false;
  workspace.setHarness({
    async deleteSession() {},
    async createSession() {
      return "session-1";
    },
    async prompt(...args) {
      captured = args;
      running = true;
    },
    async inspect() {
      return { messages: [], status: running ? "running" : "idle" };
    },
    async interrupt() {
      running = false;
    },
  });
  try {
    const report = roomReport();
    report.sections = [
      {
        id: "content",
        title: "Whole resource",
        text: "Saved resource content.",
      },
    ];
    store.saveReport(report);
    const conversation = await (await post("/api/conversations", {})).json();
    const appContext = {
      appId: "rooms",
      viewToken: "app-home-token",
      viewState: {
        query: "inventory",
        filters: { year: "2026" },
        language: "zh",
      },
    };
    const response = await post(
      `/api/conversations/${conversation.id}/messages`,
      {
        text: "Find this resource",
        deviceId: "phone",
        tabId: "native-tab",
        appContext,
      },
    );
    assert.equal(response.status, 202);
    const run = await response.json();
    await until(() => captured !== undefined);
    assert.equal(captured![2], undefined);
    assert.deepEqual(captured![3], appContext);
    assert.deepEqual(
      store.snapshot(conversation.id)!.messages[0].appContext,
      appContext,
    );
    assert.deepEqual(store.run(run.id)!.appContext, appContext);
    const navigation = workspace.toolHandler("session-1", "app_navigate", {
      ...report.source,
      viewState: appContext.viewState,
    });
    await until(() => store.snapshot(conversation.id)!.commands.length === 1);
    const command = store.snapshot(conversation.id)!.commands[0];
    assert.equal(command.kind, "navigate");
    assert.equal(command.sectionId, "content");
    assert.equal(command.expectedViewToken, "app-home-token");
    assert.deepEqual(command.viewState, appContext.viewState);
    assert.equal(command.deviceId, "phone");
    assert.equal(command.tabId, "native-tab");
    assert.equal(
      (
        await post(`/api/commands/${command.id}/ack`, {
          deviceId: "phone",
          tabId: "other-tab",
          status: "applied",
        })
      ).status,
      403,
    );
    await post(`/api/commands/${command.id}/ack`, {
      deviceId: "phone",
      tabId: "native-tab",
      status: "stale",
    });
    assert.equal(((await navigation) as { status: string }).status, "stale");
  } finally {
    await workspace.close();
    store.close();
  }
});

test("navigation validates published highlight targets and preserves pending results until a late acknowledgement", async () => {
  const store = new Store(":memory:");
  const { workspace, post, complete } = setup(store);
  try {
    const conversation = await (await post("/api/conversations", {})).json();
    const report = roomReport();
    const run = await (await post(`/api/conversations/${conversation.id}/messages`, {
      text: "Show evidence", deviceId: "desktop", tabId: "tab-a",
    })).json();
    const invalid = await workspace.toolHandler("session-1", "app_navigate", {
      ...report.source, sectionId: "furniture", highlightIds: ["invented-field"],
    });
    assert.match((invalid as { error: string }).error, /highlight does not exist/);
    assert.equal(store.snapshot(conversation.id)!.commands.length, 0);
    const navigation = await workspace.toolHandler("session-1", "app_navigate", {
      ...report.source, sectionId: "furniture", highlightIds: ["desk"],
    }) as { id: string; status: string };
    assert.equal(navigation.status, "pending");
    complete();
    await until(() => store.run(run.id)!.status === "completed");
    assert.equal(store.command(navigation.id)!.status, "pending");
    await post(`/api/commands/${navigation.id}/ack`, {
      deviceId: "desktop", tabId: "tab-a", status: "applied", viewToken: "late-view-token",
    });
    assert.equal(store.command(navigation.id)!.status, "applied");
    assert.equal(store.run(run.id)!.navigationViewToken, "late-view-token");
    assert.equal(store.run(run.id)!.status, "completed");
    await post(`/api/commands/${navigation.id}/ack`, {
      deviceId: "desktop", tabId: "tab-a", status: "stale",
    });
    assert.equal(store.command(navigation.id)!.status, "applied");
    assert.equal(store.snapshot(conversation.id)!.tools.length, 2);
  } finally {
    await workspace.close();
    store.close();
  }
});

test("in-flight app reads expose a single running operation and interrupted recovery settles it", async () => {
  const store = new Store(":memory:");
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const report = roomReport();
  const workspace = createWorkspace(store, [{
    id: "rooms", name: "Rooms", description: "Fixture", resourceId: fixtureResourceId,
    integration: { search: async () => [], read: async () => { await gate; return report; } },
  }], { mode: "fixture", model: "fixture", configured: true });
  const conversation = store.createConversation("Read", "session-1");
  const run = store.startRun(conversation.id, "Read", "phone", "tab-b");
  const reading = workspace.toolHandler("session-1", "app_read", {
    appId: "rooms", resourceId: fixtureResourceId,
  });
  try {
    const config = await (await workspace.app.request("/api/config")).json();
    assert.equal(config.apps[0].resourceId, fixtureResourceId);
    assert.equal(store.snapshot(conversation.id)!.tools[0].status, "running");
    store.recover();
    assert.equal(store.run(run.id)!.status, "interrupted");
    const recovered = store.snapshot(conversation.id)!.tools[0];
    assert.equal(recovered.status, "completed");
    assert.match((recovered.output as { error: string }).error, /Relay stopped/);
    release();
    await reading;
    const records = store.snapshot(conversation.id)!.tools;
    assert.equal(records.length, 1);
    assert.deepEqual(records[0], recovered, "Late completion cannot replace an interrupted result");
  } finally {
    release();
    await reading;
    await workspace.close();
    store.close();
  }
});

test("confirmed navigation advances the next command token without replacing question context", async () => {
  for (const originalToken of ["question-view", undefined]) {
    const store = new Store(":memory:");
    const { workspace, post } = setup(store);
    try {
      const conversation = await (await post("/api/conversations", {})).json();
      const report = roomReport();
      store.saveReport(report);
      const context = originalToken ? { source: report.source, viewToken: originalToken, sectionId: "furniture" } : undefined;
      const run = await (await post(`/api/conversations/${conversation.id}/messages`, {
        text: "Show selected evidence", deviceId: "desktop", tabId: "tab-a", context,
      })).json();
      const navigate = () => workspace.toolHandler("session-1", "app_navigate", {
        ...report.source, sectionId: "furniture", highlightIds: ["desk"],
      });
      const firstNavigation = navigate();
      await until(() => store.snapshot(conversation.id)!.commands.length === 1);
      const first = store.snapshot(conversation.id)!.commands[0];
      assert.equal(first.expectedViewToken, originalToken ?? null);
      assert.equal((await post(`/api/commands/${first.id}/ack`, {
        deviceId: "phone", tabId: "tab-a", status: "applied", viewToken: "wrong-device",
      })).status, 403);
      assert.equal((await post(`/api/commands/${first.id}/ack`, {
        deviceId: "desktop", tabId: "tab-a", status: "applied", viewToken: 7,
      })).status, 400);
      await post(`/api/commands/${first.id}/ack`, {
        deviceId: "desktop", tabId: "tab-a", status: "applied", viewToken: "after-first",
      });
      assert.equal((await firstNavigation as { status: string }).status, "applied");
      const secondNavigation = navigate();
      await until(() => store.snapshot(conversation.id)!.commands.length === 2);
      const second = store.snapshot(conversation.id)!.commands[1];
      assert.equal(second.expectedViewToken, "after-first");
      await post(`/api/commands/${second.id}/ack`, {
        deviceId: "desktop", tabId: "tab-a", status: "applied", viewToken: "after-second",
      });
      assert.equal((await secondNavigation as { status: string }).status, "applied");
      await post(`/api/commands/${first.id}/ack`, {
        deviceId: "desktop", tabId: "tab-a", status: "applied", viewToken: "duplicate-old-token",
      });
      assert.equal(store.run(run.id)!.navigationViewToken, "after-second");
      const staleRunCopy = { ...store.run(run.id)!, navigationViewToken: undefined };
      const third = store.createCommand(staleRunCopy, report.source, "furniture");
      assert.equal(third.expectedViewToken, "after-second", "Command creation reads the latest saved token");
      await post(`/api/commands/${third.id}/ack`, {
        deviceId: "desktop", tabId: "tab-a", status: "stale", viewToken: "manual-view",
      });
      assert.equal(store.run(run.id)!.navigationViewToken, "after-second");
      assert.deepEqual(store.run(run.id)!.context, context);
      assert.deepEqual(store.snapshot(conversation.id)!.messages[0].context, context);
    } finally {
      await workspace.close();
      store.close();
    }
  }
});

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { setTimeout as delay } from "node:timers/promises";
import { ProviderSettingsStore } from "../server/provider-settings.ts";
import { Store } from "../server/store.ts";
import { createWorkspace } from "../server/app.ts";
import type { ProviderUpdate } from "../shared/types.ts";

test("thinking effort retains provider defaults, validates model support, and survives reload without replacing the key", async () => {
  const dir = await mkdtemp(join(tmpdir(), "relay-provider-effort-"));
  try {
    let settings = new ProviderSettingsStore(dir, { DEEPSEEK_API_KEY: "synthetic-key" });
    assert.equal(settings.status().reasoningEffort, undefined);
    for (const reasoningEffort of ["none", "low", "high", "max", "default"] as const) {
      settings.save(settings.prepare({ mode: "deepseek", model: "deepseek-flash", reasoningEffort }));
      settings = new ProviderSettingsStore(dir, { DEEPSEEK_API_KEY: "synthetic-key" });
      assert.equal(settings.status().reasoningEffort, reasoningEffort);
      assert.equal(settings.configuration().reasoningEffort, reasoningEffort);
      assert.equal(settings.configuration().apiKey, "synthetic-key");
      const unchanged = settings.prepare({ mode: "deepseek", model: "deepseek-v4-pro" });
      assert.equal(unchanged.reasoningEffort, reasoningEffort);
    }
    for (const reasoningEffort of ["medium", "xhigh", "ultra", 1, null]) {
      assert.throws(() => settings.prepare({ mode: "deepseek", model: "deepseek-flash", reasoningEffort } as ProviderUpdate), /supported thinking effort/);
    }
    assert.throws(() => settings.prepare({ mode: "deepseek", model: "unverified-model", reasoningEffort: "max" }), /supported for/);
    settings.save(settings.prepare({ mode: "deepseek", model: "deepseek-flash", reasoningEffort: "max" }));
    assert.equal(settings.prepare({ mode: "deepseek", model: "unverified-model" }).reasoningEffort, undefined);
    assert.equal(settings.prepare({ mode: "fixture", model: "deepseek-flash" }).reasoningEffort, "max");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("provider settings persist privately, override environment defaults, and retain or replace saved keys", async () => {
  const dir = await mkdtemp(join(tmpdir(), "relay-provider-"));
  try {
    let settings = new ProviderSettingsStore(dir, {
      RELAY_PROVIDER: "fixture",
      DEEPSEEK_MODEL: "initial-model",
    });
    assert.deepEqual(settings.status(), {
      mode: "fixture",
      model: "initial-model",
      hasKey: false,
    });
    assert.throws(
      () => settings.prepare({ mode: "deepseek", model: "deepseek-flash" }),
      /Enter a DeepSeek API key/,
    );
    settings.save(
      settings.prepare({
        mode: "deepseek",
        model: " selected-model ",
        apiKey: " synthetic-first-key ",
      }),
    );
    assert.equal((await stat(join(dir, "provider.json"))).mode & 0o777, 0o600);
    settings = new ProviderSettingsStore(dir, {
      RELAY_PROVIDER: "fixture",
      DEEPSEEK_MODEL: "ignored-env-model",
    });
    assert.deepEqual(settings.status(), {
      mode: "deepseek",
      model: "selected-model",
      hasKey: true,
    });
    settings.save(
      settings.prepare({ mode: "deepseek", model: "new-model", apiKey: "  " }),
    );
    assert.equal(settings.configuration().apiKey, "synthetic-first-key");
    settings.save(
      settings.prepare({
        mode: "deepseek",
        model: "new-model",
        apiKey: "synthetic-replacement-key",
      }),
    );
    settings = new ProviderSettingsStore(dir, {});
    assert.equal(settings.configuration().apiKey, "synthetic-replacement-key");
    assert.deepEqual(settings.status(), {
      mode: "deepseek",
      model: "new-model",
      hasKey: true,
    });
    assert.ok(!JSON.stringify(settings.status()).includes("synthetic-"));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("blank-key saves reuse an external key file without copying its key into provider settings", async () => {
  const dir = await mkdtemp(join(tmpdir(), "relay-provider-file-"));
  try {
    const external = join(dir, "synthetic-external-key.txt");
    await writeFile(external, "synthetic-external-key\n", { mode: 0o600 });
    const env = { RELAY_PROVIDER: "fixture", DEEPSEEK_API_KEY_FILE: external };
    const fixtureOnly = new ProviderSettingsStore(join(dir, "fixture-only"), {
      RELAY_PROVIDER: "fixture",
      DEEPSEEK_API_KEY_FILE: join(dir, "missing-key-file"),
    });
    assert.equal(fixtureOnly.configuration().mode, "fixture");
    assert.equal(
      fixtureOnly.configuration().apiKey,
      undefined,
      "Fixture startup does not read or receive a configured external key file",
    );
    let settings = new ProviderSettingsStore(dir, env);
    const next = settings.prepare({
      mode: "deepseek",
      model: "deepseek-flash",
      apiKey: "",
    });
    assert.equal(settings.configuration(next).apiKey, "synthetic-external-key");
    settings.save(next);
    assert.deepEqual(
      JSON.parse(await readFile(join(dir, "provider.json"), "utf8")),
      { mode: "deepseek", connections: {deepseek: {model: "deepseek-flash"}} },
    );
    assert.equal(await readFile(external, "utf8"), "synthetic-external-key\n");
    settings = new ProviderSettingsStore(dir, env);
    assert.equal(settings.configuration().apiKey, "synthetic-external-key");
    assert.equal(settings.status().hasKey, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("provider HTTP settings redact keys and enforce origin, active-work and apply gates, releasing the gate on failure", async () => {
  const dir = await mkdtemp(join(tmpdir(), "relay-provider-api-"));
  const store = new Store(":memory:");
  const settings = new ProviderSettingsStore(dir, {});
  let updateStarted = false;
  let applyGate: Promise<void> | undefined;
  let failApply: (error: Error) => void = () => {};
  let running = false;
  const workspace = createWorkspace(
    store,
    [],
    { mode: "fixture", model: "fixture", configured: true },
    {
      get: (mode) => settings.status(mode),
      models: async () => [],
      update: async (input) => {
        const next = settings.prepare(input);
        updateStarted = true;
        if (applyGate) await applyGate;
        settings.save(next);
        return settings.status();
      },
    },
  );
  workspace.setHarness({
    async deleteSession() {},
    async createSession() {
      return "synthetic-session";
    },
    async prompt() {
      running = true;
    },
    async inspect() {
      return { messages: [], status: running ? "running" : "idle" };
    },
    async interrupt() {
      running = false;
    },
  });
  const post = (path: string, body: unknown, origin = "http://localhost") =>
    workspace.app.request(path, {
      method: "POST",
      headers: { "Content-Type": "application/json", Origin: origin },
      body: JSON.stringify(body),
    });
  const change: ProviderUpdate = {
    mode: "deepseek",
    model: "model-a",
    apiKey: "synthetic-http-key-a",
  };
  try {
    for (const reasoningEffort of ["medium", "xhigh"]) {
      const response = await post("/api/settings/provider", { ...change, reasoningEffort });
      assert.equal(response.status, 400);
    }
    assert.equal(
      (
        await post("/api/settings/provider", {
          mode: "deepseek",
          model: "model-a",
        })
      ).status,
      400,
    );
    assert.equal(
      (await post("/api/settings/provider", change, "https://unrelated.test"))
        .status,
      403,
    );
    assert.equal(updateStarted, false);
    for (const apiKey of ["synthetic-http-key-a", "synthetic-http-key-b"]) {
      const response = await post("/api/settings/provider", {
        ...change,
        apiKey,
      });
      assert.equal(response.status, 200);
      assert.deepEqual(await response.json(), {
        mode: "deepseek",
        model: "model-a",
        hasKey: true,
      });
      for (const path of ["/api/settings/provider", "/api/config"]) {
        const publicText = await (await workspace.app.request(path)).text();
        assert.ok(!publicText.includes(apiKey));
        assert.ok(!publicText.includes("apiKey"));
      }
    }
    assert.equal(settings.configuration().apiKey, "synthetic-http-key-b");
    for (const reasoningEffort of ["none", "low", "high", "max", "default"]) {
      const response = await post("/api/settings/provider", { mode: "deepseek", model: "deepseek-flash", reasoningEffort });
      assert.equal(response.status, 200);
      assert.equal((await response.json()).reasoningEffort, reasoningEffort);
      assert.equal((await (await workspace.app.request("/api/settings/provider")).json()).reasoningEffort, reasoningEffort);
      assert.equal(settings.configuration().apiKey, "synthetic-http-key-b");
    }
    // Restore the initial selection before exercising restart failure recovery.
    await post("/api/settings/provider", change);
    const conversation = await (await post("/api/conversations", {})).json();
    updateStarted = false;
    applyGate = new Promise<void>((_resolve, reject) => {
      failApply = reject;
    });
    const applying = post("/api/settings/provider", {
      mode: "deepseek",
      model: "would-fail",
    });
    for (let attempt = 0; !updateStarted && attempt < 100; attempt++)
      await delay(10);
    assert.equal(updateStarted, true);
    const message = { text: "A question", deviceId: "desktop", tabId: "tab" };
    assert.equal(
      (await post(`/api/conversations/${conversation.id}/messages`, message))
        .status,
      409,
    );
    assert.equal((await post("/api/conversations", {})).status, 409);
    assert.equal((await post("/api/settings/provider", change)).status, 409);
    failApply(new Error("Synthetic restart failed"));
    assert.equal((await applying).status, 502);
    assert.deepEqual(settings.status(), {
      mode: "deepseek",
      model: "model-a",
      hasKey: true,
    });
    applyGate = undefined;
    assert.equal(
      (
        await post("/api/settings/provider", {
          mode: "fixture",
          model: "deepseek-flash",
        })
      ).status,
      200,
    );
    assert.equal(
      (await post(`/api/conversations/${conversation.id}/messages`, message))
        .status,
      202,
    );
    assert.equal((await post("/api/settings/provider", change)).status, 409);
  } finally {
    await workspace.close();
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
});


test("Claude and DeepSeek preserve separate keys/models across switching and legacy migration", async () => {
  const dir = await mkdtemp(join(tmpdir(), "relay-provider-switch-"));
  try {
    await writeFile(join(dir, "provider.json"), JSON.stringify({mode:"deepseek", model:"deepseek-flash", apiKey:"synthetic-deepseek", reasoningEffort:"high"}));
    let settings = new ProviderSettingsStore(dir, {});
    assert.equal(settings.status("anthropic").hasKey, false);
    assert.throws(() => settings.prepare({mode:"anthropic", model:"claude-sonnet-5-5"}), /Claude API key/);
    settings.save(settings.prepare({mode:"anthropic", model:"claude-sonnet-5-5", apiKey:"synthetic-claude"}));
    assert.equal(settings.configuration().apiKey, "synthetic-claude");
    assert.equal(settings.status().reasoningEffort, undefined);
    settings = new ProviderSettingsStore(dir, {});
    settings.save(settings.prepare({mode:"deepseek", model:settings.status("deepseek").model}));
    assert.equal(settings.configuration().apiKey, "synthetic-deepseek");
    assert.equal(settings.status().reasoningEffort, "high");
    settings.save(settings.prepare({mode:"fixture", model:"deepseek-flash"}));
    assert.equal(settings.configuration().apiKey, undefined);
    settings.save(settings.prepare({mode:"anthropic", model:"claude-sonnet-5-5", apiKey:""}));
    assert.equal(settings.configuration().apiKey, "synthetic-claude");
    assert.ok(!JSON.stringify(settings.status()).includes("synthetic-"));
    assert.equal((await stat(join(dir,"provider.json"))).mode & 0o777, 0o600);
    assert.throws(() => settings.prepare({mode:"anthropic", model:"claude-sonnet-5-5", reasoningEffort:"high"}), /supported for/);
    assert.throws(() => settings.prepare({mode:"anthropic", model:"deepseek-flash", reasoningEffort:"high"}), /supported for/,
      "A model name alone cannot enable another provider's options");
  } finally { await rm(dir, {recursive:true, force:true}); }
});

test("Claude reads only its own external key and does not copy it into settings", async () => {
  const dir=await mkdtemp(join(tmpdir(), "relay-claude-env-"));
  try {
    const keyFile=join(dir,"claude-key");
    await writeFile(keyFile,"synthetic-claude-file");
    const settings=new ProviderSettingsStore(dir,{ANTHROPIC_API_KEY_FILE:keyFile,DEEPSEEK_API_KEY:"synthetic-deepseek-env"});
    settings.save(settings.prepare({mode:"anthropic",model:"claude-sonnet-5-5"}));
    assert.equal(settings.configuration().apiKey,"synthetic-claude-file");
    assert.ok(!(await readFile(join(dir,"provider.json"),"utf8")).includes("synthetic-"));
  } finally { await rm(dir,{recursive:true,force:true}); }
});

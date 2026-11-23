import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { listProviderModels } from "../server/provider-models.ts";
import { liveProviders, pickListedModel } from "../shared/provider.ts";
import { ProviderNetworkError } from "../server/provider-network.ts";
import { ProviderSettingsStore } from "../server/provider-settings.ts";
import { Store } from "../server/store.ts";
import { createWorkspace } from "../server/app.ts";

test("model discovery uses provider authentication, labels and pagination with a VPN check per page", async () => {
  for (const mode of ["deepseek", "anthropic", "openai"] as const) {
    let checks = 0, requests = 0, connected = true;
    const original = liveProviders[mode].baseURL;
    const server = createServer((req, res) => {
      requests++;
      assert.equal(req.headers[liveProviders[mode].auth.header], liveProviders[mode].auth.prefix + "synthetic-key");
      const url = new URL(req.url!, "http://localhost");
      assert.equal(url.pathname, "/v1/models");
      assert.equal(req.method, "GET");
      if (mode === "anthropic") assert.equal(req.headers["anthropic-version"], "2023-06-01");
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify(url.searchParams.has("after_id")
        ? {data: [{id:"model-b", display_name:"Model B"}, {id:"model-a", display_name:"Model A"}, {id:"retired", lifecycle:"retired"}], has_more:false}
        : {data: [{id:"model-a", display_name:"Model A"}], has_more:mode === "anthropic", last_id:"model-a"}));
    });
    await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
    liveProviders[mode].baseURL = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1`;
    const guard = async () => { checks++; if (!connected) throw new ProviderNetworkError("NordVPN is not connected. No API request was sent."); };
    try {
      assert.deepEqual(await listProviderModels({mode, model:"unused", apiKey:"synthetic-key"}, undefined, guard),
        mode === "anthropic" ? [{id:"model-a",name:"Model A"},{id:"model-b",name:"Model B"}] : [{id:"model-a",name:"Model A"}]);
      assert.equal(checks, mode === "anthropic" ? 2 : 1);
      assert.equal(requests, checks);
      connected = false;
      const before = requests;
      await assert.rejects(listProviderModels({mode,model:"unused",apiKey:"synthetic-key"}, undefined, guard), /NordVPN is not connected/);
      assert.equal(requests, before);
    } finally {
      liveProviders[mode].baseURL = original;
      server.closeAllConnections();
      await new Promise<void>(resolve => server.close(() => resolve()));
    }
  }
});

test("model discovery sanitizes upstream failures and stops pagination if the VPN disconnects", async () => {
  let status = 401, requests = 0, checks = 0;
  const original = liveProviders.anthropic.baseURL;
  const server = createServer((_req, res) => {
    requests++;
    res.writeHead(status, {"Content-Type":"application/json"}).end(status === 200
      ? JSON.stringify({data:[{id:"model-a"}],has_more:true,last_id:"model-a"})
      : JSON.stringify({error:"upstream echoed synthetic-secret"}));
  });
  await new Promise<void>(resolve => server.listen(0,"127.0.0.1",resolve));
  liveProviders.anthropic.baseURL = `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1`;
  const connection = {mode:"anthropic" as const,model:"unused",apiKey:"synthetic-secret"};
  try {
    await assert.rejects(listProviderModels(connection,undefined,async()=>{}), error => {
      assert.match((error as Error).message,/did not accept this key/);
      assert.ok(!(error as Error).message.includes("synthetic-secret"));
      return true;
    });
    status = 200; requests = 0;
    await assert.rejects(listProviderModels(connection,undefined,async()=>{
      if (++checks === 2) throw new ProviderNetworkError("NordVPN disconnected");
    }),/NordVPN disconnected/);
    assert.equal(requests,1);
    await assert.rejects(listProviderModels(connection,undefined,async()=>{}),/Could not load Claude models/);
  } finally {
    liveProviders.anthropic.baseURL = original;
    server.closeAllConnections();
    await new Promise<void>(resolve=>server.close(()=>resolve()));
  }
});

test("model lookup accepts draft keys without saving or switching and enforces provider isolation and HTTP origin", async () => {
  const dir = await mkdtemp(join(tmpdir(),"relay-model-discovery-"));
  const store = new Store(":memory:");
  const settings = new ProviderSettingsStore(dir, {});
  settings.save(settings.prepare({mode:"deepseek",model:"saved-model",apiKey:"synthetic-saved-key"}));
  const before = await readFile(join(dir,"provider.json"),"utf8");
  const selected = settings.status();
  let calls = 0;
  const workspace = createWorkspace(store, () => [], {mode:"deepseek",model:"saved-model",configured:true}, {
    get:mode=>settings.status(mode),
    update:async()=>{throw new Error("Discovery must not update settings");},
    models:async input=>{
      const connection = settings.configuration(settings.prepare({...input,model:settings.status(input.mode).model}));
      calls++;
      assert.equal(connection.apiKey, input.apiKey || "synthetic-saved-key");
      return [{id:"offered-model",name:"Offered model"}];
    },
  });
  const post = (body:unknown, origin="http://localhost")=>workspace.app.request("/api/settings/provider/models",{
    method:"POST",headers:{"Content-Type":"application/json",Origin:origin},body:JSON.stringify(body),
  });
  try {
    for (const body of [{mode:"deepseek"},{mode:"anthropic",apiKey:"synthetic-draft-key"}]) {
      const response = await post(body);
      assert.equal(response.status,200);
      assert.equal(response.headers.get("cache-control"),"no-store");
      assert.deepEqual(await response.json(),{models:[{id:"offered-model",name:"Offered model",supportsReasoningEffort:false}]});
    }
    assert.equal((await post({mode:"anthropic"})).status,400);
    assert.equal((await post({mode:"deepseek"},"https://unrelated.test")).status,403);
    assert.equal((await post({mode:"unsupported"})).status,400);
    assert.equal((await post({mode:"deepseek",apiKey:123})).status,400);
    assert.equal(calls,2);
    assert.deepEqual(settings.status(),selected);
    assert.equal(await readFile(join(dir,"provider.json"),"utf8"),before);
  } finally {
    await workspace.close(); store.close(); await rm(dir,{recursive:true,force:true});
  }
});

test("a loaded model list keeps the current model, then the default, and never picks a non-chat first entry", () => {
  const openai = ["text-embedding-3-large", "tts-1", "whisper-1", "dall-e-3", "omni-moderation-latest", "gpt-6.1-terra", "gpt-6.2-sol"]
    .map(id => ({id}));
  assert.equal(pickListedModel("openai", "", openai), "gpt-6.2-sol", "First setup starts with no model and gets the default");
  assert.equal(pickListedModel("openai", "gpt-6.1-terra", openai), "gpt-6.1-terra");
  assert.equal(pickListedModel("openai", "", openai.filter(model => model.id !== "gpt-6.2-sol")), "",
    "Without the default the user must choose");
});

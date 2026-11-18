import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdir, mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { resolve, join } from "node:path";
import type { AddressInfo } from "node:net";
import { liveProviders } from "../shared/provider.ts";
import { startProviderGateway } from "../server/provider-gateway.ts";
import { Harness } from "../server/harness.ts";

test("Claude's native Messages adapter completes a Relay tool round trip without DeepSeek options", {timeout:30_000}, async () => {
  await mkdir(resolve("tmp"),{recursive:true});
  const dir=await mkdtemp(resolve("tmp/claude-wire-"));
  const requests: any[]=[];
  const calls: string[]=[];
  const server=createServer(async (req,res) => {
    let raw="";
    for await (const chunk of req) raw+=chunk;
    const body=JSON.parse(raw);
    requests.push({path:req.url,key:req.headers["x-api-key"],body});
    const tool=body.tools.find((item: any)=>item.name.endsWith("app_discover"));
    const first=!body.messages.some((message: any)=>Array.isArray(message.content) && message.content.some((item: any)=>item.type==="tool_result"));
    res.writeHead(200,{"Content-Type":"text/event-stream"});
    const event=(type:string,value:object) => res.write(`event: ${type}\ndata: ${JSON.stringify({type,...value})}\n\n`);
    event("message_start",{message:{id:`msg_${requests.length}`,type:"message",role:"assistant",model:body.model,content:[],stop_reason:null,stop_sequence:null,usage:{input_tokens:20,output_tokens:0}}});
    event("content_block_start",{index:0,content_block:first?{type:"tool_use",id:"tool_discover",name:tool.name,input:{}}:{type:"text",text:""}});
    event("content_block_delta",{index:0,delta:first?{type:"input_json_delta",partial_json:'{"appId":"research"}'}:{type:"text_delta",text:"Claude tool round trip completed."}});
    event("content_block_stop",{index:0});
    event("message_delta",{delta:{stop_reason:first?"tool_use":"end_turn",stop_sequence:null},usage:{output_tokens:12}});
    event("message_stop",{});
    res.end();
  });
  await new Promise<void>(resolve=>server.listen(0,"127.0.0.1",resolve));
  let harness: Harness | undefined;
  let gateway: Awaited<ReturnType<typeof startProviderGateway>> | undefined;
  const previousPath = process.env.PATH;
  const statusFile = join(dir, "vpn-status");
  const checksFile = join(dir, "vpn-checks");
  await writeFile(statusFile, "Status: Connected\n");
  await writeFile(join(dir, "nordvpn"), `#!/bin/sh\nprintf 'checked\\n' >> '${checksFile}'\n/bin/cat '${statusFile}'\n`, {mode:0o700});
  process.env.PATH = dir + ":" + previousPath;
  try {
    harness=await Harness.start({dataDir:dir,mode:"fixture",model:"deepseek-flash",
      toolHandler:async ()=>assert.fail("Normal fixture chat must not call tools")});
    const session=await harness.createSession("Existing conversation");
    await harness.prompt(session,"Hello from the previous provider.");
    for(let n=0;(await harness.inspect(session)).status==="running" && n<150;n++)
      await new Promise(resolve=>setTimeout(resolve,50));
    assert.equal((await harness.inspect(session)).status,"idle");
    await harness.close();
    gateway = await startProviderGateway({
      ...liveProviders.anthropic, baseURL: `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1`,
    }, "synthetic-claude-key");
    harness=await Harness.start({dataDir:dir,mode:"anthropic",model:"claude-sonnet-5-5", gateway: {url:gateway.url, token:gateway.token},
      toolHandler:async (_session,name)=>{calls.push(name);return {instructions:"Synthetic Research",operations:[]};}});
    const path=join(dir,"opencode/config/opencode.json");
    const config=JSON.parse(await readFile(path,"utf8"));
    assert.equal(config.providers.anthropic.package,"@opencode/ai/providers/anthropic");
    assert.deepEqual(config.providers.anthropic.env,["ANTHROPIC_API_KEY"]);
    assert.ok(!JSON.stringify(config).includes("synthetic-claude-key"));
    assert.match(config.providers.anthropic.settings.baseURL, /^http:\/\/127\.0\.0\.1:/);
    const png = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nO3NMQ0AAAgDsPn/cILEqeAgadK/meypCAQCgUAgEAgEgi9BAZhHBEy8PGiYAAAAAElFTkSuQmCC";
    await harness.prompt(session,"Discover Research then answer.",undefined,undefined,"max",png);
    let state=await harness.inspect(session);
    for(let n=0;state.status==="running" && n<150;n++) {
      await new Promise(resolve=>setTimeout(resolve,50));
      state=await harness.inspect(session);
    }
    assert.equal(state.status,"idle",state.error);
    assert.deepEqual(calls,["app_discover"]);
    assert.ok(JSON.stringify(requests[0].body.messages).includes("Hello from the previous provider."));
    assert.equal(requests.length,2);
    for(const request of requests) {
      assert.equal(new URL(request.path,"http://fixture").pathname,"/v1/messages");
      assert.equal(request.key,"synthetic-claude-key");
      assert.equal(request.body.model,"claude-sonnet-5-5");
      assert.equal(request.body.reasoning_effort,undefined);
    }
    assert.ok(JSON.stringify(state.messages).includes("Claude tool round trip completed."));
    assert.equal((await readFile(checksFile, "utf8")).trim().split("\n").length, 2,
      "Every model call, including the tool continuation, passed the gateway");
    assert.ok(requests[0].body.messages.some((message: any) => Array.isArray(message.content) &&
      message.content.some((part: any) => part.type === "image" && part.source.media_type === "image/png" && part.source.data === png)));
    await writeFile(statusFile, "Status: Disconnected\n");
    await harness.prompt(session, "One more question.");
    for(let n=0;n<150;n++) {
      state = await harness.inspect(session);
      if (state.status !== "running") break;
      await new Promise(resolve=>setTimeout(resolve,50));
    }
    assert.equal(state.status, "error");
    assert.match(state.error || "", /NordVPN is not connected/);
    assert.equal(requests.length, 2, "No upstream call is sent after disconnect");
  } finally {
    await harness?.close();
    process.env.PATH = previousPath;
    await gateway?.close();
    server.closeAllConnections();
    await new Promise<void>(resolve=>server.close(()=>resolve()));
    await rm(dir,{recursive:true,force:true});
  }
});

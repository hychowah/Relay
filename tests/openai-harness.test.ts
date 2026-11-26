import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdir, mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { resolve, join } from "node:path";
import type { AddressInfo } from "node:net";
import { liveProviders } from "../shared/provider.ts";
import { startProviderGateway } from "../server/provider-gateway.ts";
import { Harness } from "../server/harness.ts";

test("OpenAI's native Responses adapter receives a Relay tool image through the gateway", {timeout:30_000}, async () => {
  await mkdir(resolve("tmp"),{recursive:true});
  const dir=await mkdtemp(resolve("tmp/openai-wire-"));
  const png = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nO3NMQ0AAAgDsPn/cILEqeAgadK/meypCAQCgUAgEAgEgi9BAZhHBEy8PGiYAAAAAElFTkSuQmCC";
  const requests: any[]=[];
  const calls: string[]=[];
  const server=createServer(async (req,res) => {
    let raw="";
    for await (const chunk of req) raw+=chunk;
    const body=JSON.parse(raw);
    requests.push({path:req.url,key:req.headers.authorization,body});
    const n=requests.length;
    const tool=body.tools.find((item: any)=>item.name.endsWith("app_call"));
    const first=!body.input.some((item: any)=>item.type==="function_call_output");
    const args='{"appId":"research","operation":"sample.frame","arguments":{}}';
    const text="OpenAI tool round trip completed.";
    const item=first
      ? {type:"function_call",id:`fc_${n}`,call_id:`call_${n}`,name:tool.name,arguments:args,status:"completed"}
      : {type:"message",id:`msg_${n}`,role:"assistant",status:"completed",content:[{type:"output_text",text,annotations:[]}]};
    res.writeHead(200,{"Content-Type":"text/event-stream"});
    const event=(type:string,value:object) => res.write(`event: ${type}\ndata: ${JSON.stringify({type,...value})}\n\n`);
    event("response.created",{response:{id:`resp_${n}`,object:"response",status:"in_progress",model:body.model,output:[]}});
    event("response.output_item.added",{output_index:0,item:first?{...item,arguments:"",status:"in_progress"}:{...item,status:"in_progress",content:[]}});
    if (first) event("response.function_call_arguments.delta",{item_id:item.id,output_index:0,delta:args});
    else event("response.output_text.delta",{item_id:item.id,output_index:0,content_index:0,delta:text});
    event("response.output_item.done",{output_index:0,item});
    event("response.completed",{response:{id:`resp_${n}`,object:"response",status:"completed",model:body.model,output:[item],
      usage:{input_tokens:20,output_tokens:12,total_tokens:32}}});
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
      ...liveProviders.openai, baseURL: `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1`,
    }, "synthetic-openai-key");
    harness=await Harness.start({dataDir:dir,mode:"openai",model:"gpt-6.2-sol", gateway: {url:gateway.url, token:gateway.token},
      toolHandler:async (_session,name)=>{calls.push(name);return {data:{label:"Synthetic frame"},image:{mimeType:"image/png",base64:png}};}});
    const config=JSON.parse(await readFile(join(dir,"opencode/config/opencode.json"),"utf8"));
    assert.equal(config.providers.openai.package,"@opencode/ai/providers/openai");
    assert.deepEqual(config.providers.openai.env,["OPENAI_API_KEY"]);
    assert.equal(config.providers.openai.settings.transport,"http","The gateway does not accept WebSocket upgrades");
    assert.ok(!JSON.stringify(config).includes("synthetic-openai-key"));
    await harness.prompt(session,"Get the synthetic frame then answer.",undefined,undefined,"max",png);
    let state=await harness.inspect(session);
    for(let n=0;state.status==="running" && n<150;n++) {
      await new Promise(resolve=>setTimeout(resolve,50));
      state=await harness.inspect(session);
    }
    assert.equal(state.status,"idle",state.error);
    assert.deepEqual(calls,["app_call"]);
    assert.ok(JSON.stringify(requests[0].body.input).includes("Hello from the previous provider."));
    assert.equal(requests.length,2);
    for(const request of requests) {
      assert.equal(new URL(request.path,"http://fixture").pathname,"/v1/responses");
      assert.equal(request.key,"Bearer synthetic-openai-key");
      assert.equal(request.body.model,"gpt-6.2-sol");
      assert.equal(request.body.reasoning?.effort,undefined,"Relay offers no OpenAI effort, so a requested Max is not sent");
      // Reasoning counts against the cap; OpenAI advises reserving at least 25,000 tokens.
      assert.ok(request.body.max_output_tokens === undefined || request.body.max_output_tokens >= 25_000);
    }
    assert.ok(JSON.stringify(state.messages).includes("OpenAI tool round trip completed."));
    assert.equal((await readFile(checksFile, "utf8")).trim().split("\n").length, 2,
      "Every model call, including the tool continuation, passed the gateway");
    assert.ok(requests[0].body.input.some((item: any) => Array.isArray(item.content) &&
      item.content.some((part: any) => part.type === "input_image" && String(part.image_url).endsWith(png))));
    const output = requests[1].body.input.find((item: any) => item.type === "function_call_output").output;
    assert.ok(Array.isArray(output));
    assert.ok(output.some((part: any) => part.type === "input_image" && String(part.image_url).endsWith(png)));
    assert.ok(output.some((part: any) => part.type === "input_text" && part.text.includes("Synthetic frame") && !part.text.includes(png)));
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

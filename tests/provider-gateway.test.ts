import test from "node:test";
import assert from "node:assert/strict";
import { createServer, type RequestListener } from "node:http";
import type { AddressInfo } from "node:net";
import { startProviderGateway } from "../server/provider-gateway.ts";
import { ProviderNetworkError } from "../server/provider-network.ts";

async function listen(handler: RequestListener) {
  const server=createServer(handler);
  await new Promise<void>(resolve=>server.listen(0,"127.0.0.1",resolve));
  return {url:`http://127.0.0.1:${(server.address() as AddressInfo).port}`,close:()=>new Promise<void>(resolve=>{
    server.closeAllConnections(); server.close(()=>resolve());
  })};
}

test("gateway checks each request before attaching keys, including repeated requests after disconnect", async () => {
  for (const auth of [{header:"authorization",prefix:"Bearer "},{header:"x-api-key",prefix:""}]) {
    let connected=true, checks=0;
    const received: Array<{key:unknown;body:string;path:string|undefined}>=[];
    const upstream=await listen(async (req,res)=>{
      let body="";for await(const chunk of req) body+=chunk;
      received.push({key:req.headers[auth.header],body,path:req.url});
      assert.equal(req.headers.cookie,undefined);
      res.writeHead(200,{"Content-Type":"text/event-stream"}).end("data: synthetic reply\n\n");
    });
    const gateway=await startProviderGateway({baseURL:upstream.url+"/v1",auth},"synthetic-real-key",async()=>{
      checks++;
      if(!connected) throw new ProviderNetworkError("NordVPN is not connected in WSL. No API request was sent.");
    });
    const send=(token=gateway.token)=>fetch(gateway.url+"/messages?beta=true",{
      method:"POST",headers:{[auth.header]:auth.prefix+token,"content-type":"application/json",cookie:"must-not-forward"},body:'{"message":"synthetic"}',
    });
    try {
      const unauthorized=await send("wrong-token");
      assert.equal(unauthorized.status,403);assert.equal(checks,0);
      const response=await send();
      assert.equal(response.status,200);assert.match(await response.text(),/synthetic reply/);
      assert.deepEqual(received,[{key:auth.prefix+"synthetic-real-key",body:'{"message":"synthetic"}',path:"/v1/messages?beta=true"}]);
      connected=false;
      for(let n=0;n<2;n++) {
        const blocked=await send();
        assert.equal(blocked.status,403);
        const body=await blocked.text();
        assert.match(body,/NordVPN is not connected/);assert.ok(!body.includes("synthetic-real-key"));
      }
      assert.equal(received.length,1);assert.equal(checks,3);
    } finally {await gateway.close();await upstream.close();}
  }
});

test("gateway streams without buffering, cancels upstream work, and never follows redirects", async () => {
  let redirected=0, cancelled!:()=>void;
  const upstreamCancelled=new Promise<void>(resolve=>{cancelled=resolve;});
  const other=await listen((_req,res)=>{redirected++;res.end("unexpected");});
  const upstream=await listen((req,res)=>{
    if(req.url==="/v1/redirect") {res.writeHead(307,{Location:other.url+"/stolen"}).end();return;}
    res.writeHead(200,{"Content-Type":"text/event-stream"});
    res.write("data: first event\n\n");
    res.on("close",cancelled);
  });
  const gateway=await startProviderGateway({baseURL:upstream.url+"/v1",auth:{header:"authorization",prefix:"Bearer "}},"synthetic-key",async()=>{});
  const headers={authorization:"Bearer "+gateway.token};
  try {
    const abort=new AbortController();
    const response=await fetch(gateway.url+"/stream",{method:"POST",headers,body:"{}",signal:abort.signal});
    const reader=response.body!.getReader();
    assert.match(new TextDecoder().decode((await reader.read()).value),/first event/);
    abort.abort();
    await Promise.race([upstreamCancelled,new Promise((_,reject)=>setTimeout(()=>reject(Error("Upstream was not cancelled")),2000).unref())]);
    const redirect=await fetch(gateway.url+"/redirect",{method:"POST",headers,body:"{}"});
    assert.equal(redirect.status,502);assert.equal(redirected,0);
  } finally {await gateway.close();await upstream.close();await other.close();}
});

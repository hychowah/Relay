import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import type { AddressInfo } from "node:net";
import { serve } from "@hono/node-server";
import { WebSocket } from "ws";
import { createBrowser } from "../server/browser.ts";

test("the built-in Browser relays page reads and transcripts to the connected client and refuses web-page sockets", async () => {
  const browser = createBrowser();
  const server = serve({ fetch: browser.app.fetch, hostname: "127.0.0.1", port: 0 });
  browser.attach(server);
  await once(server, "listening");
  const port = (server.address() as AddressInfo).port;
  const call = async (operation: string, args: unknown) => {
    const response = await fetch(`http://127.0.0.1:${port}/_relay/call`, { method: "POST", body: JSON.stringify({ operation, arguments: args }) });
    return JSON.parse((await response.text()).trim());
  };
  const session = "11111111-2222-3333-4444-555555555555";
  try {
    assert.match((await call("browser.read", { sessionId: session, tabId: "tab" })).message, /disconnected/);

    const page = new WebSocket(`ws://127.0.0.1:${port}/desktop/connect?session=${session}`, { origin: "https://example.com" });
    await once(page, "error");

    const client = new WebSocket(`ws://127.0.0.1:${port}/desktop/connect?session=${session}`);
    await once(client, "open");
    client.on("message", (raw) => {
      const request = JSON.parse(raw.toString());
      if (request.type === "read")
        client.send(JSON.stringify({ id: request.id, data: { tabId: request.tabId, text: "Page text" } }));
      else if (request.offset === 0)
        client.send(JSON.stringify({ id: request.id, data: { text: "[0:01] Hello", nextOffset: 13 } }));
      else client.send(JSON.stringify({ id: request.id, error: "This video has no captions, so it has no transcript." }));
    });
    assert.deepEqual(await call("browser.read", { sessionId: session, tabId: "tab" }),
      { type: "result", result: { data: { tabId: "tab", text: "Page text" } } });
    assert.deepEqual((await call("browser.transcript", { sessionId: session, tabId: "tab" })).result.data,
      { text: "[0:01] Hello", nextOffset: 13 });
    assert.deepEqual(await call("browser.transcript", { sessionId: session, tabId: "tab", offset: 13 }),
      { type: "error", message: "This video has no captions, so it has no transcript." });
    assert.deepEqual((await call("browser.open", { url: "https://example.com/a" })).result.data,
      { presentation: { viewId: "browser", state: { url: "https://example.com/a" } } });
    client.close();
  } finally {
    browser.close();
    server.close();
  }
});

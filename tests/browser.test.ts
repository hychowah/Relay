import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import type { AddressInfo } from "node:net";
import { serve } from "@hono/node-server";
import { WebSocket } from "ws";
import { createBrowser } from "../server/browser.ts";

test("the built-in Browser relays page reads, transcripts and form fills to the connected client and refuses web-page sockets", async () => {
  const browser = createBrowser();
  const server = serve({ fetch: () => new Response(null, { status: 404 }), hostname: "127.0.0.1", port: 0 });
  browser.attach(server);
  await once(server, "listening");
  const port = (server.address() as AddressInfo).port;
  const call = (operation: string, args: Record<string, unknown>) => browser.app.integration.call!(operation, args, {});
  const failure = (operation: string, args: Record<string, unknown>) =>
    call(operation, args).then(() => assert.fail("expected an error"), (error: Error) => error.message);
  const session = "11111111-2222-3333-4444-555555555555";
  try {
    assert.match(await failure("browser.read", { sessionId: session, tabId: "tab" }), /disconnected/);
    assert.match(await failure("browser.write", {}), /Unknown/);

    const page = new WebSocket(`ws://127.0.0.1:${port}/desktop/connect?session=${session}`, { origin: "https://example.com" });
    await once(page, "error");

    const client = new WebSocket(`ws://127.0.0.1:${port}/desktop/connect?session=${session}`);
    await once(client, "open");
    client.on("message", (raw) => {
      const request = JSON.parse(raw.toString());
      if (request.type === "read")
        client.send(JSON.stringify({ id: request.id, data: { tabId: request.tabId, text: "Page text" } }));
      else if (request.type === "form")
        client.send(JSON.stringify({ id: request.id, data: { fields: [{ id: "f1", type: "email", label: "Email" }] } }));
      else if (request.type === "fill")
        client.send(JSON.stringify({ id: request.id, data: { asked: request.fields, submitted: false } }));
      else if (request.offset === 0)
        client.send(JSON.stringify({ id: request.id, data: { text: "[0:01] Hello", nextOffset: 13 } }));
      else client.send(JSON.stringify({ id: request.id, error: "This video has no captions, so it has no transcript." }));
    });
    assert.deepEqual(await call("browser.read", { sessionId: session, tabId: "tab" }), { data: { tabId: "tab", text: "Page text" } });
    assert.deepEqual((await call("browser.transcript", { sessionId: session, tabId: "tab" })).data,
      { text: "[0:01] Hello", nextOffset: 13 });
    assert.match(await failure("browser.transcript", { sessionId: session, tabId: "tab", offset: 13 }), /no captions/);
    assert.deepEqual((await call("browser.form", { sessionId: session, tabId: "tab" })).data,
      { fields: [{ id: "f1", type: "email", label: "Email" }] });
    assert.deepEqual((await call("browser.fill", { sessionId: session, tabId: "tab",
      fields: [{ id: "f1", value: "ada@example.com" }, { id: "f2", value: true }, { id: 3, value: 4 }] })).data,
    { asked: [{ id: "f1", value: "ada@example.com" }, { id: "f2", value: true }, { id: "3", value: "4" }], submitted: false });
    assert.match(await failure("browser.fill", { sessionId: session, tabId: "tab", fields: [] }), /browser\.form/);
    assert.deepEqual((await call("browser.open", { url: "https://example.com/a" })).data,
      { presentation: { viewId: "browser", state: { url: "https://example.com/a" } } });
    client.close();
  } finally {
    browser.close();
    server.close();
  }
});

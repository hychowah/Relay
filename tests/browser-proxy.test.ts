import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { connect, createServer, type AddressInfo } from "node:net";
import { serve } from "@hono/node-server";
import { WebSocket } from "ws";
import { createBrowser } from "../server/browser.ts";
import { attachBrowserProxy, publicAddress } from "../server/browser-proxy.ts";

test("the Browser proxy allows only public addresses", () => {
  for (const address of ["8.8.8.8", "172.32.0.1", "100.128.0.1", "2606:4700::1", "::ffff:8.8.8.8"])
    assert.equal(publicAddress(address), true, address);
  for (const address of ["10.1.2.3", "127.0.0.1", "172.31.255.255", "192.168.1.1", "100.64.0.1", "169.254.1.1",
    "224.0.0.1", "::", "::1", "fe80::1", "fd00::1", "ff02::1", "::ffff:192.168.1.1", "::ffff:7f00:1"])
    assert.equal(publicAddress(address), false, address);
});

test("the Browser proxy refuses local targets and a failed VPN check without connecting", async () => {
  let vpnUp = true;
  let checks = 0;
  const browser = createBrowser();
  const server = serve({ fetch: () => new Response(null, { status: 404 }), hostname: "127.0.0.1", port: 0 });
  browser.attach(server);
  const proxy = attachBrowserProxy(server, async () => {
    checks++;
    await new Promise((done) => setTimeout(done, 20));
    if (!vpnUp) throw new Error("NordVPN is not connected.");
  });
  let reached = 0;
  const local = createServer((socket) => { reached++; socket.destroy(); }).listen(0, "127.0.0.1");
  await Promise.all([once(server, "listening"), once(local, "listening")]);
  const port = (server.address() as AddressInfo).port;
  const tunnel = async (target: string) => {
    const socket = connect(port, "127.0.0.1");
    socket.write(`CONNECT ${target} HTTP/1.1\r\nHost: ${target}\r\n\r\n`);
    const [data] = await once(socket, "data");
    socket.destroy();
    return data.toString().split("\r\n")[0];
  };
  try {
    const localPort = (local.address() as AddressInfo).port;
    assert.equal(await tunnel(`127.0.0.1:${localPort}`), "HTTP/1.1 403 Forbidden");
    assert.equal(await tunnel(`[::ffff:127.0.0.1]:${localPort}`), "HTTP/1.1 403 Forbidden");
    vpnUp = false;
    assert.equal(await tunnel("192.0.2.1:443"), "HTTP/1.1 503 Service Unavailable");
    assert.equal(checks, 3);
    // Tunnels that start while a check runs share it.
    assert.deepEqual(await Promise.all([tunnel("192.0.2.1:443"), tunnel("192.0.2.2:443")]),
      ["HTTP/1.1 503 Service Unavailable", "HTTP/1.1 503 Service Unavailable"]);
    assert.equal(checks, 4);
    assert.equal(reached, 0);

    const client = new WebSocket(`ws://127.0.0.1:${port}/desktop/connect?session=11111111-2222-3333-4444-555555555555`);
    await once(client, "open");
    client.close();
  } finally {
    proxy.close();
    browser.close();
    server.close();
    local.close();
  }
});

import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { connect, createServer, type AddressInfo, type Socket } from "node:net";
import { serve } from "@hono/node-server";
import { WebSocket } from "ws";
import { createBrowser } from "../server/browser.ts";
import { attachBrowserProxy, publicAddress } from "../server/browser-proxy.ts";

test("the Browser proxy allows only public addresses", () => {
  for (const address of ["8.8.8.8", "172.32.0.1", "100.128.0.1", "2606:4700::1", "::ffff:8.8.8.8"])
    assert.equal(publicAddress(address), true, address);
  for (const address of ["0.0.0.0", "10.1.2.3", "127.0.0.1", "172.31.255.255", "192.168.1.1", "100.64.0.1", "169.254.1.1",
    "224.0.0.1", "::", "::1", "fe80::1", "fd00::1", "ff02::1", "::ffff:192.168.1.1", "::ffff:7f00:1",
    "::7f00:1", "64:ff9b::a00:1", "2002:c0a8:101::1"])
    assert.equal(publicAddress(address), false, address);
});

test("the Browser proxy refuses local targets and a failed VPN check without connecting", async (t) => {
  // The watch's own checks stay out of the counts below.
  t.mock.timers.enable({ apis: ["setInterval"] });
  let vpnUp = true;
  let checks = 0;
  const browser = createBrowser();
  const server = serve({ fetch: () => new Response(null, { status: 404 }), hostname: "127.0.0.1", port: 0 });
  browser.attach(server);
  const lookups: string[] = [];
  const proxy = attachBrowserProxy(server, async () => {
    checks++;
    await new Promise((done) => setTimeout(done, 200));
    if (!vpnUp) throw new Error("NordVPN is not connected.");
  }, async (host) => {
    lookups.push(host);
    return host === "mixed.test" ? ["93.184.215.14", "10.0.0.1"] : [host];
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
    // Every address of a name must be public.
    assert.equal(await tunnel("mixed.test:443"), "HTTP/1.1 403 Forbidden");
    assert.equal(reached, 0);
    vpnUp = false;
    assert.equal(await tunnel("down.test:443"), "HTTP/1.1 503 Service Unavailable");
    assert.equal(checks, 4);
    // Tunnels that start while a check runs share it.
    assert.deepEqual(await Promise.all([tunnel("down.test:443"), tunnel("down.test:80")]),
      ["HTTP/1.1 503 Service Unavailable", "HTTP/1.1 503 Service Unavailable"]);
    assert.equal(checks, 5);
    // While NordVPN is down, no name is looked up.
    assert.ok(!lookups.includes("down.test"));

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

test("the Browser proxy closes its open tunnels when NordVPN drops, until it is back", async (t) => {
  t.mock.timers.enable({ apis: ["setInterval"] });
  let vpnUp = true;
  let checks = 0;
  const server = serve({ fetch: () => new Response(null, { status: 404 }), hostname: "127.0.0.1", port: 0 });
  // A tunnel that passed its check stays open here, at its name lookup.
  let lookedUp = () => {};
  const proxy = attachBrowserProxy(server, async () => {
    checks++;
    if (!vpnUp) throw new Error("NordVPN is not connected.");
  }, () => { lookedUp(); return new Promise<string[]>(() => {}); });
  await once(server, "listening");
  const port = (server.address() as AddressInfo).port;
  const request = (target: string) => {
    const socket = connect(port, "127.0.0.1");
    socket.write(`CONNECT ${target} HTTP/1.1\r\nHost: ${target}\r\n\r\n`);
    return socket;
  };
  // A tunnel the proxy leaves open fails the test instead of hanging it.
  const closes = (socket: Socket) => Promise.race([once(socket, "close"), new Promise((_, fail) =>
    setTimeout(() => fail(new Error("The tunnel stayed open.")), 2000).unref())]);
  const open = async () => {
    const reached = new Promise<void>((done) => { lookedUp = done; });
    const socket = request("open.test:443");
    await reached;
    return socket;
  };
  try {
    // The watch finds the drop: the open tunnel closes without a new request.
    const first = await open();
    vpnUp = false;
    t.mock.timers.tick(2000);
    await closes(first);
    // No tunnel is open, so nothing is checked.
    const before = checks;
    t.mock.timers.tick(2000);
    assert.equal(checks, before);

    // Back up, tunnels open again; a new tunnel's failed check also closes them.
    vpnUp = true;
    const second = await open();
    vpnUp = false;
    const refused = request("down.test:443");
    const [[data]] = await Promise.all([once(refused, "data"), closes(second)]);
    assert.equal(data.toString().split("\r\n")[0], "HTTP/1.1 503 Service Unavailable");
    refused.destroy();
  } finally {
    proxy.close();
    server.close();
  }
});

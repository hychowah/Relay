import { BlockList, connect, isIP, type Socket } from "node:net";
import { lookup } from "node:dns/promises";
import type { IncomingMessage } from "node:http";
import type { serve } from "@hono/node-server";
import { requireNordVPN } from "./provider-network.ts";

// The Mac Browser's rule (privateAddress in flutter/lib/web_page.dart). BlockList
// judges an IPv4-mapped IPv6 address by the IPv4 ranges.
const privateRanges = new BlockList();
for (const [network, prefix] of [["0.0.0.0", 8], ["10.0.0.0", 8], ["127.0.0.0", 8], ["169.254.0.0", 16],
  ["172.16.0.0", 12], ["192.168.0.0", 16], ["100.64.0.0", 10], ["224.0.0.0", 3]] as const)
  privateRanges.addSubnet(network, prefix, "ipv4");
for (const [network, prefix] of [["::", 128], ["::1", 128], ["fe80::", 10], ["ff00::", 8], ["fc00::", 7]] as const)
  privateRanges.addSubnet(network, prefix, "ipv6");

export function publicAddress(address: string) {
  const family = isIP(address);
  return family !== 0 && !privateRanges.check(address, family === 4 ? "ipv4" : "ipv6");
}

function refuse(client: Socket, status: string) {
  client.end(`HTTP/1.1 ${status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`);
}

// Proxy tunnels (HTTP CONNECT) for VPN Browser tabs: traffic leaves through WSL's
// NordVPN, to public addresses only. Destinations are never logged.
export function attachBrowserProxy(server: ReturnType<typeof serve>, requireNetwork = requireNordVPN) {
  // A page opens many tunnels at once; 30 parallel checks took 0.45 s, so tunnels
  // that start while a check runs share it. Nothing is reused after it ends.
  let running: Promise<void> | undefined;
  // Answered tunnels leave the HTTP server, so server.close() would wait for them.
  const clients = new Set<Socket>();
  server.on("connect", async (request: IncomingMessage, client: Socket, head: Buffer) => {
    client.on("error", () => {});
    clients.add(client);
    client.on("close", () => clients.delete(client));
    const target = /^\[?([^\]]*)\]?:(\d+)$/.exec(request.url ?? "");
    const port = Number(target?.[2]);
    if (!target || port > 65535) return refuse(client, "400 Bad Request");
    // The check comes first so that no name lookup leaves WSL while NordVPN is down.
    try { await (running ??= requireNetwork().finally(() => { running = undefined; })); }
    catch { return refuse(client, "503 Service Unavailable"); }
    const found = await lookup(target[1], { all: true }).catch(() => []);
    if (!found.length) return refuse(client, "502 Bad Gateway");
    if (!found.every(({ address }) => publicAddress(address))) return refuse(client, "403 Forbidden");
    if (client.destroyed) return;
    // Connect to the address that was checked, never a fresh lookup.
    let open = false;
    const upstream = connect(port, found[0].address, () => {
      open = true;
      client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head.length) upstream.write(head);
      upstream.pipe(client).pipe(upstream);
    });
    upstream.on("error", () => open ? client.destroy() : refuse(client, "502 Bad Gateway"));
    client.on("close", () => upstream.destroy());
  });
  return { close() { for (const client of clients) client.destroy(); } };
}

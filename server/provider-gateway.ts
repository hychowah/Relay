import { randomBytes } from "node:crypto";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { ProviderNetworkError, requireNordVPN, createProviderRequest } from "./provider-network.ts";

// The provider adapter speaks its native protocol to this local endpoint. Only
// this service holds the real key and attaches it after the network prerequisite.
// The destination is fixed by service configuration, not by an incoming request.
export async function startProviderGateway(
  transport: { baseURL: string; auth: { header: string; prefix: string } },
  apiKey: string,
  requireNetwork: () => Promise<void> = requireNordVPN,
) {
  const upstream = new URL(transport.baseURL);
  const prefix = upstream.pathname.replace(/\/$/, "");
  const token = randomBytes(32).toString("hex");
  const send = createProviderRequest(transport, apiKey, requireNetwork);
  const server = createServer(async (request, response) => {
    const abort = new AbortController();
    response.on("close", () => abort.abort());
    if (request.headers[transport.auth.header] !== transport.auth.prefix + token) {
      response.writeHead(403).end();
      return;
    }
    if (!request.url?.startsWith("/") || request.method !== "POST") {
      response.writeHead(400).end();
      return;
    }
    try {
      const headers = new Headers();
      for (const [name, value] of Object.entries(request.headers)) {
        if (typeof value === "string") headers.set(name, value);
      }
      const result = await send(request.url!, {
        method: "POST", headers, redirect: "error", signal: abort.signal,
        body: Readable.toWeb(request) as ReadableStream<Uint8Array>,
        duplex: "half",
      } as RequestInit & { duplex: "half" });
      response.writeHead(result.status, {
        "Content-Type": result.headers.get("content-type") || "application/json",
        "Cache-Control": "no-store",
      });
      if (result.body) await pipeline(Readable.fromWeb(result.body as import("node:stream/web").ReadableStream), response);
      else response.end();
    } catch (error) {
      if (abort.signal.aborted) return;
      if (response.headersSent) { response.destroy(); return; }
      const blocked = error instanceof ProviderNetworkError;
      // 403 is non-retryable for the adapters. Preserve the actionable VPN error
      // without leaking upstream URLs, headers or credentials into agent records.
      response.writeHead(blocked ? 403 : 502, {"Content-Type": "application/json"}).end(JSON.stringify({
        type: "error",
        error: {
          type: blocked ? "permission_error" : "api_error",
          message: blocked ? error.message : "The provider connection failed. Check the VPN and provider availability, then retry.",
        },
      }));
    }
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  return {
    url: `http://127.0.0.1:${(server.address() as AddressInfo).port}${prefix}`,
    token,
    close: () => new Promise<void>((resolve, reject) => {
      server.closeAllConnections();
      server.close(error => error ? reject(error) : resolve());
    }),
  };
}

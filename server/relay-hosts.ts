/**
 * Relay answers only requests that name one of its own addresses (host:port)
 * in Host. A website whose name is rebound to Relay's address (DNS rebinding)
 * is same-origin with Relay, so no Origin check can stop it; its requests
 * still carry its own name. This wraps the whole service, so no route, path
 * spelling or route added later is left out.
 */
export function onlyRelayHosts<Rest extends unknown[]>(
  fetch: (request: Request, ...rest: Rest) => Response | Promise<Response>,
  hosts: string[],
) {
  const allowed = new Set(hosts.map((host) => host.toLowerCase()));
  return (request: Request, ...rest: Rest) =>
    allowed.has(request.headers.get("host")?.toLowerCase() ?? "")
      ? fetch(request, ...rest)
      : Response.json({ error: "Open Relay at its own address." }, { status: 403 });
}

/** The loopback addresses of a service on [port], and the address devices use, when set. */
export function relayHosts(port: number, deviceOrigin?: string) {
  return [`127.0.0.1:${port}`, `localhost:${port}`, ...(deviceOrigin ? [new URL(deviceOrigin).host] : [])];
}

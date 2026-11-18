import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execute = promisify(execFile);

export class ProviderNetworkError extends Error {}

// A fresh status check is required for every outbound request. This is not a
// network kill switch: OS routing must protect a request after the check passes.
// The check is on unless the operator sets RELAY_VPN_CHECK=off.
export async function requireNordVPN(): Promise<void> {
  if (process.env.RELAY_VPN_CHECK === "off") return;
  let stdout: string;
  try {
    ({ stdout } = await execute("nordvpn", ["status"], {
      timeout: 5000, maxBuffer: 64 * 1024,
      env: { ...process.env, LC_ALL: "C", TERM: "dumb" },
    }));
  } catch {
    throw new ProviderNetworkError("Cannot verify NordVPN in WSL. Check that NordVPN is running and connected, then retry. No API request was sent.");
  }
  const status = stdout.replace(/\x1b\[[0-9;]*[A-Za-z]/g, "").replace(/\r/g, "\n");
  if (!/^\s*Status:\s*Connected\s*$/m.test(status))
    throw new ProviderNetworkError("NordVPN is not connected in WSL. Connect NordVPN, then retry. No API request was sent.");
}

// Shared outbound boundary for model inference and discovery. The destination is
// service-owned; every request checks the VPN before attaching real credentials.
export function createProviderRequest(
  transport: {baseURL: string; auth: {header: string; prefix: string}},
  apiKey: string,
  requireNetwork: () => Promise<void> = requireNordVPN,
) {
  const upstream = new URL(transport.baseURL);
  const prefix = upstream.pathname.replace(/\/$/, "");
  return async (path: string, init: RequestInit & {duplex?: "half"} = {}) => {
    const target = new URL(path, upstream.origin);
    if (!path.startsWith("/") || target.origin !== upstream.origin || !target.pathname.startsWith(prefix + "/"))
      throw new Error("Invalid provider request destination.");
    await requireNetwork();
    init.signal?.throwIfAborted();
    const inputHeaders = new Headers(init.headers);
    const headers = new Headers();
    for (const name of ["content-type", "accept", "anthropic-version", "anthropic-beta"]) {
      const value = inputHeaders.get(name);
      if (value) headers.set(name, value);
    }
    headers.set(transport.auth.header, transport.auth.prefix + apiKey);
    return fetch(target, {...init, headers, redirect: "error"});
  };
}

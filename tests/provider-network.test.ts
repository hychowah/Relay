import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { requireNordVPN, ProviderNetworkError } from "../server/provider-network.ts";

test("NordVPN check accepts only a successful connected status and fails closed otherwise", async () => {
  const dir = await mkdtemp(join(tmpdir(), "relay-vpn-status-"));
  const previousPath = process.env.PATH;
  try {
    process.env.PATH = dir;
    for (const [output, exit, allowed] of [
      ["Status: Connected", 0, true],
      ["Status: Disconnected", 0, false],
      ["Status: Connecting", 0, false],
      ["Unexpected response", 0, false],
      ["Status: Connected", 1, false],
    ] as const) {
      await writeFile(join(dir,"nordvpn"), `#!/bin/sh\nprintf '%s\\n' '${output}'\nexit ${exit}\n`, {mode:0o700});
      if (allowed) await requireNordVPN();
      else await assert.rejects(requireNordVPN(), error => error instanceof ProviderNetworkError && /No API request was sent/.test(error.message));
    }
    await rm(join(dir,"nordvpn"));
    await assert.rejects(requireNordVPN(), /Cannot verify NordVPN in WSL/);
    process.env.RELAY_VPN_CHECK = "off";
    await requireNordVPN();
    delete process.env.RELAY_VPN_CHECK;
  } finally {
    process.env.PATH = previousPath;
    await rm(dir,{recursive:true,force:true});
  }
});

// Runs one Flutter integration test on the Mac against real WKWebViews:
// `npm run test:mac -- popup_windows_test.dart`. The test app has its own
// bundle id and its data is removed afterwards (see mac-flutter.ts). Only for
// tests that never use the Flutter deployment's records, so never
// workflow_test.dart. browser_vpn_test.dart uses the backend's VPN route only,
// through the app's usual origin (`relay.appUrl`), passed as RELAY_URL.
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { flutterScript, mac, withMacCopy } from "./mac-flutter.ts";

const BUNDLE_ID = "app.relay.flutterTest";
const root = resolve(import.meta.dirname, "..");
const test = process.argv[2] ?? "";
if (!/^[a-z_]+_test\.dart$/.test(test) || test === "workflow_test.dart") {
  throw new Error("Name one self-contained test in flutter/integration_test, such as popup_windows_test.dart.");
}
let relayUrl = "";
try { relayUrl = execFileSync("git", ["config", "--get", "relay.appUrl"], { cwd: root, encoding: "utf8" }).trim(); }
catch { /* Only tests that use the backend need it. */ }
const define = relayUrl ? ` --dart-define=RELAY_URL='${relayUrl}'` : "";

await withMacCopy(root, BUNDLE_ID, async (ssh, remote) => {
  console.log(`Building and running ${test} on the Mac; its windows show briefly...`);
  // A failure rejects with the output's tail.
  const output = await mac(ssh, `${flutterScript(remote, BUNDLE_ID)}flutter test -d macos${define} integration_test/${test}`);
  console.log(output.trim().split("\n").slice(-20).join("\n"));
});

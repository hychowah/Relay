// Runs one Flutter integration test on the Mac against real WKWebViews:
// `npm run test:mac -- popup_windows_test.dart`. The test app has its own
// bundle id and its data is removed afterwards (see mac-flutter.ts). Only for
// self-contained tests with their own fixtures; never workflow_test.dart,
// which uses the Flutter deployment's records.
import { resolve } from "node:path";
import { flutterScript, mac, withMacCopy } from "./mac-flutter.ts";

const BUNDLE_ID = "app.relay.flutterTest";
const root = resolve(import.meta.dirname, "..");
const test = process.argv[2] ?? "";
if (!/^[a-z_]+_test\.dart$/.test(test) || test === "workflow_test.dart") {
  throw new Error("Name one self-contained test in flutter/integration_test, such as popup_windows_test.dart.");
}

await withMacCopy(root, BUNDLE_ID, async (ssh, remote) => {
  console.log(`Building and running ${test} on the Mac; its windows show briefly...`);
  // A failure rejects with the output's tail.
  const output = await mac(ssh, `${flutterScript(remote, BUNDLE_ID)}flutter test -d macos integration_test/${test}`);
  console.log(output.trim().split("\n").slice(-20).join("\n"));
});

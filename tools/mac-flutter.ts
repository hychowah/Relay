// Runs this checkout's Flutter source on the Mac from a temporary folder, as
// an app with its own bundle id, so a run never reads or writes the installed
// app's preferences, WebKit data or saved window position. Removes the folder
// and the test app's data afterwards. Used by perf-ui.ts and mac-test.ts.
import { execFileSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

/** Runs a command on the Mac; resolves with its output, or rejects with its tail. */
export function mac(ssh: string, command: string, input?: Buffer) {
  return new Promise<string>((done, fail) => {
    const child = spawn(ssh, [command], { stdio: ["pipe", "pipe", "pipe"] });
    let output = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.stderr.on("data", (chunk) => { output += chunk; });
    child.on("error", fail);
    child.on("close", (code) => code === 0 ? done(output)
      : fail(new Error(`Mac command failed (${code}):\n${output.split("\n").slice(-40).join("\n")}`)));
    child.stdin.end(input);
  });
}

// Removes the temporary folder, the test app's own settings and data, and the
// small DerivedData folder Xcode keeps for the temporary project path.
const cleanupScript = (remote: string, bundleId: string) => `pkill -f '${remote}/' || true
sleep 1
rm -rf '${remote}'
defaults delete ${bundleId} >/dev/null 2>&1 || true
cd ~/Library
rm -rf "Preferences/${bundleId}.plist" "Application Support/${bundleId}" "Caches/${bundleId}" \\
  "WebKit/${bundleId}" "HTTPStorages/${bundleId}" "HTTPStorages/${bundleId}.binarycookies" \\
  "Saved Application State/${bundleId}.savedState"
grep -l '"path":"${remote}/' Developer/Xcode/DerivedData/*/Build/Intermediates.noindex/XCBuildData/PIFCache/workspace/* 2>/dev/null \\
  | sed 's|/Build/.*||' | while read -r folder; do rm -rf "$folder"; done`;

/** The start of a Mac script: the SDK, the copy's flutter/ folder and its own bundle id. */
export const flutterScript = (remote: string, bundleId: string) => `set -eu
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="$HOME/Developer/relay-flutter-experiment/sdk/bin:$PATH"
cd '${remote}/flutter'
sed -i '' 's/^PRODUCT_BUNDLE_IDENTIFIER = .*/PRODUCT_BUNDLE_IDENTIFIER = ${bundleId}/' macos/Runner/Configs/AppInfo.xcconfig
grep -qx 'PRODUCT_BUNDLE_IDENTIFIER = ${bundleId}' macos/Runner/Configs/AppInfo.xcconfig
`;

/** Copies the checkout's flutter/ folder to a new Mac folder, runs `use`, then cleans up. */
export async function withMacCopy<T>(root: string, bundleId: string,
  use: (ssh: string, remote: string) => Promise<T>) {
  let ssh: string;
  try { ssh = execFileSync("git", ["config", "--get", "relay.macSSH"], { cwd: root, encoding: "utf8" }).trim(); }
  catch { throw new Error("Set relay.macSSH in local git config (see docs/development.md)."); }
  const remote = (await mac(ssh, "mktemp -d /tmp/relay-mac-run.XXXXXXXX")).trim();
  if (!/^\/tmp\/relay-mac-run\.[A-Za-z0-9]+$/.test(remote)) throw new Error(`Unexpected Mac folder: ${remote}`);
  let cleaning: Promise<unknown> | undefined;
  const cleanup = () => cleaning ??= mac(ssh, cleanupScript(remote, bundleId)).catch((error) =>
    console.error(`Cleanup on the Mac failed; remove ${remote} and the ${bundleId} data by hand.\n${error.message}`));
  process.once("SIGINT", () => void cleanup().finally(() => process.exit(130)));
  try {
    // This checkout's Flutter source, including uncommitted edits.
    const files = execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "flutter"],
      { cwd: root, encoding: "utf8" }).split("\0").filter((path) => path && existsSync(join(root, path)));
    const source = execFileSync("tar", ["--null", "-T", "-", "-czf", "-"],
      { cwd: root, input: files.join("\0"), maxBuffer: 512 * 1024 * 1024 });
    await mac(ssh, `tar -xzf - -C '${remote}'`, source);
    return await use(ssh, remote);
  } finally {
    await cleanup();
  }
}

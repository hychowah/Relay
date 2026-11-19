// Manual UI smoothness review on the Mac: `npm run perf:ui`. Not a test or a
// gate. It runs flutter/integration_test/ui_performance_test.dart from a
// temporary copy of this checkout's flutter/ folder on the Mac, saves the
// result to tmp/perf/ui-<timestamp>.json and compares it with the previous UI run.
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { latestResult, percentChange, printRows } from "./perf-table.ts";

// The test app gets its own bundle id, so it never reads or writes the
// installed app's preferences, WebKit data or saved window position.
const BUNDLE_ID = "app.relay.flutterPerf";
// Marked changes. In three runs of one commit on the MacBook Neo, fps moved by
// up to 3 (one 100 ms hitch among 190 frames) and slow frames by up to 1.1 points.
const FPS_DROP = 5;
const SLOW_RISE = 3;

const root = resolve(import.meta.dirname, "..");
const resultsDir = join(root, "tmp", "perf");
const git = (...args: string[]) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();

type Summary = Record<string, number>;
type Result = { scenarios: Record<string, Summary> };

/** Runs a command on the Mac; resolves with its output, or rejects with its tail. */
function mac(ssh: string, command: string, input?: Buffer) {
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
const cleanupScript = (remote: string) => `pkill -f '${remote}/' || true
sleep 1
rm -rf '${remote}'
defaults delete ${BUNDLE_ID} >/dev/null 2>&1 || true
cd ~/Library
rm -rf "Preferences/${BUNDLE_ID}.plist" "Application Support/${BUNDLE_ID}" "Caches/${BUNDLE_ID}" \\
  "WebKit/${BUNDLE_ID}" "HTTPStorages/${BUNDLE_ID}" "HTTPStorages/${BUNDLE_ID}.binarycookies" \\
  "Saved Application State/${BUNDLE_ID}.savedState"
grep -l '"path":"${remote}/' Developer/Xcode/DerivedData/*/Build/Intermediates.noindex/XCBuildData/PIFCache/workspace/* 2>/dev/null \\
  | sed 's|/Build/.*||' | while read -r folder; do rm -rf "$folder"; done`;

const runScript = (remote: string) => `set -eu
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="$HOME/Developer/relay-flutter-experiment/sdk/bin:$PATH"
cd '${remote}/flutter'
sed -i '' 's/^PRODUCT_BUNDLE_IDENTIFIER = .*/PRODUCT_BUNDLE_IDENTIFIER = ${BUNDLE_ID}/' macos/Runner/Configs/AppInfo.xcconfig
grep -qx 'PRODUCT_BUNDLE_IDENTIFIER = ${BUNDLE_ID}' macos/Runner/Configs/AppInfo.xcconfig
flutter drive --profile -d macos --driver=test_driver/integration_test.dart \\
  --target=integration_test/ui_performance_test.dart`;

const COLUMNS: Array<[key: string, header: string]> = [
  ["frames", "Frames"], ["fps", "FPS"], ["slow_frames_percent", "Slow %"],
  ["build_ms_median", "Build p50"], ["build_ms_p90", "Build p90"],
  ["raster_ms_median", "Raster p50"], ["raster_ms_p90", "Raster p90"],
  ["gaps_over_25ms", "Gaps >25ms"], ["worst_gap_ms", "Worst gap"],
];

function change(key: string, value: number, before: number) {
  const difference = value - before;
  const signed = (text: string) => `${difference >= 0 ? "+" : ""}${text}`;
  if (key === "fps") return signed(difference.toFixed(1)) + (difference < -FPS_DROP ? " <<" : "");
  if (key === "slow_frames_percent") return signed(`${difference.toFixed(1)}pt`) + (difference > SLOW_RISE ? " <<" : "");
  if (key === "gaps_over_25ms") return signed(String(difference));
  // Frame times vary between runs, so their changes are shown, not marked.
  return percentChange(value, before);
}

function printTable(scenarios: Record<string, Summary>, previous?: Record<string, Summary>) {
  const rows = [["Scenario", ...COLUMNS.map(([, header]) => header)]];
  for (const [name, summary] of Object.entries(scenarios)) {
    rows.push([name, ...COLUMNS.map(([key]) => key.endsWith("_ms") || key.includes("_ms_")
      ? summary[key].toFixed(1) : String(summary[key]))]);
    const before = previous?.[name];
    if (before) rows.push(["  change", ...COLUMNS.map(([key]) => change(key, summary[key], before[key]))]);
  }
  printRows(rows);
  console.log("Times are in ms. Slow % counts frames whose build or raster took longer than one display refresh.");
  if (previous) console.log(`<< marks fps down by more than ${FPS_DROP} or slow frames up by more than ${SLOW_RISE} points.`);
}

async function main() {
  const started = performance.now();
  let ssh: string;
  try { ssh = git("config", "--get", "relay.macSSH"); }
  catch { throw new Error("Set relay.macSSH in local git config (see flutter/README.md)."); }
  const remote = (await mac(ssh, "mktemp -d /tmp/relay-perf-ui.XXXXXXXX")).trim();
  if (!/^\/tmp\/relay-perf-ui\.[A-Za-z0-9]+$/.test(remote)) throw new Error(`Unexpected Mac folder: ${remote}`);
  let cleaning: Promise<unknown> | undefined;
  const cleanup = () => cleaning ??= mac(ssh, cleanupScript(remote)).catch((error) =>
    console.error(`Cleanup on the Mac failed; remove ${remote} and the ${BUNDLE_ID} data by hand.\n${error.message}`));
  process.once("SIGINT", () => void cleanup().finally(() => process.exit(130)));
  try {
    // This checkout's Flutter source, including uncommitted edits.
    const files = execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "flutter"],
      { cwd: root, encoding: "utf8" }).split("\0").filter((path) => path && existsSync(join(root, path)));
    const source = execFileSync("tar", ["--null", "-T", "-", "-czf", "-"],
      { cwd: root, input: files.join("\0"), maxBuffer: 512 * 1024 * 1024 });
    await mac(ssh, `tar -xzf - -C '${remote}'`, source);
    const [model, macos] = (await mac(ssh, "sysctl -n hw.model; sw_vers -productVersion")).trim().split("\n");
    console.log(`Building and running the suite on the Mac (${model}). Leave the Mac alone for about 3 minutes...`);
    await mac(ssh, runScript(remote));
    const report = JSON.parse(await mac(ssh, `cat '${remote}/flutter/build/integration_response_data.json'`));

    const previous = latestResult<Result>(resultsDir, (name) => name.startsWith("ui-"));
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    const result = {
      timestamp, commit: git("rev-parse", "--short", "HEAD"), dirty: git("status", "--porcelain") !== "",
      mac: { model, macos }, seconds: Math.round((performance.now() - started) / 1000), ...report,
    };
    mkdirSync(resultsDir, { recursive: true });
    const file = join(resultsDir, `ui-${timestamp}.json`);
    writeFileSync(file, JSON.stringify(result, null, 2) + "\n");
    console.log(`\n${report.display_hz} Hz display, ${report.window_width} × ${report.window_height} window`);
    if (previous) console.log(`Compared with ${previous.file}`);
    printTable(report.scenarios, previous?.data.scenarios);
    console.log(`\nSaved ${file.slice(root.length + 1)} (${result.seconds} s)`);
  } finally {
    await cleanup();
  }
}

await main();

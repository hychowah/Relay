// Manual UI smoothness review on the Mac: `npm run perf:ui`. Not a test or a
// gate. It runs flutter/integration_test/ui_performance_test.dart from a
// temporary copy of this checkout's flutter/ folder on the Mac, saves the
// result to tmp/perf/ui-<timestamp>.json and compares it with the previous UI run.
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { flutterScript, mac, withMacCopy } from "./mac-flutter.ts";
import { latestResult, printRows } from "./perf-table.ts";

// The test app gets its own bundle id, so it never reads or writes the
// installed app's preferences, WebKit data or saved window position.
const BUNDLE_ID = "app.relay.flutterPerf";
// Marked changes. In four runs of one commit on the MacBook Neo, fps moved by
// up to 3 (one 100 ms hitch among 190 frames) and slow frames by up to 1.1 points.
const FPS_DROP = 5;
const SLOW_RISE = 3;

const root = resolve(import.meta.dirname, "..");
const resultsDir = join(root, "tmp", "perf");
const git = (...args: string[]) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();

type Summary = Record<string, number>;
type Result = { scenarios: Record<string, Summary> };

const runScript = (remote: string) => `${flutterScript(remote, BUNDLE_ID)}flutter drive --profile -d macos --driver=test_driver/integration_test.dart \\
  --target=integration_test/ui_performance_test.dart`;

const COLUMNS: Array<[key: string, header: string]> = [
  ["frames", "Frames"], ["fps", "FPS"], ["slow_frames_percent", "Slow %"],
  ["gaps_over_25ms", "Waits >25 ms"], ["worst_gap_ms", "Worst wait (ms)"],
];

// Each cell shows this run's value with the previous run's in brackets. Times
// vary between runs, so only a clear fall in fps or rise in slow frames is marked.
function cell(key: string, value: number, before?: number) {
  const text = (n: number) => key === "frames" || key === "gaps_over_25ms" ? String(n) : n.toFixed(1);
  if (before === undefined) return text(value);
  const marked = key === "fps" ? before - value > FPS_DROP : key === "slow_frames_percent" && value - before > SLOW_RISE;
  return `${text(value)} (${text(before)})${marked ? " <<" : ""}`;
}

function printTable(scenarios: Record<string, Summary>, previous?: Record<string, Summary>) {
  printRows([
    ["Scenario", ...COLUMNS.map(([, header]) => header)],
    ...Object.entries(scenarios).map(([name, summary]) =>
      [name, ...COLUMNS.map(([key]) => cell(key, summary[key], previous?.[name]?.[key]))]),
  ]);
  console.log("Slow %: frames whose build or raster took longer than one display refresh. "
    + "Waits: gaps between frames while something moves.");
  if (previous) console.log(`(Previous run.) << marks fps down by more than ${FPS_DROP} or slow % up by more than ${SLOW_RISE} points.`);
}

async function main() {
  const started = performance.now();
  await withMacCopy(root, BUNDLE_ID, async (ssh, remote) => {
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
  });
}

await main();

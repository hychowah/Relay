// Real-app memory reading: `npm run perf:mem`. Reads, over SSH, the memory of
// the installed Mac app and of the WebKit processes started for it, appends
// the reading to tmp/perf/mem.jsonl and prints the recent readings, so growth
// over a day of use shows. It only reads the process list and memory figures.
import { execFileSync } from "node:child_process";
import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { printRows } from "./perf-table.ts";

const INSTALLED_BUNDLE_ID = "app.relay.flutterExperiment";
const SHOWN = 12;

const root = resolve(import.meta.dirname, "..");
const log = join(root, "tmp", "perf", "mem.jsonl");

// WebKit's processes run as XPC services in the app's own launchd domain;
// `launchctl print pid/<pid>` lists them without root. `footprint` gives each
// process's physical footprint, the figure Activity Monitor shows as Memory.
const script = `pid=$(lsappinfo info -only pid ${INSTALLED_BUNDLE_ID} | sed -n 's/^"pid"=//p')
[ -n "$pid" ] || exit 0
ps -o etime= -p "$pid"
set -- -p "$pid"
for id in $(launchctl print "pid/$pid" | awk '$3 ~ /^com\\.apple\\.WebKit\\./ && $1 > 0 { print $1 }'); do
  set -- "$@" -p "$id"
done
footprint -f bytes --noCategories "$@" | grep ' Footprint: '
sysctl -n vm.swapusage`;

type Reading = {
  at: string; pid: number; runningHours: number; appMb: number; webKitMb: number;
  webContent: number; largestPageMb: number; swapUsedMb: number;
};

/** Hours from ps's elapsed time, [[dd-]hh:]mm:ss. */
function hours(etime: string) {
  const [days, clock] = etime.includes("-") ? etime.split("-") : ["0", etime];
  const [s = 0, m = 0, h = 0] = clock.split(":").map(Number).reverse();
  return Number(days) * 24 + h + m / 60 + s / 3600;
}

function read(): Reading | undefined {
  let ssh: string;
  try { ssh = execFileSync("git", ["config", "--get", "relay.macSSH"], { cwd: root, encoding: "utf8" }).trim(); }
  catch { throw new Error("Set relay.macSSH in local git config (see flutter/README.md)."); }
  const output = execFileSync(ssh, ["/bin/sh -s"], { input: script, encoding: "utf8" }).trim();
  if (!output) return undefined;
  const [etime, ...rest] = output.split("\n");
  const reading: Reading = {
    at: new Date().toISOString(), pid: 0, runningHours: hours(etime.trim()), appMb: 0, webKitMb: 0,
    webContent: 0, largestPageMb: 0, swapUsedMb: Number(/used = ([\d.]+)M/.exec(rest.at(-1) ?? "")?.[1] ?? NaN),
  };
  for (const line of rest) {
    const match = /^(.+) \[(\d+)\]: .*Footprint: (\d+) B/.exec(line);
    if (!match) continue;
    const mb = Number(match[3]) / 2 ** 20;
    if (match[1].startsWith("com.apple.WebKit.")) {
      reading.webKitMb += mb;
      if (match[1].endsWith("WebContent")) {
        reading.webContent++;
        reading.largestPageMb = Math.max(reading.largestPageMb, mb);
      }
    } else {
      reading.pid = Number(match[2]);
      reading.appMb = mb;
    }
  }
  return reading;
}

const reading = read();
if (!reading) {
  console.log("The installed app is not running on the Mac; nothing recorded.");
} else {
  mkdirSync(join(root, "tmp", "perf"), { recursive: true });
  appendFileSync(log, JSON.stringify(reading) + "\n");
}
let readings: Reading[] = [];
try { readings = readFileSync(log, "utf8").trim().split("\n").map((line) => JSON.parse(line)); }
catch { /* no log yet */ }
const mb = (n: number) => n.toFixed(0);
printRows([
  ["Time", "App up (h)", "Flutter", "WebKit", "Total", "Web processes", "Largest page", "Mac swap used"],
  ...readings.slice(-SHOWN).map((r) => [
    new Date(r.at).toLocaleString("en-GB", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }),
    r.runningHours.toFixed(1), mb(r.appMb), mb(r.webKitMb), mb(r.appMb + r.webKitMb),
    String(r.webContent), mb(r.largestPageMb), `${(r.swapUsedMb / 1024).toFixed(1)} GB`,
  ]),
]);
console.log(`Memory in MB (physical footprint) of the installed app and its WebKit processes. Log: ${log.slice(root.length + 1)}`);

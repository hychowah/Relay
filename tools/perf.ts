// Manual performance review: `npm run perf [-- --skip-build]`. Not a test or a
// gate; it prints numbers, saves them to tmp/perf/ and compares with the last run.
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { availableParallelism, loadavg, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { gzipSync } from "node:zlib";
import { randomUUID } from "node:crypto";
import { Store } from "../server/store.ts";
import type { Run, Snapshot } from "../shared/types.ts";
import { latestResult, printRows } from "./perf-table.ts";

const SEED = {
  conversations: 200,
  messagesPerConversation: 20,
  bigConversationMessages: 2000,
  trashed: 20,
  bots: 5,
  memories: 300,
};
const READ_REPEATS = 30;
const ROUND_TRIPS = 5;
const LARGER = 0.2;

const root = resolve(import.meta.dirname, "..");
const resultsDir = join(root, "tmp", "perf");
const skipBuild = process.argv.includes("--skip-build");

type Metric = { value: number; unit: "ms" | "B" | "MB" };
type Metrics = Record<string, Metric>;
const metrics: Metrics = {};
const ms = (value: number): Metric => ({ value: round(value), unit: "ms" });
const round = (value: number) => Math.round(value * 100) / 100;

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];

async function repeat(name: string, times: number, action: () => unknown | Promise<unknown>) {
  await action(); // warm-up
  const samples: number[] = [];
  for (let i = 0; i < times; i++) {
    const start = performance.now();
    await action();
    samples.push(performance.now() - start);
  }
  metrics[`${name} median`] = ms(median(samples));
}

// Synthetic text with a few searchable words spread through it.
const words = ["harbour", "lantern", "orchard", "granite", "meadow", "copper", "willow", "saffron"];
const sentence = (i: number) =>
  `Message ${i} about the ${words[i % words.length]} and the ${words[(i * 3) % words.length]} plan. ` +
  "Synthetic filler text that stands in for an ordinary conversation turn. ".repeat(1 + (i % 4));

function seed(dataDir: string) {
  const store = new Store(join(dataDir, "relay.sqlite"));
  try {
    const bots = Array.from({ length: SEED.bots }, (_, i) =>
      store.saveBot({ name: `Bot ${i}`, objective: `Synthetic bot ${i}.`, scope: "Synthetic data.", appIds: [] }));
    for (let c = 0; c < SEED.conversations; c++) {
      const conversation = store.createConversation(`Conversation ${c} ${words[c % words.length]}`,
        `perf-session-${c}`, c % 4 === 0 ? bots[c % SEED.bots].id : null);
      for (let m = 0; m < SEED.messagesPerConversation; m++)
        store.message(conversation.id, {
          id: randomUUID(), role: m % 2 ? "assistant" : "user", text: sentence(c * 100 + m),
          createdAt: new Date().toISOString(),
        });
      if (c < SEED.trashed) store.trashConversation(conversation.id);
    }
    for (let i = 0; i < SEED.memories; i++)
      store.saveMemory({ key: `memory ${i}`, content: sentence(i), botId: i % 3 === 0 ? bots[i % SEED.bots].id : null });
    const big = store.createConversation("Big conversation", "perf-session-big");
    for (let m = 0; m < SEED.bigConversationMessages; m++)
      store.message(big.id, {
        id: randomUUID(), role: m % 2 ? "assistant" : "user", text: sentence(m), createdAt: new Date().toISOString(),
      });
    return big.id;
  } finally {
    store.close();
  }
}

async function freePort() {
  const server = createServer();
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  const { port } = server.address() as AddressInfo;
  await new Promise((done) => server.close(done));
  return port;
}

function startServer(dataDir: string, port: number) {
  // Explicit environment: no .env, so no provider keys reach the child.
  return spawn(process.execPath, ["server/index.ts"], {
    cwd: root,
    env: {
      PATH: process.env.PATH, HOME: dataDir, RELAY_DATA_DIR: dataDir, RELAY_PROVIDER: "fixture",
      RELAY_HOST: "127.0.0.1", PORT: String(port), RELAY_VPN_CHECK: "off",
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
}

async function stopServer(child: ChildProcess) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise((done) => child.once("exit", done));
  child.kill("SIGTERM"); // lets the server close its OpenCode child
  const timer = setTimeout(() => child.kill("SIGKILL"), 10_000);
  await exited;
  clearTimeout(timer);
}

async function measureHttp(base: string, bigId: string, child: ChildProcess) {
  const get = async (path: string) => {
    const response = await fetch(base + path);
    const body = await response.arrayBuffer();
    if (!response.ok) throw new Error(`GET ${path}: ${response.status} ${new TextDecoder().decode(body)}`);
    return body.byteLength;
  };
  const reads: Array<[string, string]> = [
    ["GET /api/conversations", "/api/conversations"],
    ["GET /api/conversations?q=", "/api/conversations?q=saffron"],
    ["GET /api/conversations?q= miss", "/api/conversations?q=zeppelin"],
    ["GET /api/conversations/:big", `/api/conversations/${bigId}`],
    ["GET /api/memories", "/api/memories"],
    ["GET /api/trash", "/api/trash"],
    ["GET /api/bots", "/api/bots"],
  ];
  for (const [name, path] of reads) {
    await repeat(name, READ_REPEATS, () => get(path));
    metrics[`${name} size`] = { value: await get(path), unit: "B" };
  }

  const post = async <T>(path: string, body: unknown) => {
    const response = await fetch(base + path, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    if (!response.ok) throw new Error(`POST ${path}: ${response.status} ${await response.text()}`);
    return response.json() as Promise<T>;
  };
  const roundTrip = async () => {
    const conversation = await post<{ id: string }>("/api/conversations", { title: "Perf round trip" });
    const sent = performance.now();
    const run = await post<Run>(`/api/conversations/${conversation.id}/messages`,
      { text: "Hello", deviceId: "perf-device", tabId: "perf-tab" });
    for (;;) {
      const snapshot: Snapshot = await (await fetch(`${base}/api/conversations/${conversation.id}`)).json();
      const status = snapshot.runs.find((item) => item.id === run.id)?.status;
      if (status && status !== "running") {
        if (status !== "completed") throw new Error(`Round trip run ended ${status}`);
        return performance.now() - sent;
      }
      await new Promise((done) => setTimeout(done, 10));
    }
  };
  // The server polls the harness every 400 ms (server/app.ts), so this moves in
  // roughly 400 ms steps and shows only large slowdowns.
  await roundTrip();
  const replies: number[] = [];
  for (let i = 0; i < ROUND_TRIPS; i++) replies.push(await roundTrip());
  metrics["Round trip plain reply median"] = ms(median(replies));

  const status = readFileSync(`/proc/${child.pid}/status`, "utf8");
  const kb = (field: string) => Number(status.match(new RegExp(`^${field}:\\s+(\\d+) kB`, "m"))?.[1]);
  metrics["Server peak RSS"] = { value: round(kb("VmHWM") / 1024), unit: "MB" };
}

function measureBuild(outDir: string) {
  execFileSync(join(root, "node_modules", ".bin", "vite"), ["build", "--outDir", outDir, "--emptyOutDir", "--logLevel", "error"],
    { cwd: root, stdio: ["ignore", "ignore", "inherit"] });
  for (const extension of ["js", "css"]) {
    let raw = 0, gzip = 0;
    for (const file of readdirSync(join(outDir, "assets")).filter((name) => name.endsWith(`.${extension}`))) {
      const content = readFileSync(join(outDir, "assets", file));
      raw += content.byteLength;
      gzip += gzipSync(content).byteLength;
    }
    metrics[`Web ${extension.toUpperCase()} size`] = { value: raw, unit: "B" };
    metrics[`Web ${extension.toUpperCase()} gzip size`] = { value: gzip, unit: "B" };
  }
}

type Load = { start: number[]; end: number[]; cpus: number };
const busy = (load: Load) => Math.max(load.start[0], load.end[0]) > load.cpus / 2;
const describeLoad = (load: Load) =>
  `1-min load ${load.start[0].toFixed(1)} at start, ${load.end[0].toFixed(1)} at end, ${load.cpus} CPUs`;

function previousRun(): { file: string; metrics: Metrics; load?: Load } | undefined {
  // Server runs are named by their timestamp; UI runs (`ui-...`) sit beside them.
  const previous = latestResult<{ metrics: Metrics; load?: Load }>(resultsDir, (name) => /^\d/.test(name));
  return previous && { file: previous.file, ...previous.data };
}

function format({ value, unit }: Metric) {
  if (unit === "B") return value >= 1024 ? `${(value / 1024).toFixed(1)} KB` : `${value} B`;
  return `${value.toFixed(unit === "MB" ? 1 : 2)} ${unit}`;
}

function printTable(previous: Metrics | undefined) {
  const rows = Object.entries(metrics).map(([name, metric]) => {
    const before = previous?.[name];
    if (!before) return [name, format(metric), "", ""];
    const change = before.value ? (metric.value - before.value) / before.value : 0;
    // Timings vary by tens of percent between quiet runs of the same commit, so only sizes are marked.
    const flag = metric.unit !== "ms" && change > LARGER ? "  << worse" : "";
    return [name, format(metric), format(before), `${change >= 0 ? "+" : ""}${(change * 100).toFixed(0)}%${flag}`];
  });
  const header = previous ? ["Metric", "This run", "Previous", "Change"] : ["Metric", "This run"];
  printRows([header, ...rows.map((row) => row.slice(0, header.length))]);
}

async function main() {
  const started = performance.now();
  const startLoad = loadavg();
  const work = mkdtempSync(join(tmpdir(), "relay-perf-"));
  let child: ChildProcess | undefined;
  let cleaning: Promise<void> | undefined;
  const cleanup = () => cleaning ??= (async () => {
    if (child) await stopServer(child);
    rmSync(work, { recursive: true, force: true });
  })();
  process.once("SIGINT", () => void cleanup().finally(() => process.exit(130)));
  try {
    const dataDir = join(work, "data");
    console.log("Seeding synthetic data...");
    const bigId = seed(dataDir);
    const port = await freePort();
    const base = `http://127.0.0.1:${port}`;
    console.log("Starting the server...");
    const start = performance.now();
    child = startServer(dataDir, port);
    let stderr = "";
    child.stderr!.on("data", (chunk) => { stderr += chunk; });
    for (;;) {
      if (child.exitCode !== null) throw new Error(`Server exited during startup:\n${stderr}`);
      try { if ((await fetch(`${base}/api/config`)).ok) break; } catch {}
      if (performance.now() - start > 60_000) throw new Error(`Server did not start:\n${stderr}`);
      await new Promise((done) => setTimeout(done, 20));
    }
    metrics["Server startup"] = ms(performance.now() - start);
    console.log("Measuring HTTP reads and round trips...");
    await measureHttp(base, bigId, child);
    await stopServer(child);

    if (!skipBuild) {
      console.log("Building the web client...");
      measureBuild(join(work, "web-build"));
    }

    const git = (...args: string[]) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
    const load: Load = { start: startLoad, end: loadavg(), cpus: availableParallelism() };
    const previous = previousRun();
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    const result = {
      timestamp, commit: git("rev-parse", "--short", "HEAD"), dirty: git("status", "--porcelain") !== "",
      node: process.version, platform: `${process.platform}-${process.arch}`, load, seed: SEED,
      readRepeats: READ_REPEATS, roundTrips: ROUND_TRIPS, skipBuild, metrics,
    };
    mkdirSync(resultsDir, { recursive: true });
    const file = join(resultsDir, `${timestamp}.json`);
    writeFileSync(file, JSON.stringify(result, null, 2) + "\n");
    console.log();
    if (busy(load)) console.log(`Warning: the machine was busy (${describeLoad(load)}); timings are unreliable, repeat on a quiet machine.`);
    if (previous) console.log(`Compared with ${previous.file}${previous.load ? ` (${describeLoad(previous.load)})` : ""}`);
    printTable(previous?.metrics);
    console.log(`\nSaved ${file.slice(root.length + 1)} (${((performance.now() - started) / 1000).toFixed(0)} s)`);
  } finally {
    await cleanup();
  }
}

await main();

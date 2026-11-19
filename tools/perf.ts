// Manual performance review: `npm run perf [-- --skip-build]`. Not a test or a
// gate; it prints numbers, saves them to tmp/perf/ and compares with the last run.
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { gzipSync } from "node:zlib";
import { randomUUID } from "node:crypto";
import { Store } from "../server/store.ts";
import type { Run, Snapshot } from "../shared/types.ts";

const SEED = {
  conversations: 200,
  messagesPerConversation: 20,
  bigConversationMessages: 2000,
  trashed: 20,
  bots: 5,
  memories: 300,
  appResources: 50,
};
const READ_REPEATS = 30;
const ROUND_TRIPS = 5;
const SLOWER = 0.2;

const root = resolve(import.meta.dirname, "..");
const resultsDir = join(root, "tmp", "perf");
const skipBuild = process.argv.includes("--skip-build");

type Metric = { value: number; unit: "ms" | "B" | "MB" };
type Metrics = Record<string, Metric>;
const metrics: Metrics = {};
const ms = (value: number): Metric => ({ value: round(value), unit: "ms" });
const round = (value: number) => Math.round(value * 100) / 100;

function percentile(values: number[], p: number) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1)];
}

async function repeat(name: string, times: number, action: () => unknown | Promise<unknown>) {
  await action(); // warm-up
  const samples: number[] = [];
  for (let i = 0; i < times; i++) {
    const start = performance.now();
    await action();
    samples.push(performance.now() - start);
  }
  metrics[`${name} median`] = ms(percentile(samples, 0.5));
  metrics[`${name} p95`] = ms(percentile(samples, 0.95));
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
    const start = performance.now();
    for (let m = 0; m < SEED.bigConversationMessages; m++)
      store.message(big.id, {
        id: randomUUID(), role: m % 2 ? "assistant" : "user", text: sentence(m), createdAt: new Date().toISOString(),
      });
    metrics[`Store.message x${SEED.bigConversationMessages} total`] = ms(performance.now() - start);
    const requester = store.createConversation("Requester", "perf-session-requester");
    return { store, bigId: big.id, requesterId: requester.id };
  } catch (error) {
    store.close();
    throw error;
  }
}

async function measureStore(store: Store, bigId: string, requesterId: string) {
  await repeat("Store.searchHistory hit", READ_REPEATS, () => store.searchHistory(requesterId, "saffron"));
  await repeat("Store.searchHistory miss", READ_REPEATS, () => store.searchHistory(requesterId, "zeppelin"));
  await repeat("Store.readHistory first page", READ_REPEATS, () => store.readHistory(requesterId, bigId, 0, 50));
  await repeat("Store.readHistory last page", READ_REPEATS, () =>
    store.readHistory(requesterId, bigId, SEED.bigConversationMessages - 50, 50));
}

// A tiny app speaking the Relay v1 protocol, like nativeFixture in tests/http-integration.test.ts.
async function startFixtureApp() {
  const server = createServer((request, response) => {
    const url = new URL(request.url!, "http://fixture");
    const json = (body: unknown, status = 200) =>
      response.writeHead(status, { "Content-Type": "application/json" }).end(JSON.stringify(body));
    if (url.pathname === "/_relay/manifest")
      json({
        version: 1, id: "perf-app", name: "Perf app", description: "Synthetic records",
        capabilities: { search: true, read: true, navigate: true },
        view: { path: "/_relay/view", resourceId: "record-0" },
      });
    else if (url.pathname === "/_relay/search") {
      const q = url.searchParams.get("q") ?? "";
      const count = q.includes("nomatch") ? 0 : SEED.appResources;
      json({
        resources: Array.from({ length: count }, (_, i) => ({
          appId: "perf-app", resourceId: `record-${i}`, title: `Record ${i} ${q}`, sourceUrl: `/records/${i}`,
        })),
      });
    } else json({ error: "Not found" }, 404);
  });
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  return { server, origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}` };
}

async function freePort() {
  const server = createServer();
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  const { port } = server.address() as AddressInfo;
  await new Promise((done) => server.close(done));
  return port;
}

function startServer(dataDir: string, appsFile: string, port: number) {
  // Explicit environment: no .env, so no provider keys reach the child.
  return spawn(process.execPath, ["server/index.ts"], {
    cwd: root,
    env: {
      PATH: process.env.PATH, HOME: dataDir, RELAY_DATA_DIR: dataDir, RELAY_PROVIDER: "fixture",
      RELAY_APPS_FILE: appsFile, RELAY_HOST: "127.0.0.1", PORT: String(port), RELAY_VPN_CHECK: "off",
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
    ["GET /api/apps/:id/search", "/api/apps/perf-app/search?q=record"],
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
  const roundTrip = async (text: string, tool?: string) => {
    const created = performance.now();
    const conversation = await post<{ id: string }>("/api/conversations", { title: "Perf round trip" });
    const sent = performance.now();
    const run = await post<Run>(`/api/conversations/${conversation.id}/messages`,
      { text, deviceId: "perf-device", tabId: "perf-tab" });
    for (;;) {
      const snapshot: Snapshot = await (await fetch(`${base}/api/conversations/${conversation.id}`)).json();
      const status = snapshot.runs.find((item) => item.id === run.id)?.status;
      if (status && status !== "running") {
        if (status !== "completed") throw new Error(`Round trip run ended ${status}`);
        if (tool && !snapshot.tools.some((item) => item.name === tool)) throw new Error(`Round trip did not call ${tool}`);
        return { create: sent - created, reply: performance.now() - sent };
      }
      await new Promise((done) => setTimeout(done, 10));
    }
  };
  for (const [name, text, tool] of [["plain reply", "Hello"], ["app_search tool reply", "Find: nomatch", "app_search"]]) {
    await roundTrip(text, tool);
    const creates: number[] = [], replies: number[] = [];
    for (let i = 0; i < ROUND_TRIPS; i++) {
      const { create, reply } = await roundTrip(text, tool);
      creates.push(create);
      replies.push(reply);
    }
    if (name === "plain reply") metrics["POST /api/conversations median"] = ms(percentile(creates, 0.5));
    metrics[`Round trip ${name} median`] = ms(percentile(replies, 0.5));
    metrics[`Round trip ${name} p95`] = ms(percentile(replies, 0.95));
  }

  // Replies include up to one 400 ms wait in the server's harness polling loop (server/app.ts).
  const status = readFileSync(`/proc/${child.pid}/status`, "utf8");
  const kb = (field: string) => Number(status.match(new RegExp(`^${field}:\\s+(\\d+) kB`, "m"))?.[1]);
  metrics["Server RSS after load"] = { value: round(kb("VmRSS") / 1024), unit: "MB" };
  metrics["Server peak RSS"] = { value: round(kb("VmHWM") / 1024), unit: "MB" };
}

function measureBuild(outDir: string) {
  const start = performance.now();
  execFileSync(join(root, "node_modules", ".bin", "vite"), ["build", "--outDir", outDir, "--emptyOutDir", "--logLevel", "error"],
    { cwd: root, stdio: ["ignore", "ignore", "inherit"] });
  metrics["Web build time"] = ms(performance.now() - start);
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

function previousRun(): { file: string; metrics: Metrics } | undefined {
  let files: string[] = [];
  try { files = readdirSync(resultsDir).filter((name) => name.endsWith(".json")).sort(); }
  catch { return undefined; }
  const file = files.at(-1);
  return file ? { file, metrics: JSON.parse(readFileSync(join(resultsDir, file), "utf8")).metrics } : undefined;
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
    // Sub-millisecond timings jitter by more than 20%; flag only differences that matter.
    const flag = change > SLOWER && !(metric.unit === "ms" && metric.value - before.value < 1) ? "  << worse" : "";
    return [name, format(metric), format(before), `${change >= 0 ? "+" : ""}${(change * 100).toFixed(0)}%${flag}`];
  });
  const header = previous ? ["Metric", "This run", "Previous", "Change"] : ["Metric", "This run"];
  const table = [header, ...rows.map((row) => row.slice(0, header.length))];
  const widths = header.map((_, i) => Math.max(...table.map((row) => row[i].length)));
  for (const row of table) console.log(row.map((cell, i) => i === 0 ? cell.padEnd(widths[i]) : cell.padStart(widths[i])).join("  ").trimEnd());
}

async function main() {
  const started = performance.now();
  const work = mkdtempSync(join(tmpdir(), "relay-perf-"));
  let child: ChildProcess | undefined;
  let app: Server | undefined;
  let cleaning: Promise<void> | undefined;
  const cleanup = () => cleaning ??= (async () => {
    if (child) await stopServer(child);
    app?.closeAllConnections();
    app?.close();
    rmSync(work, { recursive: true, force: true });
  })();
  process.once("SIGINT", () => void cleanup().finally(() => process.exit(130)));
  try {
    const dataDir = join(work, "data");
    console.log("Seeding synthetic data...");
    const { store, bigId, requesterId } = seed(dataDir);
    try { await measureStore(store, bigId, requesterId); }
    finally { store.close(); }

    const fixture = await startFixtureApp();
    app = fixture.server;
    const appsFile = join(work, "apps.json");
    writeFileSync(appsFile, JSON.stringify([{ id: "perf-app", name: "Perf app", serverUrl: fixture.origin }]));
    const port = await freePort();
    const base = `http://127.0.0.1:${port}`;
    console.log("Starting the server...");
    const start = performance.now();
    child = startServer(dataDir, appsFile, port);
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
    const previous = previousRun();
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
    const result = {
      timestamp, commit: git("rev-parse", "--short", "HEAD"), dirty: git("status", "--porcelain") !== "",
      node: process.version, platform: `${process.platform}-${process.arch}`, seed: SEED,
      readRepeats: READ_REPEATS, roundTrips: ROUND_TRIPS, skipBuild, metrics,
    };
    mkdirSync(resultsDir, { recursive: true });
    const file = join(resultsDir, `${timestamp}.json`);
    writeFileSync(file, JSON.stringify(result, null, 2) + "\n");
    console.log();
    if (previous) console.log(`Compared with ${previous.file}`);
    printTable(previous?.metrics);
    console.log(`\nSaved ${file.slice(root.length + 1)} (${((performance.now() - started) / 1000).toFixed(0)} s)`);
  } finally {
    await cleanup();
  }
}

await main();

import test, { type TestContext } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Hono } from "hono";
import { createWorkspace, type AgentHarness } from "../server/app.ts";
import { createFiles } from "../server/files.ts";
import { Store } from "../server/store.ts";

/** A PDF with one line of Helvetica text per page. */
function pdf(pages: string[]) {
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    `<< /Type /Pages /Kids [${pages.map((_, i) => `${4 + i * 2} 0 R`).join(" ")}] /Count ${pages.length} >>`,
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  ];
  pages.forEach((line, i) => {
    const stream = `BT /F1 12 Tf 72 720 Td (${line}) Tj ET`;
    objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + i * 2} 0 R >>`,
      `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
  });
  let out = "%PDF-1.4\n";
  const offsets = objects.map((body, i) => {
    const at = out.length;
    out += `${i + 1} 0 obj\n${body}\nendobj\n`;
    return at;
  });
  const xref = out.length;
  out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.map((at) => `${String(at).padStart(10, "0")} 00000 n \n`).join("")}`;
  return out + `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
}

// "zebra" appears only where the agent must not look.
const long = "Ünïcødé line with € and 日本語 text.\n".repeat(1500);
function fixture(t: TestContext) {
  const base = mkdtempSync(join(tmpdir(), "relay-files-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const shared = join(base, "shared");
  const write = (path: string, content: string | Buffer) => {
    mkdirSync(join(path, ".."), { recursive: true });
    writeFileSync(path, content);
  };
  write(join(shared, "notes.md"), "# Notes\nThe quarterly budget review is on Friday.\n");
  write(join(shared, "long.txt"), long);
  write(join(shared, "data", "report.csv"), "item,cost\nlamp,40\n");
  write(join(shared, "sub", "deep", "plan.txt"), "Plan for the move.\n");
  write(join(shared, "paper.pdf"), pdf(["Photosynthesis in leaves", "Second page about chlorophyll"]));
  write(join(shared, "image.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]));
  write(join(shared, ".env"), "TOKEN=zebra\n");
  write(join(shared, ".git", "config"), "zebra\n");
  write(join(shared, "old-relay", "relay.sqlite"), "");
  write(join(shared, "old-relay", "chat.txt"), "zebra\n");
  write(join(base, "outside", "secret.txt"), "zebra\n");
  symlinkSync(join(base, "outside"), join(shared, "escape"));
  symlinkSync(join(shared, "data"), join(shared, "linked-data"));
  // The service's own data directory, inside the shared folder.
  const dataDir = join(shared, "relay-data");
  write(join(dataDir, "provider.json"), "{\"zebra\":true}\n");
  const files = createFiles(dataDir, {});
  const server = new Hono();
  files.addRoutes(server, ["relay.test:3250"]);
  const request = (method: string, path: string, body?: unknown, host = "relay.test:3250") => server.request(path, {
    method, headers: { "Content-Type": "application/json", Host: host }, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const call = async (operation: string, args: Record<string, unknown>) =>
    (await files.app.integration.call!(operation, args, {})).data as Record<string, any>;
  const failure = (operation: string, args: Record<string, unknown>) =>
    call(operation, args).then(() => assert.fail("expected a refusal"), (error: Error) => error.message);
  return { base, shared, dataDir, files, request, call, failure };
}

test("shared folders are added as existing absolute folders, kept on disk, removed, and changed only through Relay's own address", async (t) => {
  const f = fixture(t);
  for (const path of ["shared", join(f.base, "missing"), join(f.shared, "notes.md"), f.dataDir, join(f.shared, "old-relay")])
    assert.equal((await f.request("POST", "/api/settings/folders", { path })).status, 400, path);
  assert.equal((await f.request("POST", "/api/settings/folders", { path: f.shared + "/" })).status, 200);
  assert.deepEqual(await (await f.request("GET", "/api/settings/folders")).json(), { folders: [f.shared] });
  assert.deepEqual(await createFiles(f.dataDir, {}).app.integration.call!("files.list", {}, {}), { data: { folders: [f.shared] } });
  const removed = await f.request("DELETE", `/api/settings/folders?path=${encodeURIComponent(f.shared)}`);
  assert.deepEqual(await removed.json(), { folders: [] });
  // A page rebound to Relay's address (DNS rebinding) sends its own Host.
  for (const [method, path, body] of [["GET", "/api/settings/folders"], ["POST", "/api/settings/folders", { path: f.shared }],
    ["DELETE", `/api/settings/folders?path=${encodeURIComponent(f.shared)}`]] as const)
    assert.equal((await f.request(method, path, body, "evil.test:3250")).status, 403, method);
  assert.deepEqual(await (await f.request("GET", "/api/settings/folders")).json(), { folders: [] });
});

test("listing, search and reading stay inside shared folders and skip hidden names and Relay's records", async (t) => {
  const f = fixture(t);
  await f.request("POST", "/api/settings/folders", { path: f.shared });

  const listed = await f.call("files.list", { path: f.shared });
  assert.deepEqual(listed.entries.map((entry: { name: string }) => entry.name),
    ["data", "image.png", "linked-data", "long.txt", "notes.md", "old-relay", "paper.pdf", "sub"]);
  assert.deepEqual(listed.entries.find((entry: { name: string }) => entry.name === "image.png"),
    { name: "image.png", path: join(f.shared, "image.png"), kind: "file", size: 8, readable: false });
  assert.match(await f.failure("files.list", { path: join(f.shared, "old-relay") }), /Relay's own records/);

  assert.deepEqual((await f.call("files.search", { query: "PLAN" })).matches, [{ path: join(f.shared, "sub", "deep", "plan.txt"), match: "name" }]);
  const budget = (await f.call("files.search", { query: "budget quarterly" })).matches;
  assert.equal(budget.length, 1);
  assert.equal(budget[0].path, join(f.shared, "notes.md"));
  assert.match(budget[0].snippet, /quarterly budget review/);
  assert.deepEqual((await f.call("files.search", { query: "chlorophyll" })).matches.map((match: { path: string }) => match.path),
    [join(f.shared, "paper.pdf")]);
  assert.deepEqual((await f.call("files.search", { query: "zebra" })).matches, []);

  assert.match((await f.call("files.read", { path: join(f.shared, "notes.md") })).text, /quarterly budget/);
  const paper = await f.call("files.read", { path: join(f.shared, "paper.pdf") });
  assert.equal(paper.pages, 2);
  assert.match(paper.text, /\[Page 1\]\nPhotosynthesis in leaves[\s\S]*\[Page 2\]\nSecond page about chlorophyll/);
  assert.equal((await f.call("files.read", { path: join(f.shared, "linked-data", "report.csv") })).text, "item,cost\nlamp,40\n");

  for (const path of [join(f.shared, "..", "outside", "secret.txt"), join(f.shared, "escape", "secret.txt"), "/etc/hostname", "notes.md"])
    assert.match(await f.failure("files.read", { path }), /not in a shared folder|absolute path/, path);
  assert.deepEqual((await f.call("files.list", { path: f.shared })).entries.some((entry: { name: string }) => entry.name === "escape"), false);
  for (const path of [join(f.shared, ".env"), join(f.shared, ".git", "config")])
    assert.match(await f.failure("files.read", { path }), /Hidden/);
  for (const path of [join(f.dataDir, "provider.json"), join(f.shared, "old-relay", "chat.txt")])
    assert.match(await f.failure("files.read", { path }), /Relay's own records/);
  assert.match(await f.failure("files.read", { path: join(f.shared, "image.png") }), /listed by name only/);
});

test("a long text file reads in pages that join back without breaking characters", async (t) => {
  const f = fixture(t);
  await f.request("POST", "/api/settings/folders", { path: f.shared });
  let text = "", offset: number | undefined = 0, pages = 0;
  while (offset !== undefined) {
    const page = await f.call("files.read", { path: join(f.shared, "long.txt"), offset });
    text += page.text;
    offset = page.nextOffset;
    pages++;
  }
  assert.ok(pages > 2);
  assert.equal(text, long);
});

test("a search stops at 50 matches and says so", async (t) => {
  const f = fixture(t);
  for (let i = 0; i < 60; i++) writeFileSync(join(f.shared, `match-${i}.txt`), "");
  await f.request("POST", "/api/settings/folders", { path: f.shared });
  const result = await f.call("files.search", { query: "match" });
  assert.equal(result.matches.length, 50);
  assert.match(result.note, /Stopped at 50 matches; there may be more/);
});

test("a bot without the Files app cannot call it; normal chat can", async (t) => {
  const f = fixture(t);
  await f.request("POST", "/api/settings/folders", { path: f.shared });
  const store = new Store(":memory:");
  const notes = { id: "notes", name: "Notes", description: "Synthetic app", integration: {} };
  const workspace = createWorkspace(store, () => [f.files.app, notes], { mode: "fixture", model: "fixture", configured: true });
  let sessions = 0;
  const harness: AgentHarness = {
    async createSession() { return `session-${++sessions}`; },
    async deleteSession() {},
    async prompt() {},
    async inspect() { return { messages: [], status: "running" }; },
    async interrupt() {},
  };
  workspace.setHarness(harness);
  t.after(async () => { await workspace.close(); store.close(); });
  const post = async (path: string, body: unknown) => (await workspace.app.request(path, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  })).json();
  const bot = await post("/api/bots", { name: "Notes only", objective: "Notes", appIds: ["notes"] });
  const listing = { appId: "files", operation: "files.list", arguments: {} };
  for (const [botId, session] of [[bot.id, "session-1"], [undefined, "session-2"]]) {
    const conversation = await post("/api/conversations", { botId });
    await post(`/api/conversations/${conversation.id}/messages`, { text: "What is shared?", deviceId: "d", tabId: "t" });
    const result = await workspace.toolHandler(session, "app_call", listing) as { error?: string; data?: unknown };
    if (botId) assert.match(result.error!, /outside the bot's scope/);
    else assert.deepEqual(result, { data: { folders: [f.shared] } });
  }
  const config = await (await workspace.app.request("/api/config")).json();
  assert.equal(config.apps.find((app: { id: string }) => app.id === "files").hasView, false);
});

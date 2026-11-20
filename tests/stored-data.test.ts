import test from "node:test";
import assert from "node:assert/strict";
import { Hono } from "hono";
import { addBrowserHistory, browserHistoryData } from "../server/browser-history.ts";
import { addHighlights, highlightsData } from "../server/highlights.ts";
import { addStoredData } from "../server/stored-data.ts";
import { Store } from "../server/store.ts";

const day = 24 * 60 * 60 * 1000;

function server() {
  const store = new Store(":memory:");
  const app = new Hono();
  const clock = { time: Date.UTC(2026, 10, 20, 12) };
  addBrowserHistory(app, store, () => clock.time);
  addHighlights(app, store, () => clock.time);
  const clean = addStoredData(app, store, [browserHistoryData(store), highlightsData(store)], () => clock.time);
  const send = (method: string, path: string, body?: unknown) => app.request(path, {
    method, headers: { "Content-Type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return {
    store, clock, clean, send,
    async stored(): Promise<Array<{ id: string; name: string; items: number; bytes: number; autoCleanDays: number | null }>> {
      return (await app.request("/api/stored-data")).json();
    },
    async highlights(url: string): Promise<Array<Record<string, unknown>>> {
      return (await app.request(`/api/highlights?url=${encodeURIComponent(url)}`)).json();
    },
    /** Saves a highlight of [text] made [daysAgo] days ago. */
    async highlight(url: string, id: string, text: string, daysAgo = 0, more: object = {}) {
      clock.time -= daysAgo * day;
      const reply = await send("POST", "/api/highlights", { url, id, text, prefix: "before ", suffix: " after", ...more });
      clock.time += daysAgo * day;
      return reply.status;
    },
  };
}

test("highlights are kept for each page address and found again", async () => {
  const s = server();
  const marks = [[0, 72, 640.5, 300, 12], [0, 72, 626.5, 180, 12]];
  assert.equal(await s.highlight("https://example.com/paper.pdf#page=2", "a", "first passage", 0, { marks }), 204);
  assert.equal(await s.highlight("https://example.com/paper.pdf", "b", "second passage"), 204);
  assert.equal(await s.highlight("https://example.com/other", "c", "elsewhere"), 204);
  assert.deepEqual(await s.highlights("https://example.com/paper.pdf"), [
    { id: "a", text: "first passage", prefix: "before ", suffix: " after", marks },
    { id: "b", text: "second passage", prefix: "before ", suffix: " after" },
  ]);

  assert.equal((await s.send("DELETE", "/api/highlights/a")).status, 204);
  assert.deepEqual((await s.highlights("https://example.com/paper.pdf#top")).map((item) => item.id), ["b"]);
  assert.deepEqual(await s.highlights("file:///etc/hosts"), []);
});

test("a highlight that is not text on a web address is refused", async () => {
  const s = server();
  assert.equal(await s.highlight("file:///etc/hosts", "a", "text"), 400);
  assert.equal(await s.highlight("https://example.com/", "a", ""), 400);
  assert.equal(await s.highlight("https://example.com/", "a", "text", 0, { marks: [[0, 1, 2, "wide", 4]] }), 400);
  assert.equal(await s.highlight("https://example.com/", "a", "text", 0, { marks: [[0, 1, 2]] }), 400);
  assert.deepEqual(await s.highlights("https://example.com/"), []);
});

test("stored data lists each category with its size and clears one", async () => {
  const s = server();
  assert.deepEqual(await s.stored(), [
    { id: "browser-history", name: "Browsing history", description: "Pages visited in Browser tabs, for address bar suggestions.",
      items: 0, bytes: 0, autoCleanDays: 90 },
    { id: "highlights", name: "Highlights", description: "Text you highlighted on web pages and in PDFs.",
      items: 0, bytes: 0, autoCleanDays: null },
  ]);

  await s.send("POST", "/api/browser-history/visit", { url: "https://example.com/", title: "Example" });
  await s.highlight("https://example.com/", "a", "a passage");
  await s.highlight("https://example.com/", "b", "a longer passage of text");
  const [history, highlights] = await s.stored();
  assert.equal(history.items, 1);
  assert.equal(history.bytes, "https://example.com/".length + "Example".length);
  assert.equal(highlights.items, 2);
  assert.ok(highlights.bytes > "a passage".length + "a longer passage of text".length);

  assert.equal((await s.send("DELETE", "/api/stored-data/highlights")).status, 204);
  assert.deepEqual((await s.stored()).map((item) => item.items), [1, 0]);
  assert.equal((await s.send("DELETE", "/api/stored-data/browser-history")).status, 204);
  assert.deepEqual(s.store.browserPages(), []);
  // The installed Stable 0.0.16 still clears the history at its old address.
  await s.send("POST", "/api/browser-history/visit", { url: "https://example.com/" });
  assert.equal((await s.send("DELETE", "/api/browser-history")).status, 204);
  assert.deepEqual(s.store.browserPages(), []);
  assert.equal((await s.send("DELETE", "/api/stored-data/other")).status, 404);
});

test("auto-clean forgets what is older than each category's days", async () => {
  const s = server();
  const visit = async (url: string, daysAgo: number) => {
    s.clock.time -= daysAgo * day;
    await s.send("POST", "/api/browser-history/visit", { url });
    s.clock.time += daysAgo * day;
  };
  await visit("https://stale.example/", 91);
  await visit("https://month.example/", 40);
  await visit("https://week.example/", 5);
  await s.highlight("https://example.com/", "old", "an old passage", 400);
  await s.highlight("https://example.com/", "new", "a new passage", 2);
  const pages = () => s.store.browserPages().map((page) => page.url);

  // Browsing history is kept 90 days until the user chooses; highlights for ever.
  s.clean();
  assert.deepEqual(pages(), ["https://month.example/", "https://week.example/"]);
  assert.equal((await s.highlights("https://example.com/")).length, 2);

  // A period that would delete items now is not saved until the user has
  // agreed to the number; then it applies at once and is remembered.
  const set = async (id: string, body: object) => (await s.send("PUT", `/api/stored-data/${id}`, body)).json();
  assert.deepEqual(await set("browser-history", { autoCleanDays: 30 }), { saved: false, older: 1 });
  assert.deepEqual(pages(), ["https://month.example/", "https://week.example/"]);
  assert.deepEqual((await s.stored()).map((item) => item.autoCleanDays), [90, null]);
  assert.deepEqual(await set("browser-history", { autoCleanDays: 30, deleteOlder: true }), { saved: true, older: 1 });
  assert.deepEqual(pages(), ["https://week.example/"]);
  assert.deepEqual(await set("highlights", { autoCleanDays: 365 }), { saved: false, older: 1 });
  assert.equal((await s.highlights("https://example.com/")).length, 2);
  assert.deepEqual(await set("highlights", { autoCleanDays: 365, deleteOlder: true }), { saved: true, older: 1 });
  assert.deepEqual((await s.highlights("https://example.com/")).map((item) => item.id), ["new"]);
  assert.deepEqual((await s.stored()).map((item) => item.autoCleanDays), [30, 365]);
  // A period that deletes nothing now needs no agreement.
  assert.deepEqual(await set("highlights", { autoCleanDays: 300 }), { saved: true, older: 0 });

  // Turned off, nothing is forgotten however old it gets.
  assert.deepEqual(await set("browser-history", { autoCleanDays: null }), { saved: true, older: 0 });
  s.clock.time += 1000 * day;
  s.clean();
  assert.deepEqual(pages(), ["https://week.example/"]);
  assert.deepEqual((await s.highlights("https://example.com/")), []);

  for (const autoCleanDays of [0, 1.5, "7", 4000]) {
    assert.equal((await s.send("PUT", "/api/stored-data/highlights", { autoCleanDays })).status, 400);
  }
  assert.equal((await s.send("PUT", "/api/stored-data/other", { autoCleanDays: 7 })).status, 404);
});

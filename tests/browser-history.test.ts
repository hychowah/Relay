import test from "node:test";
import assert from "node:assert/strict";
import { Hono } from "hono";
import { addBrowserHistory } from "../server/browser-history.ts";
import { Store } from "../server/store.ts";

const day = 24 * 60 * 60 * 1000;

function history() {
  const store = new Store(":memory:");
  const app = new Hono();
  const clock = { time: Date.UTC(2026, 10, 19, 12) };
  addBrowserHistory(app, store, () => clock.time);
  const post = (kind: string, body: unknown) => app.request(`/api/browser-history/${kind}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  return {
    store, app, clock, post,
    /** Visits [url] [visits] times, [daysAgo] days ago, opening it from the address bar [typed] times. */
    async visit(url: string, { visits = 1, typed = 0, daysAgo = 0, title }: {
      visits?: number; typed?: number; daysAgo?: number; title?: string;
    } = {}) {
      const today = clock.time;
      clock.time -= daysAgo * day;
      for (let i = 0; i < visits; i++) assert.equal((await post("visit", { url, title })).status, 204);
      for (let i = 0; i < typed; i++) assert.equal((await post("typed", { url })).status, 204);
      clock.time = today;
    },
    async suggest(text: string): Promise<Array<{ url: string; title: string }>> {
      return (await app.request(`/api/browser-history?q=${encodeURIComponent(text)}`)).json();
    },
    async suggested(text: string) {
      return (await this.suggest(text)).map((page) => page.url);
    },
  };
}

test("browser history keeps one entry per page address and only web pages", async () => {
  const h = history();
  await h.visit("https://example.com/a#intro", { title: "Example A" });
  await h.visit("https://example.com/a#details");
  await h.visit("about:blank");
  await h.visit("file:///Users/me/notes.html");
  await h.post("title", { url: "https://example.com/a#later", title: "Example A, renamed" });
  await h.post("title", { url: "https://example.com/a", title: "" });
  await h.post("title", { url: "https://unvisited.example/", title: "Unvisited" });

  assert.deepEqual(h.store.browserPages().map(({ url, title, visits }) => ({ url, title, visits })),
    [{ url: "https://example.com/a", title: "Example A, renamed", visits: 2 }]);
  assert.deepEqual(await h.suggest("example.com/a"), [{ url: "https://example.com/a", title: "Example A, renamed" }]);
  assert.deepEqual(await h.suggested("notes"), []);
});

test("browser history counts visits and address-bar opens from devices at once, in either order", async () => {
  const h = history();
  const url = "https://shared.example/";
  await Promise.all(Array.from({ length: 10 }, (_, i) => [
    h.post("typed", { url }), h.post("visit", { url, title: `Shared ${i}` }),
  ]).flat());
  const [page] = h.store.browserPages();
  assert.equal(page.visits, 10);
  assert.equal(page.typed, 10);
  assert.match(page.title, /^Shared \d$/);
});

test("browser history ranks often, typed and recent pages first", async () => {
  const h = history();
  await h.visit("https://example.com/rare");
  await h.visit("https://example.com/often", { visits: 5 });
  assert.deepEqual(await h.suggested("example.com/"), ["https://example.com/often", "https://example.com/rare"]);

  // One typed visit outweighs three clicked ones.
  await h.visit("https://typed.test/", { typed: 1 });
  await h.visit("https://clicked.test/", { visits: 3 });
  assert.deepEqual(await h.suggested("test"), ["https://typed.test/", "https://clicked.test/"]);

  // Visits from two months ago count for less than this week's.
  await h.visit("https://old.test/news", { visits: 5, daysAgo: 60 });
  await h.visit("https://new.test/news", { visits: 2, daysAgo: 1 });
  assert.deepEqual(await h.suggested("news"), ["https://new.test/news", "https://old.test/news"]);
});

test("browser history prefers the start of a site, then of a word, then any match", async () => {
  const h = history();
  await h.visit("https://www.github.com/");
  await h.visit("https://blog.example/git-tips", { visits: 4 });
  await h.visit("https://digital.example/", { visits: 10 });
  await h.visit("https://unrelated.example/", { visits: 50 });
  assert.deepEqual(await h.suggested("git"),
    ["https://www.github.com/", "https://blog.example/git-tips", "https://digital.example/"]);
  assert.deepEqual(await h.suggested("https://www.GitHub"), ["https://www.github.com/"]);
  assert.deepEqual(await h.suggested("   "), []);
  assert.deepEqual(await h.suggested("("), []);
});

test("browser history gives a site one row that gathers its pages", async () => {
  const h = history();
  for (let i = 0; i < 10; i++) await h.visit(`https://www.youtube.com/watch?v=${i}`, { title: `Video ${i}` });
  await h.visit("https://youtube-fan.example/", { visits: 20, daysAgo: 30 });
  const [first, ...rest] = await h.suggest("you");
  assert.deepEqual(first, { url: "https://www.youtube.com/", title: "" });
  assert.equal(rest.length, 5);

  await h.visit("https://www.youtube.com/", { title: "YouTube" });
  const again = await h.suggest("you");
  assert.equal(again[0].title, "YouTube");
  assert.equal(again.filter((page) => page.url === "https://www.youtube.com/").length, 1);
});

test("browser history shows the best six", async () => {
  const h = history();
  for (let i = 1; i <= 8; i++) await h.visit(`https://site${i}.example/`, { visits: i });
  assert.deepEqual(await h.suggested("site"), [8, 7, 6, 5, 4, 3].map((i) => `https://site${i}.example/`));
});

test("browser history forgets pages after 90 days and keeps the best 1000", async () => {
  const h = history();
  await h.visit("https://stale.example/", { visits: 20, daysAgo: 91 });
  await h.visit("https://kept.example/", { daysAgo: 89 });
  assert.deepEqual(await h.suggested("example"), ["https://kept.example/"]);
  assert.equal(h.store.browserPages().length, 2, "only a write forgets pages");
  await h.post("typed", { url: "https://kept.example/" });
  assert.deepEqual(h.store.browserPages().map((page) => page.url), ["https://kept.example/"]);

  for (let i = 0; i < 999; i++) {
    h.store.countBrowserPage(`https://page${i}.example/`, h.clock.time, "visit");
    h.store.countBrowserPage(`https://page${i}.example/`, h.clock.time, "visit");
  }
  await h.visit("https://page999.example/");
  assert.equal(h.store.browserPages().length, 1000);
  assert.deepEqual(await h.suggested("kept"), [], "the weakest page goes");
  assert.deepEqual(await h.suggested("page999"), ["https://page999.example/"]);
});

test("browser history clears every page", async () => {
  const h = history();
  await h.visit("https://example.com/");
  assert.equal((await h.app.request("/api/browser-history", { method: "DELETE" })).status, 204);
  assert.deepEqual(h.store.browserPages(), []);
  assert.deepEqual(await h.suggested("example"), []);
});

import type { Hono } from "hono";
import type { StoredCategory } from "./stored-data.ts";
import type { BrowserPage, Store } from "./store.ts";

const shown = 6, maxPages = 1000;
const siteStart = /^(https?:\/\/)?(www\.)?/;

/** The address kept for a page, without its #fragment, or null for anything but an HTTP or HTTPS website. */
export function pageAddress(text: unknown) {
  if (typeof text !== "string" || !URL.canParse(text)) return null;
  const url = new URL(text);
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  url.hash = "";
  return url.href;
}

// Typing an address shows more intent than following a link to it.
function weight(page: BrowserPage, now: number) {
  const days = Math.trunc((now - page.lastVisit) / 60_000) / (24 * 60);
  const recency = days <= 4 ? 1 : Math.max(0.2, 0.2 ** ((days - 4) / 56));
  return (page.visits + 3 * page.typed) * recency;
}

/** Forgets all but the best 1000 pages. Stored data's clean-up forgets the old ones. */
function prune(store: Store, now: number) {
  const pages = store.browserPages();
  if (pages.length <= maxPages) return;
  const kept = new Set(pages
    .sort((a, b) => weight(b, now) - weight(a, now) || b.lastVisit - a.lastVisit)
    .slice(0, maxPages).map((page) => page.url));
  store.forgetBrowserPages(pages.filter((page) => !kept.has(page.url)).map((page) => page.url));
}

/** The pages that best match [text], best first. */
function suggest(pages: BrowserPage[], text: string, now: number) {
  const q = text.trim().toLowerCase();
  if (!q) return [];
  const site = q.replace(siteStart, "");
  const wordStart = new RegExp(`(^|[^\\p{L}\\p{N}])${q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`, "u");
  const match = (page: BrowserPage) => {
    const url = page.url.toLowerCase(), title = page.title.toLowerCase();
    if (site && url.replace(siteStart, "").startsWith(site)) return 20;
    if (wordStart.test(url) || wordStart.test(title)) return 4;
    if (url.includes(q) || title.includes(q)) return 1;
    return 0;
  };
  const scored = pages.flatMap((page) => {
    const bonus = match(page);
    return bonus ? [{ page, score: bonus * weight(page, now) }] : [];
  });
  // A site whose name starts with the text also gets one row for its home
  // page, worth all its pages together, so many single visits to its pages
  // neither crowd out the site nor leave it missing.
  const titles = new Map(pages.map((page) => [page.url, page.title]));
  const sites = new Map<string, { page: BrowserPage; score: number }>();
  for (const item of scored) {
    const url = new URL(item.page.url);
    if (!site || !url.hostname.replace(siteStart, "").startsWith(site)) continue;
    const home = `${url.origin}/`;
    const row = sites.get(home);
    sites.set(home, {
      page: row?.page ?? { url: home, title: titles.get(home) ?? "", visits: 0, typed: 0, lastVisit: item.page.lastVisit },
      score: (row?.score ?? 0) + item.score,
    });
  }
  return [...scored.filter((item) => !sites.has(item.page.url)), ...sites.values()]
    // On a tie the shorter address, a site before its page, comes first.
    .sort((a, b) => b.score - a.score || b.page.lastVisit - a.page.lastVisit || a.page.url.length - b.page.url.length)
    .slice(0, shown).map(({ page }) => ({ url: page.url, title: page.title }));
}

/**
 * The Browser's address-bar history, one for every device. It is private
 * browsing data: nothing here is given to the agent, its tools or app views.
 */
export function addBrowserHistory(app: Hono, store: Store, now = Date.now) {
  app.get("/api/browser-history", (c) =>
    c.json(suggest(store.browserPages(), c.req.query("q") ?? "", now())));
  // Stable 0.0.16 and earlier clear the history here; later clients use
  // Stored data.
  app.delete("/api/browser-history", (c) => {
    store.forgetBrowserPages();
    return c.body(null, 204);
  });
  // A visit and an address-bar open of the same page are counted separately,
  // so either request may arrive first.
  for (const kind of ["visit", "typed"] as const) {
    app.post(`/api/browser-history/${kind}`, async (c) => {
      const { url, title } = await c.req.json() as { url?: unknown; title?: unknown };
      const address = pageAddress(url), at = now();
      if (address) {
        store.countBrowserPage(address, at, kind, kind === "visit" && typeof title === "string" ? title : "");
        prune(store, at);
      }
      return c.body(null, 204);
    });
  }
  app.post("/api/browser-history/title", async (c) => {
    const { url, title } = await c.req.json() as { url?: unknown; title?: unknown };
    const address = pageAddress(url);
    if (address && typeof title === "string" && title) store.retitleBrowserPage(address, title);
    return c.body(null, 204);
  });
}

export const browserHistoryData = (store: Store): StoredCategory => ({
  id: "browser-history",
  name: "Browsing history",
  description: "Pages visited in Browser tabs, for address bar suggestions.",
  defaultDays: 90,
  usage: (before) => store.browserPagesUsage(before),
  forget: (before) => before === undefined ? store.forgetBrowserPages() : store.forgetBrowserPagesBefore(before),
});

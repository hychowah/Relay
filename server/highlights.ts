import type { Hono } from "hono";
import { pageAddress } from "./browser-history.ts";
import type { StoredCategory } from "./stored-data.ts";
import type { Highlight, Store } from "./store.ts";

const text = (value: unknown, longest: number) =>
  typeof value === "string" && value.length <= longest ? value : null;

/** A highlight as a client may save it, or null. */
function highlight(input: Record<string, unknown>): Highlight | null {
  const id = text(input.id, 64), quote = text(input.text, 4000);
  const prefix = text(input.prefix ?? "", 200), suffix = text(input.suffix ?? "", 200);
  if (!id || !quote || prefix === null || suffix === null) return null;
  const marks = input.marks;
  if (marks === undefined) return { id, text: quote, prefix, suffix };
  const lines = Array.isArray(marks) && marks.length <= 2000 && marks.every((line) =>
    Array.isArray(line) && line.length === 5 && line.every((n) => typeof n === "number" && Number.isFinite(n)));
  return lines ? { id, text: quote, prefix, suffix, marks: marks as number[][] } : null;
}

/**
 * The text the user highlighted in Browser tabs, one list for each page
 * address and every device. Like the browsing history it is private: nothing
 * here is given to the agent, its tools or app views.
 */
export function addHighlights(app: Hono, store: Store, now = Date.now) {
  app.get("/api/highlights", (c) => {
    const address = pageAddress(c.req.query("url"));
    return c.json(address ? store.highlights(address) : []);
  });
  app.post("/api/highlights", async (c) => {
    const { url, ...input } = await c.req.json() as Record<string, unknown>;
    const address = pageAddress(url), made = highlight(input);
    if (!address || !made) return c.json({ error: "This highlight cannot be saved." }, 400);
    store.addHighlight(address, made, now());
    return c.body(null, 204);
  });
  app.delete("/api/highlights/:id", (c) => {
    store.forgetHighlight(c.req.param("id"));
    return c.body(null, 204);
  });
}

export const highlightsData = (store: Store): StoredCategory => ({
  id: "highlights",
  name: "Highlights",
  description: "Text you highlighted on web pages and in PDFs.",
  defaultDays: null,
  usage: (before) => store.highlightsUsage(before),
  forget: (before) => store.forgetHighlights(before),
});

import type { Hono } from "hono";
import type { Store, StoredUsage } from "./store.ts";

const day = 24 * 60 * 60 * 1000;

/**
 * One kind of data the server keeps as the user works, such as browsing
 * history. The module that owns the data describes it; the Stored data screen
 * lists every category with its size, clears it and sets how long it is kept.
 */
export interface StoredCategory {
  id: string;
  name: string;
  description: string;
  /** Days an item is kept until the user chooses; null keeps it for ever. */
  defaultDays: number | null;
  /** What the category holds, or only its items older than [before]. */
  usage(before?: number): StoredUsage;
  /** Forgets everything, or the items older than [before]. */
  forget(before?: number): void;
}

/** Adds the stored data routes; returns the clean-up to run now and then. */
export function addStoredData(app: Hono, store: Store, categories: StoredCategory[], now = Date.now) {
  const keptDays = (category: StoredCategory) => {
    const chosen = store.cleanupDays(category.id);
    return chosen === undefined ? category.defaultDays : chosen;
  };
  const clean = () => {
    for (const category of categories) {
      const days = keptDays(category);
      if (days !== null) category.forget(now() - days * day);
    }
  };
  const unknown = { error: "Unknown stored data." };

  app.get("/api/stored-data", (c) => c.json(categories.map((category) => ({
    id: category.id, name: category.name, description: category.description,
    ...category.usage(), autoCleanDays: keptDays(category),
  }))));
  app.put("/api/stored-data/:id", async (c) => {
    const category = categories.find((item) => item.id === c.req.param("id"));
    if (!category) return c.json(unknown, 404);
    const { autoCleanDays: days, deleteOlder } = await c.req.json() as { autoCleanDays?: unknown; deleteOlder?: unknown };
    if (days !== null && !(Number.isInteger(days) && (days as number) >= 1 && (days as number) <= 3650))
      return c.json({ error: "Choose 1 to 3650 days, or turn auto-clean off." }, 400);
    // A period that would delete items now is saved only once the user has
    // seen how many and agreed: nothing is lost to a slip of the hand.
    const older = days === null ? 0 : category.usage(now() - (days as number) * day).items;
    if (older > 0 && deleteOlder !== true) return c.json({ saved: false, older });
    store.setCleanupDays(category.id, days as number | null);
    clean();
    return c.json({ saved: true, older });
  });
  app.delete("/api/stored-data/:id", (c) => {
    const category = categories.find((item) => item.id === c.req.param("id"));
    if (!category) return c.json(unknown, 404);
    category.forget();
    return c.body(null, 204);
  });
  return clean;
}

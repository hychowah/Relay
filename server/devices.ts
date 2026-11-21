import type { Hono } from "hono";
import type { Store } from "./store.ts";

/**
 * What one device can take from another: the open tabs each device saved
 * last, so another device can open them once, and the conversation last
 * opened on any device, which a client opens when it starts or returns to the
 * front. Tabs stay each device's own; nothing follows live. Like the browsing
 * history these are private: nothing here is given to the agent, its tools or
 * app views.
 */
export function addDevices(app: Hono, store: Store, now = Date.now) {
  app.put("/api/devices/:id", async (c) => {
    const id = c.req.param("id");
    const { name, tabs } = await c.req.json() as Record<string, unknown>;
    // Another device reads these tabs, so they must be a tab session.
    if (typeof name !== "string" || !Array.isArray((tabs as { tabs?: unknown } | null)?.tabs)) {
      return c.json({ error: "These tabs cannot be saved." }, 400);
    }
    store.saveDevice(id, name, JSON.stringify(tabs), now());
    return c.body(null, 204);
  });
  app.get("/api/devices", (c) => c.json(store.devices().map((device) => ({
    ...device, tabs: JSON.parse(device.tabs),
  }))));
  app.get("/api/current-conversation", (c) => c.json({ id: store.currentConversation() ?? null }));
  app.put("/api/current-conversation", async (c) => {
    const { id } = await c.req.json() as Record<string, unknown>;
    if (typeof id !== "string" || !store.conversation(id)) {
      return c.json({ error: "Conversation not found." }, 404);
    }
    store.setCurrentConversation(id);
    return c.body(null, 204);
  });
}

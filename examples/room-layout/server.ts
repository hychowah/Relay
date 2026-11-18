import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const items = [
  { id: "desk", name: "Desk", zone: "work", width: 140, depth: 70 },
  { id: "lamp", name: "Floor lamp", zone: "work", width: 35, depth: 35 },
  { id: "sofa", name: "Sofa", zone: "rest", width: 190, depth: 85 },
  { id: "plant", name: "Plant", zone: "rest", width: 45, depth: 45 },
];
const zones = ["all", "work", "rest"];

export function createRoomLayoutApp(parentOrigins: string[]) {
  const app = new Hono();
  app.get("/_relay/manifest", (c) => c.json({
    version: 2, id: "room-layout", name: "Room layout",
    description: "A small interactive room plan with furniture and work/rest zones.",
    instructions: "Use layout.inspect to inspect the room or a zone. Measurements are synthetic centimetres. Present its returned presentation intent to show the matching furniture. app_present supports an optional explanation (plain text, at most 600 characters), shown beside the first target or room view. Use it to explain the dimensions you are showing. This app has no document search or read API.",
    view: { path: "/_relay/view" },
  }));
  app.get("/_relay/operations", (c) => c.json({ operations: [{
    name: "layout.inspect", description: "Inspect furniture in the whole room or a work/rest zone.",
    inputSchema: { type: "object", properties: { zone: { type: "string", enum: zones, default: "all" } }, additionalProperties: false },
  }] }));
  app.post("/_relay/call", async (c) => {
    let body;
    try { body = await c.req.json(); } catch { return c.json({ error: "Expected JSON." }, 400); }
    const args = body?.arguments;
    if (body?.operation !== "layout.inspect" || !args || typeof args !== "object" || Array.isArray(args) ||
      Object.keys(args).some((key) => key !== "zone") || !zones.includes(args.zone ?? "all"))
      return c.text(JSON.stringify({ type: "error", message: "Use layout.inspect with zone all, work or rest." }) + "\n", 200, { "Content-Type": "application/x-ndjson" });
    const zone = args.zone ?? "all";
    const found = items.filter((item) => zone === "all" || item.zone === zone);
    const events = [
      { type: "progress", message: `Inspecting the ${zone === "all" ? "whole room" : `${zone} zone`}` },
      { type: "result", result: { data: {
        room: "Studio", unit: "cm", items: found, count: found.length,
        presentation: { viewId: "room", state: { zone }, targetIds: found.map((item) => item.id) },
      } } },
    ];
    return c.text(events.map((event) => JSON.stringify(event)).join("\n") + "\n", 200, { "Content-Type": "application/x-ndjson" });
  });
  const html = readFileSync(new URL("./index.html", import.meta.url), "utf8");
  app.get("/", (c) => c.html(html));
  app.get("/_relay/view", (c) => {
    const parent = c.req.query("parentOrigin");
    if (!parent || !parentOrigins.includes(parent) || !c.req.query("token"))
      return c.json({ error: "This Relay parent is not configured." }, 403);
    c.header("Content-Security-Policy", `frame-ancestors ${parent}`);
    return c.html(html);
  });
  return app;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT || 3220);
  const app = createRoomLayoutApp((process.env.RELAY_ALLOWED_ORIGINS || "http://127.0.0.1:3210,http://localhost:3210").split(","));
  serve({ fetch: app.fetch, hostname: "127.0.0.1", port });
  console.log(`Room layout: http://127.0.0.1:${port}`);
}

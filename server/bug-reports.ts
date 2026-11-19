import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Hono } from "hono";
import { HTTPException } from "hono/http-exception";
import type { Store } from "./store.ts";

const maxReportCharacters = 20_000_000;
const secretName = /api.?key|secret|password|authorization/i;
// Only names this module writes; the check keeps requests inside the report folder.
const reportId = /^[0-9TZ-]+-[0-9a-f]{8}$/;

// Recordings include request bodies, such as provider settings with an API key.
function redact(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(redact);
  if (value === null || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value).map(([key, item]) =>
    [key, secretName.test(key) && item ? "[redacted]" : redact(item)]));
}

/** Saves and serves development bug reports: one JSON file each, plus an optional PNG. */
export function addBugReports(app: Hono, dir: string, store: Store) {
  function reportFile(id: string, extension: "json" | "png") {
    const path = join(dir, `${id}.${extension}`);
    if (!reportId.test(id) || !existsSync(path)) throw new HTTPException(404, { message: "Bug report not found." });
    return path;
  }

  app.get("/api/bug-reports", (c) => {
    const files = existsSync(dir) ? readdirSync(dir).filter((name) => name.endsWith(".json")) : [];
    return c.json(files.map((name) => {
      const report = JSON.parse(readFileSync(join(dir, name), "utf8"));
      return { id: report.id, savedAt: report.savedAt, description: report.description,
        events: report.events.length, screenshot: Boolean(report.screenshot) };
    }).sort((a, b) => b.savedAt.localeCompare(a.savedAt)));
  });
  app.get("/api/bug-reports/:id", (c) =>
    c.body(readFileSync(reportFile(c.req.param("id"), "json"), "utf8"), 200, { "Content-Type": "application/json" }));
  app.get("/api/bug-reports/:id/screenshot", (c) =>
    c.body(readFileSync(reportFile(c.req.param("id"), "png")), 200, { "Content-Type": "image/png" }));

  app.post("/api/bug-reports", async (c) => {
    const text = await c.req.text();
    if (text.length > maxReportCharacters)
      throw new HTTPException(413, { message: "The recording is too large to save." });
    const { screenshot, ...body } = JSON.parse(text) as Record<string, unknown>;
    if (typeof body.description !== "string" || !Array.isArray(body.events))
      throw new HTTPException(400, { message: "Send a description and the recorded events." });
    const savedAt = new Date().toISOString();
    const id = `${savedAt.replace(/[:.]/g, "-")}-${randomUUID().slice(0, 8)}`;
    const conversation = typeof body.conversationId === "string" ? store.snapshot(body.conversationId) : undefined;
    mkdirSync(dir, { recursive: true });
    if (typeof screenshot === "string" && screenshot)
      writeFileSync(join(dir, `${id}.png`), Buffer.from(screenshot, "base64"), { mode: 0o600 });
    const report = {
      id, savedAt, ...(redact(body) as object),
      screenshot: typeof screenshot === "string" && screenshot ? `${id}.png` : null,
      // The server's own record of the conversation: messages, runs, tool calls and view commands.
      serverConversation: conversation ?? null,
    };
    writeFileSync(join(dir, `${id}.json`), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
    return c.json({ id, file: `bug-reports/${id}.json` }, 201);
  });
}

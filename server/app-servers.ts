import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import type { Hono } from "hono";
import { HTTPException } from "hono/http-exception";

/**
 * App servers: existing user services that the user starts and stops from
 * Relay. The host's user service manager runs them from their own units, so
 * they outlive Relay. Only the private servers file names them; a request
 * carries nothing but a server id, and Relay never writes a unit.
 */
export interface AppServer { id: string; name: string; unit: string }

export interface RunResult { ok: boolean; stdout: string; stderr: string; timedOut?: boolean }
/** The one way this module reaches the host, so tests use a fake. */
export type Run = (command: "systemctl" | "journalctl", args: string[]) => Promise<RunResult>;

// Below the Flutter client's 20-second request limit. A job that outlasts it
// continues in the service manager and the reply reports its current state.
const runTimeout = 15_000;
const runCommand: Run = (command, args) => new Promise((resolve) =>
  execFile(command, args, { encoding: "utf8", timeout: runTimeout, maxBuffer: 8 << 20 }, (error, stdout, stderr) =>
    resolve({ ok: !error, stdout, stderr: stderr.trim() || (error?.message ?? ""), timedOut: Boolean(error?.killed) })));

// Ids and unit names reach systemctl arguments, so they are kept to plain
// characters and cannot start like an option.
const idPattern = /^[a-z0-9][a-z0-9_-]{0,62}$/;
const unitPattern = /^[A-Za-z0-9][A-Za-z0-9:_.@-]*\.service$/;

export function parseServers(text: string): AppServer[] {
  const value: unknown = JSON.parse(text);
  if (!Array.isArray(value)) throw new Error("it must contain a JSON array of servers");
  const ids = new Set<string>();
  const units = new Set<string>();
  return value.map((entry, index) => {
    if (entry === null || typeof entry !== "object" || typeof entry.id !== "string" || !idPattern.test(entry.id))
      throw new Error(`entry ${index + 1} needs an id of lowercase letters, digits, - or _`);
    const { id, name, unit } = entry as Record<string, string>;
    if (typeof name !== "string" || !name.trim()) throw new Error(`server "${id}" needs a name`);
    if (typeof unit !== "string" || !unitPattern.test(unit)) throw new Error(`server "${id}" needs a unit ending in .service`);
    if (ids.has(id)) throw new Error(`server id "${id}" is used more than once`);
    if (units.has(unit)) throw new Error(`unit ${unit} is named more than once`);
    ids.add(id);
    units.add(unit);
    return { id, name, unit };
  });
}

/** The file's servers as it is now: none without a file, an error the screen shows when it is unusable. */
function readServers(file: string | undefined): AppServer[] {
  if (!file) return [];
  let text: string;
  try { text = readFileSync(file, "utf8"); }
  catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT") return [];
    throw new HTTPException(500, { message: `The servers file could not be read (${code ?? "error"}).` });
  }
  try { return parseServers(text); }
  catch (error) { throw new HTTPException(500, { message: `The servers file is not valid: ${(error as Error).message}.` }); }
}

export type ServerState = "running" | "starting" | "stopping" | "stopped" | "failed";
export interface ServerStatus {
  id: string;
  name: string;
  state: ServerState;
  detail?: string;
  /** Whether it starts with the computer; null when its unit cannot be set to. */
  autoStart: boolean | null;
  autoStartNote?: string;
}

const properties = ["LoadState", "ActiveState", "SubState", "Result", "ExecMainStatus", "UnitFileState"];
type Properties = Record<string, string>;

function failureReason({ Result, ExecMainStatus }: Properties) {
  switch (Result) {
    case "exit-code": return `exited with status ${ExecMainStatus}`;
    case "signal": case "core-dump": return `ended by signal ${ExecMainStatus}`;
    case "timeout": return "timed out";
    case "start-limit-hit": return "restarted too often";
    default: return Result;
  }
}

export function serverStatus(server: AppServer, unit: Properties): ServerStatus {
  const status = (state: ServerState, detail?: string) => ({ state, detail });
  const failed = unit.Result && unit.Result !== "success" ? failureReason(unit) : undefined;
  const { state, detail } = unit.LoadState === "not-found" ? status("stopped", `${server.unit} is not installed.`)
    : unit.SubState === "auto-restart" ? status("failed", `Restarting: it ${failed ?? "stopped"}.`)
    : unit.ActiveState === "active" || unit.ActiveState === "reloading" || unit.ActiveState === "refreshing" ? status("running")
    : unit.ActiveState === "activating" ? status("starting")
    : unit.ActiveState === "deactivating" ? status("stopping")
    : unit.ActiveState === "failed" ? status("failed", failed && `It ${failed}.`)
    : status("stopped");
  const fileState = unit.UnitFileState ?? "";
  const autoStart = fileState === "enabled" ? true : fileState === "disabled" ? false : null;
  return {
    id: server.id, name: server.name, state, ...(detail ? { detail } : {}), autoStart,
    ...(autoStart !== null ? {} : {
      autoStartNote: fileState === "static"
        ? "Its unit has no [Install] section, so it cannot start with the computer."
        : `Not available for this unit (${fileState || "not installed"}).`,
    }),
  };
}

export interface AppServerOptions {
  run?: Run;
  /** How long a started server must keep running before the start counts. */
  settleMs?: number;
}

/**
 * Adds the App servers routes. The servers file is read on every request.
 * Log lines go only to the client that asked; Relay does not log them.
 */
export function addAppServers(app: Hono, file: string | undefined, { run = runCommand, settleMs = 1000 }: AppServerOptions = {}) {
  const systemctl = (...args: string[]) => run("systemctl", ["--user", ...args]);

  function find(id: string) {
    const server = readServers(file).find((server) => server.id === id);
    if (!server) throw new HTTPException(404, { message: "This server is not in the servers file." });
    return server;
  }

  async function statuses(list: AppServer[]): Promise<ServerStatus[]> {
    if (!list.length) return [];
    const result = await systemctl("show", `--property=${properties.join(",")}`, ...list.map(({ unit }) => unit));
    const blocks = result.stdout.trim().split(/\n\n+/);
    if (!result.ok || blocks.length !== list.length)
      throw new HTTPException(502, { message: `The service manager did not answer: ${result.stderr || "unexpected reply"}` });
    return list.map((server, index) => serverStatus(server, Object.fromEntries(
      blocks[index].split("\n").map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)]))));
  }

  async function control(server: AppServer, action: "start" | "stop" | "restart") {
    // A pressed Start also clears an earlier "restarted too often" stop.
    if (action !== "stop") await systemctl("reset-failed", server.unit);
    const result = await systemctl(action, server.unit);
    if (!result.ok && !result.timedOut) return { error: result.stderr || `${action} failed.`, server: (await statuses([server]))[0] };
    if (action !== "stop" && !result.timedOut) await new Promise((resolve) => setTimeout(resolve, settleMs));
    const [status] = await statuses([server]);
    const stayed = action === "stop" ? status.state !== "running" : status.state !== "failed" && status.state !== "stopped";
    return stayed || result.timedOut ? { server: status }
      : { error: action === "stop" ? `${server.name} is still running.` : `${server.name} did not stay running. ${status.detail ?? "It stopped."}`, server: status };
  }

  app.get("/api/app-servers", async (c) => c.json(await statuses(readServers(file))));
  for (const action of ["start", "stop", "restart"] as const) {
    app.post(`/api/app-servers/:id/${action}`, async (c) => {
      const result = await control(find(c.req.param("id")), action);
      return c.json(result, result.error ? 502 : 200);
    });
  }
  app.put("/api/app-servers/:id/auto-start", async (c) => {
    const server = find(c.req.param("id"));
    const { on } = await c.req.json() as { on?: unknown };
    if (typeof on !== "boolean") throw new HTTPException(400, { message: "Send on: true or false." });
    const [before] = await statuses([server]);
    if (before.autoStart === null) throw new HTTPException(409, { message: before.autoStartNote! });
    const result = await systemctl(on ? "enable" : "disable", server.unit);
    if (!result.ok) throw new HTTPException(502, { message: result.stderr || "The change was not applied." });
    return c.json((await statuses([server]))[0]);
  });
  app.get("/api/app-servers/:id/logs", async (c) => {
    const server = find(c.req.param("id"));
    const result = await run("journalctl", ["--user", "-u", server.unit, "-o", "cat", "-n", "200", "--no-pager"]);
    if (!result.ok) throw new HTTPException(502, { message: `The logs could not be read: ${result.stderr}` });
    return c.json({ text: result.stdout });
  });
}

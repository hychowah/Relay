import { readFileSync } from "node:fs";
import type { RegisteredApp } from "./app.ts";
import { HttpIntegration, type AppRegistration } from "./integrations/http.ts";

const optional = (value: unknown, type: string) => value === undefined || typeof value === type;

function parse(text: string, reserved: Set<string>): AppRegistration[] {
  const value: unknown = JSON.parse(text);
  if (!Array.isArray(value)) throw new Error("it must contain a JSON array of registrations");
  const ids = new Set(reserved);
  return value.map((entry, index) => {
    if (entry === null || typeof entry !== "object" || typeof entry.id !== "string" || !entry.id.trim() ||
      typeof entry.name !== "string" || typeof entry.serverUrl !== "string" ||
      !optional(entry.browserUrl, "string") || !optional(entry.trustedNative, "boolean"))
      throw new Error(`entry ${index + 1} needs a string id, name and serverUrl; browserUrl must be a string and trustedNative true or false`);
    if (ids.has(entry.id)) throw new Error(`app id "${entry.id}" is used more than once`);
    ids.add(entry.id);
    return entry as AppRegistration;
  });
}

const identity = ({ id, name, serverUrl, browserUrl, trustedNative }: AppRegistration) =>
  JSON.stringify([id, name, serverUrl, browserUrl ?? null, trustedNative === true]);

/**
 * Returns a function giving the current apps: the fixed built-in apps, then
 * the operator's apps file, which cannot reuse a built-in id. The file is read
 * now and on each call, and applied only when its text changed; comparing
 * text avoids coarse modification-time resolution at a small file's cost.
 * Unchanged entries keep their integration, so open views and calls continue. A file that cannot be read or applied keeps
 * the last good list and is reported once in the log.
 */
export function appRegistry(file: string | undefined, fixed: RegisteredApp[] = []): () => RegisteredApp[] {
  if (!file) return () => fixed;
  const reserved = new Set(fixed.map(({ id }) => id));
  let current = fixed;
  let entries = new Map<string, RegisteredApp>();
  let seen: string | undefined;
  const read = () => {
    let text: string;
    try { text = readFileSync(file, "utf8"); }
    catch (error) {
      const problem = `could not be read (${(error as NodeJS.ErrnoException).code ?? "error"})`;
      if (seen !== problem) console.error(`Apps file ${file} ${problem}; keeping the previous ${current.length} apps.`);
      seen = problem;
      return current;
    }
    if (text === seen) return current;
    const loaded = seen !== undefined;
    seen = text;
    try {
      const next = new Map<string, RegisteredApp>();
      for (const registration of parse(text, reserved)) {
        const key = identity(registration);
        let app = entries.get(key);
        try { app ??= HttpIntegration.register(registration); }
        catch (error) { throw new Error(`app "${registration.id}": ${(error as Error).message}`); }
        next.set(key, app);
      }
      entries = next;
      current = [...fixed, ...next.values()];
      if (loaded) console.log(`Apps file ${file} reloaded: ${next.size} apps.`);
    } catch (error) {
      console.error(`Apps file ${file} was not applied: ${error instanceof Error ? error.message.replace(/\.$/, "") : error}. Keeping the previous ${current.length} apps.`);
    }
    return current;
  };
  read();
  return read;
}

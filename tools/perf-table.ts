// Shared by the `npm run perf*` tools: finding the previous saved run and
// printing an aligned table.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

/** The newest saved run in `dir` whose file name `matches`. */
export function latestResult<T>(dir: string, matches: (name: string) => boolean): { file: string; data: T } | undefined {
  let files: string[] = [];
  try { files = readdirSync(dir).filter((name) => name.endsWith(".json") && matches(name)).sort(); }
  catch { return undefined; }
  const file = files.at(-1);
  return file ? { file, data: JSON.parse(readFileSync(join(dir, file), "utf8")) } : undefined;
}

/** Prints rows with the first column left-aligned and the others right-aligned. */
export function printRows(rows: string[][]) {
  const widths = rows[0].map((_, i) => Math.max(...rows.map((row) => (row[i] ?? "").length)));
  for (const row of rows)
    console.log(row.map((cell, i) => i === 0 ? cell.padEnd(widths[i]) : cell.padStart(widths[i])).join("  ").trimEnd());
}

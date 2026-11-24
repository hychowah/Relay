// Worker for pdf-text.ts: reads the PDFs it is sent, one at a time, and posts
// each one's page count, then each page's text, then done (or error), so the
// service's own thread never parses a PDF. It stops a PDF once it has sent
// `most` characters of its text, so a crafted PDF cannot fill the service's
// memory with text.
import { readFile } from "node:fs/promises";
import { parentPort } from "node:worker_threads";
import { getDocumentProxy } from "unpdf";

parentPort!.on("message", async ({ path, most }: { path: string; most: number }) => {
  try {
    const document = await getDocumentProxy(new Uint8Array(await readFile(path)));
    let left = most, capped = false;
    try {
      parentPort!.postMessage({ pages: document.numPages });
      for (let number = 1; number <= document.numPages; number++) {
        if (left <= 0) { capped = true; break; }
        const content = await (await document.getPage(number)).getTextContent();
        const text = content.items.map((item) => "str" in item ? item.str + (item.hasEOL ? "\n" : "") : "").join("");
        parentPort!.postMessage({ text: text.slice(0, left) });
        left -= text.length;
      }
      capped ||= left < 0;
    } finally { await document.loadingTask.destroy(); }
    parentPort!.postMessage({ done: true, ...(capped ? { capped } : {}) });
  } catch {
    parentPort!.postMessage({ error: true });
  }
});

// Worker for pdf-text.ts: reads the PDFs it is sent, one at a time, and posts
// each one's page count, then each page's text, then done (or error), so the
// service's own thread never parses a PDF.
import { readFile } from "node:fs/promises";
import { parentPort } from "node:worker_threads";
import { getDocumentProxy } from "unpdf";

parentPort!.on("message", async (path: string) => {
  try {
    const document = await getDocumentProxy(new Uint8Array(await readFile(path)));
    try {
      parentPort!.postMessage({ pages: document.numPages });
      for (let number = 1; number <= document.numPages; number++) {
        const content = await (await document.getPage(number)).getTextContent();
        parentPort!.postMessage({ text: content.items.map((item) => "str" in item ? item.str + (item.hasEOL ? "\n" : "") : "").join("") });
      }
    } finally { await document.loadingTask.destroy(); }
    parentPort!.postMessage({ done: true });
  } catch {
    parentPort!.postMessage({ error: true });
  }
});

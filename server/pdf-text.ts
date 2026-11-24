import { Worker } from "node:worker_threads";

const workerFile = new URL("./pdf-text-worker.ts", import.meta.url);
type PdfText = { text: string; pages: number; read: number; complete: boolean; capped?: true };

/** The most text kept from one PDF, about 5 MB; the worker stops reading there. */
export const pdfMostChars = 5_000_000;

/**
 * Reads PDFs' text, with a [Page N] line before each page, in one worker
 * thread shared by the PDFs of one request: a large PDF cannot stall the
 * service, and the worker starts once per search, not once per file. At the
 * deadline or when the signal aborts the worker is ended. A PDF cut off by the
 * deadline comes back with the pages read so far and complete false; one cut
 * off at pdfMostChars also has capped true; one cut off by the signal is
 * refused.
 */
export function pdfReader(deadline: number, signal?: AbortSignal) {
  let thread: Worker | undefined, stopped = false, reason: Error | undefined;
  let job: { parts: string[]; pages: number; resolve: (result: PdfText) => void; reject: (error: Error) => void } | undefined;
  const settle = (error?: Error, complete = false, capped = false) => {
    const current = job;
    job = undefined;
    if (!current) return;
    if (error) current.reject(error);
    else current.resolve({ text: current.parts.join("\n\n"), pages: current.pages, read: current.parts.length, complete,
      ...(capped ? { capped } : {}) });
  };
  const close = (error?: Error) => {
    if (stopped) return;
    stopped = true;
    reason = error;
    clearTimeout(timer);
    signal?.removeEventListener("abort", cancel);
    void thread?.terminate();
    settle(error);
  };
  const cancel = () => close(new Error("The request was cancelled."));
  const timer = setTimeout(() => close(), Math.max(0, deadline - Date.now()));
  signal?.addEventListener("abort", cancel);
  if (signal?.aborted) cancel();

  function start() {
    // A runaway PDF ends its own worker, not the service. resourceLimits
    // bound only the worker's JS heap, not its ArrayBuffers (Node docs), so
    // the file's size limit in files.ts and the deadline still matter.
    const worker = new Worker(workerFile, { resourceLimits: { maxOldGenerationSizeMb: 512 } });
    worker.on("message", (message: { pages?: number; text?: string; done?: true; capped?: true; error?: true }) => {
      if (!job) return;
      if (message.pages !== undefined) job.pages = message.pages;
      else if (message.text !== undefined) job.parts.push(`[Page ${job.parts.length + 1}]\n${message.text}`);
      else if (message.error) settle(new Error("This PDF could not be read."));
      else settle(undefined, !message.capped, message.capped);
    });
    // A worker that failed is replaced for the next PDF.
    const lost = () => {
      if (thread !== worker) return;
      thread = undefined;
      settle(new Error("This PDF could not be read."));
    };
    worker.on("error", lost);
    worker.on("exit", lost);
    return worker;
  }

  return {
    text(path: string) {
      return new Promise<PdfText>((resolve, reject) => {
        if (stopped) return reason ? reject(reason) : resolve({ text: "", pages: 0, read: 0, complete: false });
        job = { parts: [], pages: 0, resolve, reject };
        (thread ??= start()).postMessage({ path, most: pdfMostChars });
      });
    },
    close: () => close(),
  };
}

/** One PDF's text, from its own worker. */
export async function pdfText(path: string, deadline: number, signal?: AbortSignal) {
  const reader = pdfReader(deadline, signal);
  try { return await reader.text(path); }
  finally { reader.close(); }
}

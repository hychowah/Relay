import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { chromium } from "playwright";

async function listen(server: Server) {
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

// Any site can open Relay's host page with a view of its choosing in the address.
test("the app host page frames only a web page on the app's own site", async (t) => {
  const hostPage = await readFile(new URL("../public/flutter-host.html", import.meta.url), "utf8");
  const host = createServer((_, response) => response.writeHead(200, { "Content-Type": "text/html" }).end(hostPage));
  const app = createServer((_, response) => response.writeHead(200, { "Content-Type": "text/html" }).end("<title>App</title>"));
  const hostOrigin = await listen(host);
  t.after(() => host.close());
  const appOrigin = await listen(app);
  t.after(() => app.close());
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());

  async function open(view: Record<string, unknown>) {
    const page = await browser.newPage();
    await page.goto(`${hostOrigin}/flutter-host.html#${encodeURIComponent(JSON.stringify(view))}`);
    await page.waitForTimeout(300);
    const result = { title: await page.title(), frames: await page.locator("iframe").count() };
    await page.close();
    return result;
  }

  const run = "javascript:parent.document.title='ran'";
  for (const view of [
    { url: run, origin: appOrigin },
    { url: run, origin: "null", sandbox: "allow-scripts allow-same-origin" },
    { url: `${hostOrigin}/flutter-host.html`, origin: hostOrigin },
    { url: `${appOrigin}/_relay/view?token=t`, origin: "https://other.example" },
  ]) assert.deepEqual(await open(view), { title: "Relay app view", frames: 0 }, view.url);
  assert.deepEqual(await open({ url: `${appOrigin}/_relay/view?token=t`, origin: appOrigin }), { title: "Relay app view", frames: 1 });
});

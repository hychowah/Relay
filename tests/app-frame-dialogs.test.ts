import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { chromium } from "playwright";
import { HttpIntegration } from "../server/integrations/http.ts";

// Relay's real host page frames the app with the view that HttpIntegration
// opens, so the registration decides the iframe sandbox exactly as it does
// for the Flutter client. Headless Chromium stands in for WKWebView.
async function listen(server: Server) {
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

test("a page dialog and form in an app frame need a trusted registration", async (t) => {
  const hostPage = await readFile(new URL("../public/flutter-host.html", import.meta.url), "utf8");
  const host = createServer((_, response) => response.writeHead(200, { "Content-Type": "text/html" }).end(hostPage));
  const submitted: string[] = [];
  const app = createServer((request, response) => {
    const url = new URL(request.url!, "http://fixture");
    if (url.pathname === "/_relay/manifest") {
      response.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({
        version: 2, id: "analysis", name: "Analysis", description: "Synthetic analysis app", view: { path: "/_relay/view" },
      }));
    } else if (url.pathname === "/_relay/view") {
      // The shape of Analysis Web's Start analysis button.
      response.writeHead(200, { "Content-Type": "text/html" }).end(`<!doctype html><title>Analysis</title>
        <form method="post" action="/start?token=${url.searchParams.get("token")}" onsubmit="return confirm('Start analysis?')">
          <button>Start analysis</button>
        </form>`);
    } else if (url.pathname === "/start" && request.method === "POST") {
      submitted.push(url.searchParams.get("token")!);
      response.writeHead(200, { "Content-Type": "text/html" }).end("<title>Started</title>Started");
    } else {
      response.writeHead(404).end();
    }
  });
  // Each resource is closed from the moment it exists, so a browser that
  // cannot start fails the test instead of leaving the servers listening.
  const hostOrigin = await listen(host);
  t.after(() => host.close());
  const appOrigin = await listen(app);
  t.after(() => app.close());
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());

  async function press(trustedNative: boolean | undefined, token: string) {
    const integration = new HttpIntegration({ id: "analysis", name: "Analysis", serverUrl: appOrigin, trustedNative });
    const view = await integration.open(token, hostOrigin);
    const page = await browser.newPage();
    const dialogs: string[] = [];
    const blocked: string[] = [];
    page.on("dialog", (dialog) => { dialogs.push(dialog.message()); void dialog.accept(); });
    page.on("console", (message) => { if (message.text().includes("sandboxed")) blocked.push(message.text()); });
    await page.addInitScript(() => { (window as any).RelayHost = { postMessage() {} }; });
    await page.goto(`${hostOrigin}/flutter-host.html#${encodeURIComponent(JSON.stringify(view))}`);
    const button = page.frameLocator("iframe").getByRole("button", { name: "Start analysis" });
    await button.waitFor();
    const frame = page.frames().find((frame) => frame.url().includes("/_relay/view"))!;
    const confirmed = await frame.evaluate(() => confirm("Delete the draft?"));
    await button.click();
    if (trustedNative) {
      // Wait for the submission itself, however busy the machine is.
      for (let waited = 0; !submitted.includes(token) && waited < 10_000; waited += 50) await page.waitForTimeout(50);
    } else {
      // Nothing should arrive: give a submission the time it would take.
      await page.waitForTimeout(500);
    }
    await page.close();
    return { view, dialogs, blocked, confirmed, submitted: submitted.includes(token) };
  }

  const trusted = await press(true, "trusted-view");
  assert.equal(trusted.view.sandbox, undefined);
  assert.deepEqual(trusted.dialogs, ["Delete the draft?", "Start analysis?"]);
  assert.equal(trusted.submitted, true, "A trusted app's confirmed form submits.");
  assert.equal(trusted.confirmed, true);

  // Today's default rule: no allow-modals or allow-forms.
  const framed = await press(undefined, "default-view");
  assert.equal(framed.view.sandbox, "allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox");
  assert.equal(framed.submitted, false, "The sandbox blocks the form.");
  assert.ok(framed.blocked.some((text) => text.includes("'allow-forms'")), framed.blocked.join("\n"));
  assert.equal(framed.confirmed, false, "The sandbox answers confirm() with false.");
  assert.ok(framed.blocked.some((text) => text.includes("'confirm()'")), framed.blocked.join("\n"));
  assert.deepEqual(framed.dialogs, [], "The browser is never asked to show a dialog.");
});

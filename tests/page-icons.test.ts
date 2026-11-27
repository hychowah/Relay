import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";

// The Flutter Browser tab's icon script, run in headless Chromium as a
// stand-in for WKWebView, the way web_page.dart runs it after each load.
const script = await readFile(new URL("../flutter/assets/page_icons.js", import.meta.url), "utf8");

async function open(t: test.TestContext, head: string) {
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());
  const page = await browser.newPage();
  await page.addInitScript("window.relayMessages = []; window.RelayBrowser = { postMessage: (m) => relayMessages.push(m) };");
  await page.route("https://site.test/**", (route) => route.fulfill({ contentType: "text/html",
    body: `<!doctype html><head>${head}</head><title>Site</title>` }));
  await page.goto("https://site.test/news/today");
  await page.evaluate(script);
  return page;
}

const reports = async (page: import("playwright").Page) =>
  (await page.evaluate(() => (window as any).relayMessages as string[]))
    .map((message) => JSON.parse(message.slice("icons:".length)));

test("lists the page's drawable icons best first, the site's favicon.ico last", async (t) => {
  const page = await open(t, `
    <link rel="icon" href="/big.png" sizes="192x192">
    <link rel="icon" href="/logo.svg">
    <link rel="icon" type="image/svg+xml" href="/vector">
    <link rel="mask-icon" href="/mask.png">
    <link rel="apple-touch-icon" href="https://cdn.test/touch.png">
    <link rel="shortcut icon" href="/small.png" sizes="32x32">
    <link rel="icon" href="data:image/png;base64,AAAA">
    <link rel="icon" href="http://">`);
  assert.deepEqual(await reports(page), [{
    page: "https://site.test/news/today",
    icons: ["https://site.test/small.png", "https://site.test/big.png", "https://cdn.test/touch.png",
      "https://site.test/favicon.ico"],
  }]);
});

test("reports again when the page changes its icon, and only then", async (t) => {
  const page = await open(t, `<link id="icon" rel="icon" href="/one.png">`);
  await page.evaluate(() => {
    document.title = "Changed";
    document.getElementById("icon")!.setAttribute("href", "/two.png");
  });
  await page.waitForFunction(() => (window as any).relayMessages.length === 2);
  // Running the script again, as after the next load event, posts the list
  // once more but adds no second watcher.
  await page.evaluate(script);
  await page.evaluate(() => document.getElementById("icon")!.setAttribute("href", "/three.png"));
  await page.waitForFunction(() => (window as any).relayMessages.length >= 4);
  await page.evaluate(() => new Promise(requestAnimationFrame));
  assert.deepEqual((await reports(page)).map((report) => report.icons[0]), ["https://site.test/one.png",
    "https://site.test/two.png", "https://site.test/two.png", "https://site.test/three.png"]);
});

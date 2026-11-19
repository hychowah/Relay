import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chromium, type Frame } from "playwright";

// The Flutter Browser tab's fullscreen script, run in headless Chromium as a
// stand-in for WKWebView. The web view is the tab's pane, so filling the
// viewport is filling the pane.
const script = (await readFile(new URL("../flutter/assets/page_fullscreen.js", import.meta.url), "utf8"))
  .replace("RELAY_KEY", '"key"');

// A player inside a transformed ancestor, below a fixed header that is above
// it, as on video sites; and an embedded player from another site.
const site = `<!doctype html><title>Site</title><style>body{margin:0}
  header{position:fixed;top:0;left:0;right:0;height:60px;z-index:50;background:#ddd}
  main{transform:translateX(0);margin:80px 0 0 40px;width:320px}</style>
  <header>Header</header>
  <main><div id="player" style="height:180px;background:#246">
    <button id="full" onclick="this.parentElement.requestFullscreen()">Full</button></div></main>
  <iframe id="embed" src="https://player.test/embed" width="300" height="160" allowfullscreen></iframe>
  <iframe id="plain" src="https://player.test/embed" width="300" height="160"></iframe>
  <script>
    window.changes = [];
    document.addEventListener("fullscreenchange", () => changes.push(document.fullscreenElement?.id ?? null));
    // Without a click or key press, a page cannot take the screen, and it
    // cannot catch the script's messages to Relay.
    document.getElementById("player").requestFullscreen().catch(() => window.refused = true);
    window.RelayBrowser = { postMessage() {} };
  </script>`;
const embed = `<!doctype html><title>Embed</title><body style="margin:0">
  <video id="video" style="width:200px;height:100px"></video>
  <button id="full" onclick="document.getElementById('video').webkitEnterFullscreen()">Full</button>`;

test("a page's fullscreen element fills the tab's view and Escape ends it", async (t) => {
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());
  const page = await browser.newPage({ viewport: { width: 800, height: 500 } });
  // A string, because tsx adds helpers to functions that the page lacks.
  await page.addInitScript("window.relayMessages = []; window.RelayBrowser = { postMessage: (m) => relayMessages.push(m) };");
  await page.addInitScript({ content: script });
  await page.route("https://**/*", (route) =>
    route.fulfill({ contentType: "text/html", body: new URL(route.request().url()).host === "site.test" ? site : embed }));
  await page.goto("https://site.test/");
  const box = (frame: Frame, selector: string) => frame.locator(selector).evaluate((element) => {
    const { x, y, width, height } = element.getBoundingClientRect();
    return { x, y, width, height };
  });
  const top = page.mainFrame();
  const state = () => top.evaluate(() => ({
    element: document.fullscreenElement?.id ?? null,
    messages: (window as any).relayMessages,
    changes: (window as any).changes,
  }));

  assert.equal(await top.evaluate(() => (window as any).refused), true);
  assert.equal(await top.evaluate(() => document.fullscreenEnabled), true);

  await page.click("#full");
  assert.deepEqual(await box(top, "#player"), { x: 0, y: 0, width: 800, height: 500 });
  // Above the page's own fixed header, despite the transformed ancestor.
  assert.equal(await top.evaluate(() => document.elementFromPoint(400, 20)?.closest("#player")?.id), "player");
  assert.deepEqual(await state(), { element: "player", messages: ["fullscreen:enter:key"], changes: ["player"] });

  await page.keyboard.press("Escape");
  assert.deepEqual(await box(top, "#player"), { x: 40, y: 80, width: 320, height: 180 });
  assert.deepEqual(await state(), {
    element: null,
    messages: ["fullscreen:enter:key", "fullscreen:exit:key"],
    changes: ["player", null],
  });

  // An embedded player that allows fullscreen fills the page with its frame.
  const [embedded, plain] = await Promise.all(["#embed", "#plain"].map(async (selector) =>
    (await page.locator(selector).elementHandle())!.contentFrame()));
  await embedded!.click("#full");
  await page.waitForFunction(() => document.fullscreenElement?.id === "embed");
  assert.deepEqual(await box(top, "#embed"), { x: 0, y: 0, width: 800, height: 500 });
  assert.deepEqual(await box(embedded!, "#video"), { x: 0, y: 0, width: 800, height: 500 });
  await embedded!.press("#full", "Escape");
  await page.waitForFunction(() => document.fullscreenElement === null);
  assert.equal(await embedded!.evaluate(() => document.fullscreenElement), null);
  assert.deepEqual((await state()).messages, ["fullscreen:enter:key", "fullscreen:exit:key", "fullscreen:enter:key", "fullscreen:exit:key"]);

  // A frame that does not allow fullscreen fills only its own frame.
  await plain!.click("#full");
  assert.deepEqual(await box(plain!, "#video"), { x: 0, y: 0, width: 300, height: 160 });
  await page.waitForTimeout(100);
  assert.equal((await state()).element, null);
});

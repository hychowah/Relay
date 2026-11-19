import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chromium, type Browser, type Frame } from "playwright";

// The Flutter Browser tab's fullscreen script, run in headless Chromium as a
// stand-in for WKWebView. The web view is the tab's pane, so filling the
// viewport is filling the pane.
const script = (await readFile(new URL("../flutter/assets/page_fullscreen.js", import.meta.url), "utf8"))
  .replace("RELAY_KEY", '"key"');

// A player inside a transformed ancestor, below a fixed header that is above
// it, as on video sites, with a frame of its own; and two embedded players
// from another site, one allowed fullscreen.
const pages: Record<string, string> = {
  "site.test": `<!doctype html><title>Site</title><style>body{margin:0}
    header{position:fixed;top:0;left:0;right:0;height:60px;z-index:50;background:#ddd}
    main{transform:translateX(0);margin:80px 0 0 40px;width:320px}</style>
    <header>Header</header>
    <main><div id="player" style="height:180px;background:#246">
      <button id="full" onclick="this.parentElement.requestFullscreen()">Full</button>
      <iframe id="inner" src="https://player.test/inner" width="120" height="60"></iframe></div></main>
    <iframe id="embed" src="https://player.test/embed" width="300" height="160" allowfullscreen></iframe>
    <iframe id="plain" src="https://player.test/embed" width="300" height="160"></iframe>
    <button id="pop" onclick="window.open('https://player.test/popup', 'pop', 'width=400,height=300')">Popup</button>
    <script>
      window.changes = [];
      document.addEventListener("fullscreenchange", () => changes.push(document.fullscreenElement?.id ?? null));
      // Without a click or key press, a page cannot take the screen, and it
      // cannot catch the script's messages to Relay.
      document.getElementById("player").requestFullscreen().catch(() => window.refused = true);
      window.RelayBrowser = { postMessage() {} };
    </script>`,
  "player.test": `<!doctype html><title>Embed</title><body style="margin:0">
    <video id="video" style="width:200px;height:100px"></video>
    <button id="full" onclick="document.getElementById('video').webkitEnterFullscreen()">Full</button>`,
  // Pages that try to take the screen with no click: one fakes the click
  // state, and its frame, which allows fullscreen, asks for it directly.
  "attack.test": `<!doctype html><div id="player"></div>
    <iframe src="https://forge.test/" allowfullscreen></iframe>
    <script>
      Object.defineProperty(navigator, "userActivation", { value: { isActive: true } });
      document.getElementById("player").requestFullscreen().catch(() => {});
    </script>`,
  "forge.test": `<!doctype html><script>parent.postMessage({ relayFullscreen: "enter" }, "*");</script>`,
};

// Popup windows get the same scripts, as they share the tab's in WebKit.
async function open(browser: Browser, url: string) {
  const context = await browser.newContext({ viewport: { width: 800, height: 500 } });
  // A string, because tsx adds helpers to functions that the page lacks.
  await context.addInitScript("window.relayMessages = []; window.RelayBrowser = { postMessage: (m) => relayMessages.push(m) };");
  await context.addInitScript({ content: script });
  await context.route("https://**/*", (route) =>
    route.fulfill({ contentType: "text/html", body: pages[new URL(route.request().url()).host] }));
  const page = await context.newPage();
  await page.goto(url);
  return page;
}

test("a page's fullscreen element fills the tab's view and the user can always leave", async (t) => {
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());
  const page = await open(browser, "https://site.test/");
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
  const frame = async (selector: string) => (await page.locator(selector).elementHandle())!.contentFrame() as Promise<Frame>;
  const told = (count: number, last: string) => page.waitForFunction(([count, last]) =>
    (window as any).relayMessages.length === count && (window as any).relayMessages.at(-1) === last, [count, last] as const);

  assert.equal(await top.evaluate(() => (window as any).refused), true);
  assert.equal(await top.evaluate(() => document.fullscreenEnabled), true);

  await page.click("#full");
  assert.deepEqual(await box(top, "#player"), { x: 0, y: 0, width: 800, height: 500 });
  // Above the page's own fixed header, despite the transformed ancestor.
  assert.equal(await top.evaluate(() => document.elementFromPoint(400, 20)?.closest("#player")?.id), "player");
  assert.deepEqual(await state(), { element: "player", messages: ["fullscreen:enter:key"], changes: ["player"] });

  // A page that breaks the event calls cannot keep Escape from ending it.
  await top.evaluate(`
    Event.prototype.preventDefault = Event.prototype.stopImmediatePropagation = () => { throw new Error("blocked"); };
    Object.defineProperty(KeyboardEvent.prototype, "key", { get: () => "x" });
  `);
  await page.keyboard.press("Escape");
  assert.deepEqual(await box(top, "#player"), { x: 40, y: 80, width: 320, height: 180 });
  assert.deepEqual(await state(), {
    element: null,
    messages: ["fullscreen:enter:key", "fullscreen:exit:key"],
    changes: ["player", null],
  });

  // Escape with focus in a frame inside the fullscreen element ends it too.
  await page.click("#full");
  await (await frame("#inner")).press("#full", "Escape");
  await told(4, "fullscreen:exit:key");
  assert.equal((await state()).element, null);

  // An embedded player that allows fullscreen fills the page with its frame.
  const embedded = await frame("#embed");
  await embedded.click("#full");
  await told(5, "fullscreen:enter:key");
  assert.equal((await state()).element, "embed");
  assert.deepEqual(await box(top, "#embed"), { x: 0, y: 0, width: 800, height: 500 });
  assert.deepEqual(await box(embedded, "#video"), { x: 0, y: 0, width: 800, height: 500 });
  await embedded.press("#full", "Escape");
  await told(6, "fullscreen:exit:key");
  assert.equal(await embedded.evaluate(() => document.fullscreenElement), null);

  // A frame that does not allow fullscreen fills only its own frame.
  const plain = await frame("#plain");
  await plain.click("#full");
  assert.deepEqual(await box(plain, "#video"), { x: 0, y: 0, width: 300, height: 160 });
  await page.waitForTimeout(100);
  assert.equal((await state()).messages.length, 6);

  // A video in a popup window fills only the popup and leaves Relay alone.
  const [popup] = await Promise.all([page.waitForEvent("popup"), page.click("#pop")]);
  await popup.click("#full");
  assert.deepEqual(await popup.evaluate(() => [document.fullscreenElement?.id, (window as any).relayMessages]), ["video", []]);
  assert.equal((await state()).messages.length, 6);
  await popup.close();

  // As in a browser, fullscreen ends when its element leaves the page.
  await page.click("#full");
  await told(7, "fullscreen:enter:key");
  await top.evaluate(() => document.getElementById("player")!.remove());
  await told(8, "fullscreen:exit:key");
  assert.equal((await state()).element, null);
});

test("a page cannot take the screen without a click", async (t) => {
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());
  const page = await open(browser, "https://attack.test/");
  await page.waitForTimeout(300);
  assert.deepEqual(await page.evaluate(() => ({
    element: document.fullscreenElement,
    messages: (window as any).relayMessages,
  })), { element: null, messages: [] });
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chromium, type Page } from "playwright";

// The Flutter Browser tab's highlight script, run in headless Chromium as a
// stand-in for WKWebView.
const script = await readFile(new URL("../flutter/assets/page_highlights.js", import.meta.url), "utf8");

// The same words twice, so only the text around a quote tells them apart,
// and a view the page can draw again or swap under one address.
const article = `<h1>Thumb gear</h1>
  <p id="first">The worm drives the <b>sector gear</b> through a
     small angle.</p>
  <p id="second">A second paragraph says the worm drives the sector gear again.</p>`;

async function open(t: test.TestContext) {
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());
  const page = await browser.newPage();
  await page.setContent(`<!doctype html><title>Article</title><main id="app">${article}</main>`);
  // What the script tells Relay, as the Browser tab's page channel.
  await page.evaluate("window.posted = []; window.RelayBrowser = { postMessage: (message) => posted.push(message) }");
  await page.evaluate(script);
  return page;
}

/** Selects from [from] to the end of [to] inside the paragraph [id]. */
const select = (page: Page, id: string, from: string, to: string) => page.evaluate(([id, from, to]) => {
  const walker = document.createTreeWalker(document.getElementById(id)!, NodeFilter.SHOW_TEXT);
  const range = document.createRange();
  let started = false;
  for (let node; (node = walker.nextNode() as Text | null);) {
    if (!started && node.data.includes(from)) {
      range.setStart(node, node.data.indexOf(from));
      started = true;
    }
    if (started && node.data.includes(to)) {
      range.setEnd(node, node.data.indexOf(to) + to.length);
      break;
    }
  }
  getSelection()!.removeAllRanges();
  getSelection()!.addRange(range);
}, [id, from, to]);

const add = (page: Page, id: string, color = "yellow") =>
  page.evaluate(([id, color]) => (window as any).__relayHighlights.add(id, color), [id, color]);
const draw = (page: Page, html: string) => page.evaluate((html) => { document.getElementById("app")!.innerHTML = html; }, html);

/** The highlights painted now: their text and the paragraph each is in, once the page has settled. */
async function painted(page: Page) {
  await page.waitForTimeout(1600);
  return page.evaluate(() => [...((CSS as any).highlights.get("relay-highlight-yellow") ?? [])].map((range: Range) => ({
    text: range.toString().replace(/\s+/g, " "),
    paragraph: range.startContainer.parentElement!.closest("p")?.id,
    shown: range.startContainer.isConnected,
  })));
}

/** The text painted in each colour now. */
const colours = (page: Page) => page.evaluate(() => Object.fromEntries([...(CSS as any).highlights]
  .map(([name, ranges]: [string, Set<Range>]) => [name.replace("relay-highlight-", ""), [...ranges].map(String)])));

/** The menu messages the script has sent since the last call. */
const menus = (page: Page) => page.evaluate(() => (window as any).posted.splice(0)
  .filter((message: string) => message.startsWith("menu:"))
  .map((message: string) => message === "menu:" ? null : JSON.parse(message.slice(5))));

test("a highlight quotes the selected text and its surroundings, and paints it", async (t) => {
  const page = await open(t);
  await select(page, "first", "sector", "small");
  assert.deepEqual(await add(page, "one"), { added: {
    text: "sector gear through a small", prefix: "Thumb gear The worm drives the ", suffix: " angle. A second paragraph says the worm",
  } });
  assert.equal(await page.evaluate(() => getSelection()!.isCollapsed), true);
  assert.deepEqual(await painted(page), [{ text: "sector gear through a small", paragraph: "first", shown: true }]);
  assert.equal(await page.locator("#app").innerHTML(), article, "the page's own elements are untouched");

  await page.evaluate(() => (window as any).__relayHighlights.remove("one"));
  assert.deepEqual(await painted(page), []);
  assert.equal(await add(page, "three"), null, "nothing is selected");
});

test("a kept highlight goes on the text it quotes, where its surroundings match", async (t) => {
  const page = await open(t);
  await select(page, "second", "sector", "gear");
  const { added } = await add(page, "second-gear");
  assert.equal(added.text, "sector gear");

  // The page as it is on a later visit.
  const again = await open(t);
  await again.evaluate((kept) => (window as any).__relayHighlights.set(kept), [{ id: "second-gear", ...added }]);
  assert.deepEqual(await painted(again), [{ text: "sector gear", paragraph: "second", shown: true }]);
});

test("a highlight follows a page that redraws or changes its content under one address", async (t) => {
  const page = await open(t);
  await select(page, "first", "sector", "small");
  await add(page, "one");
  const shown = [{ text: "sector gear through a small", paragraph: "first", shown: true }];
  assert.deepEqual(await painted(page), shown);

  // A single-page app draws the same view again with new elements.
  await draw(page, article);
  assert.deepEqual(await painted(page), shown);

  // Another view under the same address has no such text: nothing is painted.
  await draw(page, "<p>Another view, with other words.</p>");
  assert.deepEqual(await painted(page), []);

  // Text that changes inside the same element is checked too.
  await draw(page, article);
  assert.deepEqual(await painted(page), shown);
  await page.evaluate(() => { document.querySelector("#first b")!.firstChild!.nodeValue = "pinion"; });
  assert.deepEqual(await painted(page), []);

  // Back on the first view, the highlight returns.
  await draw(page, article);
  assert.deepEqual(await painted(page), shown);
});

test("a highlight goes on the text selected before the page lost focus", async (t) => {
  const page = await open(t);
  // WKWebView clears the selection once a click on Relay's menu takes
  // focus from the page, possibly while the page still reports focus.
  await select(page, "first", "sector", "gear");
  await page.evaluate("getSelection().removeAllRanges()");
  await page.waitForTimeout(50);
  assert.equal((await add(page, "out-of-focus"))?.added.text, "sector gear");
  assert.equal(await add(page, "again"), null, "the selection was used once");

  // A press in the page starts again: the text selected before is not used.
  await select(page, "second", "second", "paragraph");
  await page.mouse.click(5, 5);
  await page.evaluate("getSelection().removeAllRanges()");
  await page.waitForTimeout(50);
  assert.equal(await add(page, "cleared"), null);
});

test("a highlight has a colour that can change", async (t) => {
  const page = await open(t);
  await page.evaluate(() => (window as any).__relayHighlights.set([
    { id: "old", text: "small angle", prefix: "", suffix: "" },
  ]));
  await select(page, "second", "second", "paragraph");
  await add(page, "new", "blue");
  assert.deepEqual(await colours(page), { yellow: ["small angle"], blue: ["second paragraph"] });
  await page.evaluate(() => (window as any).__relayHighlights.recolor("old", "pink"));
  assert.deepEqual(await colours(page), { pink: ["small angle"], blue: ["second paragraph"] });
});

test("Relay hears where to show its menu: by released selected text, or a clicked highlight", async (t) => {
  const page = await open(t);
  const box = await page.locator("#second").boundingBox();
  const y = box!.y + box!.height / 2;

  // Dragging shows nothing until the mouse is released.
  await page.mouse.move(box!.x + 2, y);
  await page.mouse.down();
  await page.mouse.move(box!.x + 120, y, { steps: 5 });
  await page.waitForTimeout(400);
  assert.deepEqual(await menus(page), []);
  await page.mouse.up();
  await page.waitForTimeout(50);
  const [shown] = await menus(page);
  assert.equal(shown.id, undefined);
  assert.ok(shown.rect.left >= box!.x - 1 && shown.rect.right <= box!.x + 121 && shown.rect.top < y && shown.rect.bottom > y);

  // Highlighting takes the selection, and nothing more is sent.
  await add(page, "kept", "green");
  await page.waitForTimeout(350);
  assert.deepEqual(await menus(page), []);

  // A click on the highlight names it; a click elsewhere hides the menu.
  await page.mouse.click(box!.x + 30, y);
  await page.waitForTimeout(50);
  assert.deepEqual((await menus(page)).map((menu: { id?: string } | null) => menu?.id), ["kept"]);
  await page.mouse.click(box!.x + 30, y + 200);
  await page.waitForTimeout(50);
  assert.deepEqual(await menus(page), [null]);

  // Selected text in a text field is not offered.
  await page.evaluate(() => document.body.insertAdjacentHTML("beforeend", "<textarea id=field>typed words</textarea>"));
  await page.locator("#field").click();
  await page.keyboard.press("ControlOrMeta+A");
  await page.waitForTimeout(400);
  assert.deepEqual(await menus(page), []);
});

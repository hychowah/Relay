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

const toggle = (page: Page, id: string) => page.evaluate((id) => (window as any).__relayHighlights.toggle(id), id);
const draw = (page: Page, html: string) => page.evaluate((html) => { document.getElementById("app")!.innerHTML = html; }, html);

/** The highlights painted now: their text and the paragraph each is in, once the page has settled. */
async function painted(page: Page) {
  await page.waitForTimeout(1600);
  return page.evaluate(() => [...((CSS as any).highlights.get("relay-highlight") ?? [])].map((range: Range) => ({
    text: range.toString().replace(/\s+/g, " "),
    paragraph: range.startContainer.parentElement!.closest("p")?.id,
    shown: range.startContainer.isConnected,
  })));
}

test("a highlight quotes the selected text and its surroundings, and paints it", async (t) => {
  const page = await open(t);
  await select(page, "first", "sector", "small");
  assert.deepEqual(await toggle(page, "one"), { added: {
    text: "sector gear through a small", prefix: "Thumb gear The worm drives the ", suffix: " angle. A second paragraph says the worm",
  } });
  assert.equal(await page.evaluate(() => getSelection()!.isCollapsed), true);
  assert.deepEqual(await painted(page), [{ text: "sector gear through a small", paragraph: "first", shown: true }]);
  assert.equal(await page.locator("#app").innerHTML(), article, "the page's own elements are untouched");

  // Selected text that touches a highlight removes it.
  await select(page, "first", "gear", "through");
  assert.deepEqual(await toggle(page, "two"), { removed: ["one"] });
  assert.deepEqual(await painted(page), []);
  assert.equal(await toggle(page, "three"), null, "nothing is selected");
});

test("a kept highlight goes on the text it quotes, where its surroundings match", async (t) => {
  const page = await open(t);
  await select(page, "second", "sector", "gear");
  const { added } = await toggle(page, "second-gear");
  assert.equal(added.text, "sector gear");

  // The page as it is on a later visit.
  const again = await open(t);
  await again.evaluate((kept) => (window as any).__relayHighlights.set(kept), [{ id: "second-gear", ...added }]);
  assert.deepEqual(await painted(again), [{ text: "sector gear", paragraph: "second", shown: true }]);
});

test("a highlight follows a page that redraws or changes its content under one address", async (t) => {
  const page = await open(t);
  await select(page, "first", "sector", "small");
  await toggle(page, "one");
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

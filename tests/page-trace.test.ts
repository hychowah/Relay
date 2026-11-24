import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";

// The Flutter Browser tab's bug-recording trace script, run in headless
// Chromium as a stand-in for WKWebView, with real mouse input.
const script = await readFile(new URL("../flutter/assets/page_trace.js", import.meta.url), "utf8");

const html = `<!doctype html><title>Trace</title>
  <style>body{margin:0} a{display:block;height:40px} #list{height:120px;overflow:auto}</style>
  <nav id="list"><a href="#1"><span>Provide URL</span></a><a href="#2"><span>Explain Flutter</span></a>
    <div style="height:400px"></div></nav>
  <input id="field" value="secret words">`;

async function open(t: test.TestContext) {
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());
  const page = await browser.newPage();
  await page.setContent(html);
  await page.evaluate("window.posted = []; window.RelayBrowser = { postMessage: (message) => posted.push(message) }");
  await page.evaluate(script);
  return page;
}

/**
 * The notes sent since the last call, once the current batch has gone. A
 * loaded machine's headless window can resize at any time; that is left out.
 */
async function notes(page: import("playwright").Page) {
  await page.waitForTimeout(400);
  const sent: string[] = await page.evaluate(() => (window as any).posted.splice(0));
  return sent.flatMap((message) => {
    assert.ok(message.startsWith("trace:"));
    return JSON.parse(message.slice(6)).map(({ at, ...note }: any) => {
      assert.equal(typeof at, "number");
      return note;
    });
  }).filter((note) => note.kind !== "resize");
}

test("the trace notes the item under the mouse, its loss, jumps and scrolling, never field text", async (t) => {
  const page = await open(t);
  assert.deepEqual((await notes(page)).map((note) => note.kind), ["trace start"]);

  // Moving inside one link notes it once, by the link rather than its span.
  await page.mouse.move(10, 10);
  await page.mouse.move(12, 14);
  await page.mouse.move(30, 70);
  const moves = await notes(page);
  assert.deepEqual(moves.filter((note) => note.kind === "hover"), [
    { kind: "hover", x: 10, y: 10, target: 'a "Provide URL"' },
    { kind: "hover", x: 30, y: 70, target: 'a "Explain Flutter"' },
  ]);
  assert.ok(moves.some((note) => note.kind === "pointer jump" && note.fromX === 12 && note.y === 70));

  await page.mouse.wheel(0, 30);
  const scrolled = await notes(page);
  assert.ok(scrolled.some((note) => note.kind === "wheel" && note.dy === 30));
  assert.ok(scrolled.some((note) => note.kind === "scroll" && note.target.startsWith("nav#list") && note.top === 30));

  // The mouse leaving the page, then coming back to the same item (the list
  // is now scrolled by 30 pixels).
  await page.mouse.move(30, 30);
  await notes(page);
  await page.mouse.move(-20, -20);
  await page.mouse.move(30, 30);
  assert.deepEqual((await notes(page)).filter((note) => note.kind.startsWith("hover")).map((note) => note.kind + " " + (note.target ?? "")), [
    "hover lost ", 'hover a "Explain Flutter"',
  ]);

  // A page's own event is marked, and a field is named without its text.
  await page.evaluate(() => document.querySelector("#list a")!.dispatchEvent(new MouseEvent("mouseover", { bubbles: true })));
  const field = await page.locator("#field").boundingBox();
  await page.mouse.move(field!.x + 5, field!.y + 5);
  const other = await notes(page);
  assert.ok(other.some((note) => note.kind === "hover" && note.target === 'a "Provide URL"' && note.synthetic === true));
  assert.ok(other.some((note) => note.kind === "hover" && note.target === "input#field"));
  assert.ok(!JSON.stringify(other).includes("secret"));

  // Stopped, it notes nothing; run again in the same document, it starts again.
  await page.evaluate(() => (window as any).__relayTrace.stop());
  await page.mouse.move(10, 10);
  assert.deepEqual(await notes(page), []);
  await page.evaluate(script);
  assert.deepEqual((await notes(page)).map((note) => note.kind), ["trace start"]);
});

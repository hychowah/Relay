import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chromium, type Page } from "playwright";

// The Flutter Browser tab's form script, run in headless Chromium as a
// stand-in for WKWebView, called the way web_page.dart calls it.
const script = await readFile(new URL("../flutter/assets/page_forms.js", import.meta.url), "utf8");

// A synthetic sign-up form below a tall heading, so a fill has to scroll to
// it, with fields that are there but that a person cannot see.
const form = `<div style="height:2000px">Top of the page</div>
<form id="signup" name="signup" action="/apply">
  <label>Full name <span style="position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%)">(as on your passport)</span>
    <input name="name" placeholder="Jane Doe"></label>
  <label for="email">Email</label><input id="email" type="email" name="email" required>
  <label>Nickname <input id="controlled" name="nickname" style="outline:1px dotted red"></label>
  <label>About you <textarea name="about">Already typed</textarea></label>
  <label>Country <select name="country"><option value="">Choose</option><option value="jp">Japan</option><option value="nz">New Zealand</option>
    <optgroup label="Closed" disabled><option value="aq">Antarctica</option></optgroup></select></label>
  <fieldset><legend>Plan</legend>
    <label><input type="radio" name="plan" value="basic" checked> Basic</label>
    <label><input type="radio" name="plan" value="pro"> Pro</label>
  </fieldset>
  <label><input type="checkbox" name="terms"> I agree</label>
  <label><input type="checkbox" name="news" style="opacity:0;position:absolute"> Send me news</label>
  <label>Birthday <input type="date" name="birthday"></label>
  <label>Password <input type="password" name="password" value="secret-value"></label>
  <label>Passport scan <input type="file" name="scan"></label>
  <label>Member number <input name="member" value="A-1" disabled></label>
  <input type="hidden" name="token" value="csrf">
  <input name="undisplayed" style="display:none">
  <div style="opacity:0"><input name="seethrough"></div>
  <input name="offpage" style="position:absolute;left:-9999px">
  <input name="dot" style="position:absolute;width:1px;height:1px;clip-path:inset(50%)">
  <span style="position:relative;display:inline-block"><input name="covered"><span style="position:absolute;inset:0;background:white"></span></span>
  <div style="height:0;overflow:hidden"><input name="clipped"></div>
  <button id="send" type="submit">Submit</button>
</form>
<iframe srcdoc="<label>Coupon <input name=coupon></label>"></iframe>
<iframe style="opacity:0" srcdoc="<label>Ghost <input name=ghost></label>"></iframe>
<iframe style="width:300px;height:100px" src="data:text/html,<input name=card>"></iframe>`;

async function open(t: test.TestContext, body = form) {
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());
  const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
  await page.route("https://forms.test/**", (route) => route.fulfill({ contentType: "text/html",
    body: `<!doctype html><title>Sign up</title>${body}` }));
  await page.goto("https://forms.test/signup");
  await page.evaluate(() => {
    const w = window as any;
    // Anything that would submit or click is counted.
    w.submits = 0;
    w.inputs = 0;
    document.addEventListener("input", () => w.inputs++, true);
    document.addEventListener("submit", (event) => { event.preventDefault(); w.submits++; });
    document.getElementById("send")?.addEventListener("click", () => w.submits++);
    for (const name of ["submit", "requestSubmit"] as const) {
      const original = HTMLFormElement.prototype[name];
      HTMLFormElement.prototype[name] = function (this: HTMLFormElement, ...args: any[]) { w.submits++; return (original as any).apply(this, args); };
    }
    document.addEventListener("keydown", () => w.submits++, true);
    // React's value tracker: it notes values set through the element and
    // ignores an input event whose value it already knows.
    const input = document.getElementById("controlled") as HTMLInputElement | null;
    if (!input) return;
    const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!;
    let tracked = input.value;
    w.reactState = "";
    Object.defineProperty(input, "value", { configurable: true,
      get() { return native.get!.call(this); }, set(value) { tracked = value; native.set!.call(this, value); } });
    input.addEventListener("input", () => { if (input.value !== tracked) { tracked = input.value; w.reactState = input.value; } });
  });
  if (body === form)
    await page.waitForFunction(() => document.querySelectorAll("iframe")[0].contentDocument?.querySelector("input"));
  return page;
}

const run = (page: Page, action: string, request?: unknown) =>
  page.evaluate(`JSON.parse(JSON.stringify((${script})(${JSON.stringify(action)}, ${JSON.stringify(request ?? null)})))`) as Promise<any>;
const idsOf = (read: any) => Object.fromEntries(read.fields.map((field: any) => [field.name, field.id]));
const outlined = (page: Page) => page.evaluate(() =>
  [...document.querySelectorAll("[data-relay-filled]")].map((el) => (el as HTMLInputElement).name || el.tagName));

test("a form read lists only fields a person can see, with no typed text", async (t) => {
  const page = await open(t);
  const read = await run(page, "read");
  assert.match(read.token, /^[0-9a-f]{32}$/);
  assert.deepEqual(read.forms, [{ form: "form1", action: "https://forms.test/apply" }]);
  assert.equal(read.otherSiteFrames, 1, "the other site's frame is counted, not read");
  const byName = Object.fromEntries(read.fields.map((field: any) => [field.name, field]));
  assert.deepEqual(Object.keys(byName), ["name", "email", "nickname", "about", "country", "plan", "terms", "news", "birthday",
    "password", "scan", "member", "coupon"], "hidden, see-through, off-page, tiny, covered and clipped fields are not listed");
  assert.deepEqual(byName.name, { id: "f1", type: "text", form: "form1", label: "Full name", name: "name", placeholder: "Jane Doe",
    required: false, empty: true }, "a label leaves out text that does not draw");
  assert.equal(byName.about.empty, false);
  assert.equal(byName.email.required, true);
  assert.equal(byName.email.label, "Email");
  assert.equal(byName.country.label, "Country", "a label leaves out the list's options");
  assert.deepEqual(byName.country.options.slice(1), [{ value: "jp", label: "Japan" }, { value: "nz", label: "New Zealand" },
    { value: "aq", label: "Antarctica", fillable: false }]);
  assert.deepEqual(byName.plan, { id: byName.plan.id, type: "radio", form: "form1", label: "Plan", name: "plan", required: false,
    value: "basic", options: [{ value: "basic", label: "Basic" }, { value: "pro", label: "Pro" }] });
  assert.equal(byName.news.label, "Send me news", "a styled check box shows through its label");
  assert.deepEqual(byName.password, { id: byName.password.id, type: "password", form: "form1", label: "Password", name: "password",
    required: false, fillable: false, reason: "Password fields are left to the user." });
  assert.equal(byName.scan.fillable, false);
  assert.equal(byName.member.reason, "The field is disabled.");
  assert.equal(byName.coupon.form, undefined);
  assert.doesNotMatch(JSON.stringify(read), /secret-value|csrf|Already typed|A-1/);
  assert.equal(await page.evaluate(() => scrollY), 0, "checking fields below the fold leaves the page where it was");
  assert.notEqual((await run(page, "read")).token, read.token, "each read has its own token");

  // A long list keeps every option; only a reply too large for the socket is cut short.
  await page.evaluate(() => document.body.insertAdjacentHTML("beforeend",
    `<select name="year">${Array.from({ length: 250 }, (_, i) => `<option>${1900 + i}</option>`).join("")}</select>`
    + Array.from({ length: 250 }, (_, i) => `<select name="list${i}">${"<option>一二三四五六七八九十</option>".repeat(20)}</select>`).join("")));
  const long = await run(page, "read");
  assert.equal(long.fields.find((field: any) => field.name === "year").options.length, 250);
  assert.equal(long.truncated, true);
  assert.ok(Buffer.byteLength(JSON.stringify(long)) < 200000);
});

test("a fill sets fields as typing would, keeps outlines and does not submit", async (t) => {
  const page = await open(t);
  const read = await run(page, "read");
  const ids = idsOf(read);
  const filled = await run(page, "fill", { token: read.token, fields: [
    { id: ids.name, value: "Ada Lovelace" },
    { id: ids.email, value: "ada@example.com" },
    { id: ids.nickname, value: "Ada" },
    { id: ids.country, value: "New Zealand" },
    { id: ids.plan, value: "Pro" },
    { id: ids.terms, value: true },
    { id: ids.news, value: "yes" },
    { id: ids.birthday, value: "1815-12-10" },
    { id: ids.coupon, value: "SAVE" },
    { id: ids.password, value: "guess" },
    { id: ids.scan, value: "/tmp/passport.png" },
    { id: ids.member, value: "B-2" },
    { id: "f500", value: "x" },
  ] });
  const status = Object.fromEntries(filled.results.map((result: any) => [result.id, result.status]));
  assert.equal(filled.filled, 9);
  assert.equal(filled.pageSubmitted, undefined);
  for (const name of ["name", "email", "nickname", "country", "plan", "terms", "news", "birthday", "coupon"])
    assert.equal(status[ids[name]], "filled", name);
  for (const name of ["password", "scan", "member"]) assert.equal(status[ids[name]], "refused", name);
  assert.equal(status.f500, "not found");

  const after = await page.evaluate(() => {
    const form = document.getElementById("signup") as HTMLFormElement;
    const frame = document.querySelector("iframe")!.contentDocument!;
    return {
      values: ["name", "email", "nickname", "country", "plan", "birthday", "password", "member"]
        .map((name) => (form.elements.namedItem(name) as HTMLInputElement).value),
      boxes: ["terms", "news"].map((name) => (form.elements.namedItem(name) as HTMLInputElement).checked),
      coupon: (frame.querySelector("input") as HTMLInputElement).value,
      reactState: (window as any).reactState,
      submits: (window as any).submits,
      outline: getComputedStyle(form.elements.namedItem("name") as Element).outlineStyle,
      ownStyle: document.getElementById("controlled")!.getAttribute("style"),
    };
  });
  assert.deepEqual(after.values, ["Ada Lovelace", "ada@example.com", "Ada", "nz", "pro", "1815-12-10", "secret-value", "A-1"]);
  assert.deepEqual(after.boxes, [true, true]);
  assert.equal(after.coupon, "SAVE", "a same-site frame's field is filled");
  assert.equal(after.reactState, "Ada", "a React-style controlled input sees the change");
  assert.equal(after.submits, 0, "nothing was submitted, clicked on the button or typed");
  assert.equal(after.outline, "solid");
  assert.equal(after.ownStyle, "outline:1px dotted red", "the page's own inline outline is left alone");
  // Scrolls smoothly to the first filled field.
  await page.waitForFunction(() => scrollY > 1000, null, { timeout: 3000 });

  // A retry of one field keeps the earlier outlines. Unclear words, a closed
  // option and a value the field does not take are refused, the field as it was.
  const again = await run(page, "fill", { token: read.token, fields: [
    { id: ids.birthday, value: "10 Dec 1815" }, { id: ids.terms, value: "agree" },
    { id: ids.country, value: "Antarctica" }, { id: ids.about, value: "More" },
  ] });
  assert.deepEqual(again.results.map((result: any) => result.status), ["refused", "refused", "refused", "filled"]);
  assert.match(again.results[0].reason, /YYYY-MM-DD/);
  assert.match(again.results[1].reason, /true .* false/);
  assert.deepEqual(await page.evaluate(() => [
    (document.querySelector("[name=birthday]") as HTMLInputElement).value,
    (document.querySelector("[name=terms]") as HTMLInputElement).checked,
    (document.querySelector("[name=country]") as HTMLSelectElement).value,
  ]), ["1815-12-10", true, "nz"]);
  assert.deepEqual(await outlined(page), ["name", "email", "nickname", "about", "country", "LABEL", "plan", "LABEL", "terms",
    "LABEL", "news", "birthday"]);
  assert.equal((await run(page, "fill", { token: read.token, fields: [{ id: ids.terms, value: "no" }] })).filled, 1);
  assert.equal(await page.evaluate(() => (document.querySelector("[name=terms]") as HTMLInputElement).checked), false);
});

test("a fill after the page changed is refused before any value goes in", async (t) => {
  const page = await open(t);
  const read = await run(page, "read");
  const ids = idsOf(read);
  const inputs = () => page.evaluate(() => (window as any).inputs);

  assert.equal((await run(page, "token")).token, read.token);
  assert.match((await run(page, "fill", { token: "0".repeat(32), fields: [{ id: ids.name, value: "Ada" }] })).error, /read the form again/);

  // A field that a form step reuses for another question, and one hidden since the read.
  await page.evaluate(() => {
    document.querySelector("label")!.firstChild!.textContent = "Card number ";
    (document.querySelector("[name=email]") as HTMLElement).style.visibility = "hidden";
  });
  const changed = await run(page, "fill", { token: read.token, fields: [{ id: ids.name, value: "Ada" }, { id: ids.email, value: "a@b.c" }] });
  assert.deepEqual(changed.results.map((result: any) => result.reason), [
    "This field changed since browser.form; read the form again.", "The field is not shown on the page."]);

  // Another address in the same document, then a new document at the first address.
  await page.evaluate(() => history.pushState(null, "", "/signup/step-2"));
  assert.equal((await run(page, "token")).token, null);
  assert.match((await run(page, "fill", { token: read.token, fields: [{ id: ids.nickname, value: "Ada" }] })).error, /read the form again/);
  await page.evaluate(() => history.back());
  await page.waitForURL("https://forms.test/signup");
  await page.reload();
  assert.match((await run(page, "fill", { token: read.token, fields: [{ id: ids.nickname, value: "Ada" }] })).error, /read the form again/);
  assert.equal(await inputs(), undefined, "the reloaded page saw no input");
  assert.equal(await page.evaluate(() => (document.querySelector("[name=nickname]") as HTMLInputElement).value), "");
});

test("a fill reports a submit that the page's own change handler starts", async (t) => {
  const page = await open(t, `<form action="/sent"><label>Sort by <select name="sort" onchange="this.form.submit()">
    <option>Newest</option><option>Oldest</option></select></label></form>`);
  await page.route("https://forms.test/sent**", (route) => route.fulfill({ contentType: "text/html", body: "Sent" }));
  const read = await run(page, "read");
  const sent = page.waitForURL(/\/sent/);
  const filled = await run(page, "fill", { token: read.token, fields: [{ id: read.fields[0].id, value: "Oldest" }] });
  assert.deepEqual(filled, { results: [{ id: "f1", status: "filled" }], filled: 1, pageSubmitted: true });
  await sent;
});

import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chromium, type Page } from "playwright";

// The Flutter Browser tab's form script, run in headless Chromium as a
// stand-in for WKWebView, called the way web_page.dart calls it.
const script = await readFile(new URL("../flutter/assets/page_forms.js", import.meta.url), "utf8");

// A synthetic sign-up form below a tall heading, so a fill has to scroll to it.
const form = `<div style="height:2000px">Top of the page</div>
<form id="signup" name="signup" action="/apply">
  <label>Full name <input name="name" placeholder="Jane Doe"></label>
  <label for="email">Email</label><input id="email" type="email" name="email" required>
  <label>Nickname <input id="controlled" name="nickname"></label>
  <label>About you <textarea name="about"></textarea></label>
  <label>Country <select name="country"><option value="">Choose</option><option value="jp">Japan</option><option value="nz">New Zealand</option></select></label>
  <fieldset><legend>Plan</legend>
    <label><input type="radio" name="plan" value="basic" checked> Basic</label>
    <label><input type="radio" name="plan" value="pro"> Pro</label>
  </fieldset>
  <label><input type="checkbox" name="terms"> I agree</label>
  <label>Birthday <input type="date" name="birthday"></label>
  <label>Password <input type="password" name="password" value="secret-value"></label>
  <label>Passport scan <input type="file" name="scan"></label>
  <label>Member number <input name="member" value="A-1" disabled></label>
  <input type="hidden" name="token" value="csrf">
  <input name="trap" style="display:none">
  <button id="send" type="submit">Submit</button>
</form>
<iframe srcdoc="<label>Coupon <input name=coupon></label>"></iframe>
<iframe style="width:300px;height:100px" src="data:text/html,<input name=card>"></iframe>`;

async function open(t: test.TestContext) {
  const browser = await chromium.launch({ headless: true });
  t.after(() => browser.close());
  const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
  await page.route("https://forms.test/**", (route) => route.fulfill({ contentType: "text/html",
    body: `<!doctype html><title>Sign up</title>${form}` }));
  await page.goto("https://forms.test/signup");
  await page.evaluate(() => {
    const w = window as any;
    // Anything that would submit or click is counted.
    w.submits = 0;
    document.getElementById("signup")!.addEventListener("submit", (event) => { event.preventDefault(); w.submits++; });
    document.getElementById("send")!.addEventListener("click", () => w.submits++);
    for (const name of ["submit", "requestSubmit"] as const) {
      const original = HTMLFormElement.prototype[name];
      HTMLFormElement.prototype[name] = function (this: HTMLFormElement, ...args: any[]) { w.submits++; return (original as any).apply(this, args); };
    }
    document.addEventListener("keydown", () => w.submits++, true);
    // React's value tracker: it notes values set through the element and
    // ignores an input event whose value it already knows.
    const input = document.getElementById("controlled") as HTMLInputElement;
    const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!;
    let tracked = input.value;
    w.reactState = "";
    Object.defineProperty(input, "value", { configurable: true,
      get() { return native.get!.call(this); }, set(value) { tracked = value; native.set!.call(this, value); } });
    input.addEventListener("input", () => { if (input.value !== tracked) { tracked = input.value; w.reactState = input.value; } });
  });
  await page.waitForFunction(() => document.querySelectorAll("iframe")[0].contentDocument?.querySelector("input"));
  return page;
}

const run = (page: Page, action: string, request?: unknown) =>
  page.evaluate(`JSON.parse(JSON.stringify((${script})(${JSON.stringify(action)}, ${JSON.stringify(request ?? null)})))`) as Promise<any>;

test("a form read lists shown fields with Relay ids, and no password value", async (t) => {
  const page = await open(t);
  const read = await run(page, "read");
  assert.deepEqual(read.forms, [{ form: "form1", name: "signup", action: "https://forms.test/apply" }]);
  assert.equal(read.otherSiteFrames, 1, "the other site's frame is counted, not read");
  const byName = Object.fromEntries(read.fields.map((field: any) => [field.name, field]));
  assert.deepEqual(Object.keys(byName), ["name", "email", "nickname", "about", "country", "plan", "terms", "birthday",
    "password", "scan", "member", "coupon"], "hidden, undisplayed and button elements are not listed");
  assert.deepEqual(byName.name, { id: "f1", type: "text", form: "form1", label: "Full name", name: "name", placeholder: "Jane Doe", required: false, value: "" });
  assert.equal(byName.email.required, true);
  assert.equal(byName.email.label, "Email");
  assert.equal(byName.country.label, "Country", "a label leaves out the list's options");
  assert.deepEqual(byName.country.options[1], { value: "jp", label: "Japan" });
  assert.deepEqual(byName.plan, { id: byName.plan.id, type: "radio", form: "form1", label: "Plan", name: "plan", required: false,
    value: "basic", options: [{ value: "basic", label: "Basic" }, { value: "pro", label: "Pro" }] });
  assert.deepEqual(byName.password, { id: byName.password.id, type: "password", form: "form1", label: "Password", name: "password",
    required: false, fillable: false, reason: "Password fields are left to the user." });
  assert.equal(byName.scan.fillable, false);
  assert.equal(byName.member.reason, "The field is disabled.");
  assert.equal(byName.coupon.form, undefined);
  assert.doesNotMatch(JSON.stringify(read), /secret-value|csrf/);

  const again = await run(page, "read");
  assert.deepEqual(again.fields.map((field: any) => field.id), read.fields.map((field: any) => field.id), "ids stay with their fields");

  // A long list keeps every option; only a read too large for the socket is cut short.
  await page.evaluate(() => document.body.insertAdjacentHTML("beforeend",
    `<select name="year">${Array.from({ length: 250 }, (_, i) => `<option>${1900 + i}</option>`).join("")}</select>`
    + Array.from({ length: 250 }, (_, i) => `<textarea name="note${i}">${"x".repeat(900)}</textarea>`).join("")));
  const long = await run(page, "read");
  assert.equal(long.fields.find((field: any) => field.name === "year").options.length, 250);
  assert.equal(long.truncated, true);
  assert.ok(JSON.stringify(long).length < 200000);
});

test("a fill sets fields as typing would, outlines them and never submits", async (t) => {
  const page = await open(t);
  const ids = Object.fromEntries((await run(page, "read")).fields.map((field: any) => [field.name, field.id]));
  // The page tries to give its submit button a field id.
  await page.evaluate(() => document.getElementById("send")!.setAttribute("data-relay-field", "f99"));
  const filled = await run(page, "fill", [
    { id: ids.name, value: "Ada Lovelace" },
    { id: ids.email, value: "ada@example.com" },
    { id: ids.nickname, value: "Ada" },
    { id: ids.about, value: "Line one\nLine two" },
    { id: ids.country, value: "New Zealand" },
    { id: ids.plan, value: "Pro" },
    { id: ids.terms, value: true },
    { id: ids.birthday, value: "1815-12-10" },
    { id: ids.coupon, value: "SAVE" },
    { id: ids.password, value: "guess" },
    { id: ids.scan, value: "/tmp/passport.png" },
    { id: ids.member, value: "B-2" },
    { id: "f99", value: "click me" },
    { id: "f500", value: "x" },
    { id: "a\"]", value: "x" },
  ]);
  const status = Object.fromEntries(filled.results.map((result: any) => [result.id, result.status]));
  assert.equal(filled.filled, 9);
  assert.equal(filled.submitted, false);
  for (const name of ["name", "email", "nickname", "about", "country", "plan", "terms", "birthday", "coupon"])
    assert.equal(status[ids[name]], "filled", name);
  for (const name of ["password", "scan", "member"]) assert.equal(status[ids[name]], "refused", name);
  assert.equal(status.f99, "refused", "a button is never a field");
  assert.equal(status.f500, "not found");
  assert.equal(status['a"]'], "not found");

  const page_ = await page.evaluate(() => {
    const form = document.getElementById("signup") as HTMLFormElement;
    const frame = document.querySelector("iframe")!.contentDocument!;
    return {
      values: ["name", "email", "nickname", "about", "country", "plan", "birthday", "password", "member"]
        .map((name) => (form.elements.namedItem(name) as HTMLInputElement).value),
      terms: (form.elements.namedItem("terms") as HTMLInputElement).checked,
      coupon: (frame.querySelector("input") as HTMLInputElement).value,
      reactState: (window as any).reactState,
      submits: (window as any).submits,
      outlined: [...document.querySelectorAll("[data-relay-filled]")].map((el) => (el as HTMLInputElement).name || el.tagName),
      outline: getComputedStyle(form.elements.namedItem("name") as Element).outlineStyle,
    };
  });
  assert.deepEqual(page_.values, ["Ada Lovelace", "ada@example.com", "Ada", "Line one\nLine two", "nz", "pro", "1815-12-10", "secret-value", "A-1"]);
  assert.equal(page_.terms, true);
  assert.equal(page_.coupon, "SAVE", "a same-site frame's field is filled");
  assert.equal(page_.reactState, "Ada", "a React-style controlled input sees the change");
  assert.equal(page_.submits, 0, "nothing was submitted, clicked on the button or typed");
  assert.deepEqual(page_.outlined, ["name", "email", "nickname", "about", "country", "LABEL", "plan", "LABEL", "terms", "birthday"]);
  assert.equal(page_.outline, "solid");
  // Scrolls smoothly to the first filled field.
  await page.waitForFunction(() => scrollY > 1000, null, { timeout: 3000 });

  // A value the field does not take leaves it as it was; a new fill clears the old outlines.
  const again = await run(page, "fill", [{ id: ids.birthday, value: "10 Dec 1815" }, { id: ids.terms, value: "no" }]);
  assert.deepEqual(again.results.map((result: any) => result.status), ["refused", "filled"]);
  assert.match(again.results[0].reason, /YYYY-MM-DD/);
  assert.deepEqual(await page.evaluate(() => [
    (document.querySelector("[name=birthday]") as HTMLInputElement).value,
    [...document.querySelectorAll("[data-relay-filled]")].map((el) => (el as HTMLInputElement).name || el.tagName),
    (window as any).submits,
  ]), ["1815-12-10", ["LABEL", "terms"], 0]);
});

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const script = await readFile(new URL("../public/app-bridge.js", import.meta.url), "utf8");
type Context = { viewId: string; state?: Record<string, unknown>; generation?: number };
type Envelope = Record<string, any>;
async function setup(present: (intent: Context, options: { signal: AbortSignal }) => Promise<Context> = async (intent) => intent, getContext: () => Context = () => ({ viewId: "home" }), dom?: ReturnType<typeof explanationDOM>, selection = () => "") {
  const sent: Envelope[] = [];
  const listeners = new Map<string, Set<(event: Envelope) => unknown>>();
  const parent = { postMessage(data: Envelope, origin: string) { assert.equal(origin, "https://relay.test"); sent.push(data); } };
  const window = {
    parent, getSelection: selection,
    innerWidth: 800, innerHeight: 600,
    matchMedia: () => ({ matches: true }),
    requestAnimationFrame: (fn: () => void) => setTimeout(fn, 0), cancelAnimationFrame: clearTimeout,
    RelayApp: undefined as any,
    addEventListener(type: string, listener: (event: Envelope) => unknown) { if (!listeners.has(type)) listeners.set(type, new Set()); listeners.get(type)!.add(listener); },
    removeEventListener(type: string, listener: (event: Envelope) => unknown) { listeners.get(type)?.delete(listener); },
  };
  vm.runInNewContext(script, { window, URL, AbortController, document: dom?.document, ResizeObserver: class { observe() {} disconnect() {} } });
  const bridge = window.RelayApp.connect({ token: "secret", parentOrigin: "https://relay.test", getContext, present, ...(dom ? { getExplanationTarget: () => dom.target } : {}) });
  const dispatch = (type: string, event: Envelope = {}) => Promise.all([...listeners.get(type) || []].map((listener) => listener(event)));
  const message = (data: Envelope, overrides: Envelope = {}) => dispatch("message", { source: parent, origin: "https://relay.test", data: { version: 2, token: "secret", ...data }, ...overrides });
  const request = (commandId = "command", expectedGeneration = 0) => message({ type: "relay.present", commandId, expectedGeneration, intent: { viewId: "room", state: { layout: "small" }, targetIds: ["sofa"] } });
  return { bridge, sent, dispatch, message, request };
}
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; }

test("selected words are included in app context until the next page interaction", async () => {
  const app = await setup(undefined, undefined, undefined, () => "a selected paragraph");
  await app.dispatch("selectionchange");
  assert.equal(app.sent.at(-1)!.context.selection, "a selected paragraph");
  await app.dispatch("pointerdown");
  assert.equal(app.sent.at(-1)!.context.selection, undefined);
});

test("bridge authenticates messages and rejects stale generations before calling the app", async () => {
  let calls = 0;
  const app = await setup(async (intent) => { calls++; return intent; });
  assert.equal(app.sent[0].type, "relay.ready");
  assert.equal(app.sent[0].context.generation, 0);
  const data = { type: "relay.present", commandId: "wrong", expectedGeneration: 0, intent: { viewId: "room" } };
  await app.message(data, { origin: "https://other.test" });
  await app.message(data, { source: {} });
  await app.message({ ...data, token: "wrong" });
  await app.message({ ...data, version: 1 });
  assert.equal(calls, 0);
  await app.request("stale", 3);
  assert.equal(calls, 0);
  assert.equal(app.sent.at(-1)!.status, "stale");
});

test("applied acknowledgement waits for app rendering and advances the bridge generation", async () => {
  const render = deferred<Context>();
  const app = await setup(async () => render.promise);
  const pending = app.request();
  assert.equal(app.sent.length, 1);
  render.resolve({ viewId: "room", state: { layout: "small" }, generation: 800 });
  await pending;
  const result = app.sent.at(-1)!;
  assert.equal(result.type, "relay.presented");
  assert.equal(result.status, "applied");
  assert.equal(result.commandId, "command");
  assert.equal(result.context.generation, 1);
  await app.request("next", 1);
  assert.equal(app.sent.at(-1)!.context.generation, 2);
});

test("manual input immediately aborts presentation and a late app render cannot acknowledge applied", async () => {
  for (const input of ["pointerdown", "keydown"]) {
    const render = deferred<Context>();
    let signal!: AbortSignal;
    let visible = { viewId: "home" };
    const app = await setup(async (_intent, options) => { visible = { viewId: "room" }; signal = options.signal; return render.promise; }, () => visible);
    const pending = app.request();
    await app.dispatch(input);
    assert.equal(signal.aborted, true);
    assert.equal(app.sent.at(-2)!.status, "stale");
    assert.equal(app.sent.at(-1)!.type, "relay.context");
    assert.equal(app.sent.at(-1)!.context.generation, 1);
    assert.equal(app.sent.at(-1)!.context.viewId, "room");
    render.resolve({ viewId: "room" });
    await pending;
    assert.equal(app.sent.some((message) => message.status === "applied"), false);
  }
});

test("cancel is authenticated and command scoped, and publishes the superseding context", async () => {
  const render = deferred<Context>();
  let signal!: AbortSignal;
  const app = await setup(async (_intent, options) => { signal = options.signal; return render.promise; });
  const pending = app.request();
  await app.message({ type: "relay.cancel", commandId: "another" });
  assert.equal(signal.aborted, false);
  await app.message({ type: "relay.cancel", commandId: "command" });
  assert.equal(signal.aborted, true);
  assert.equal(app.sent.at(-1)!.context.generation, 1);
  render.resolve({ viewId: "room" });
  await pending;
  assert.equal(app.sent.some((message) => message.status === "applied"), false);
});

test("manual context updates supersede pending work and disposal removes listeners", async () => {
  const render = deferred<Context>();
  const app = await setup(async () => render.promise);
  const pending = app.request();
  app.bridge.updateContext({ viewId: "manual", state: { layout: "large" }, generation: 999 });
  assert.equal(app.sent.at(-1)!.context.viewId, "manual");
  assert.equal(app.sent.at(-1)!.context.generation, 1);
  render.resolve({ viewId: "room" });
  await pending;
  app.bridge.dispose();
  const count = app.sent.length;
  await app.dispatch("pointerdown");
  await app.request("disposed", 1);
  app.bridge.updateContext({ viewId: "ignored" });
  assert.equal(app.sent.length, count);
});

test("failure after routing publishes the actual visible context and invalidates the old generation", async () => {
  for (const shouldThrow of [true, false]) {
    let visible: Context = { viewId: "home" };
    const app = await setup(async () => {
      visible = { viewId: "changed-page", state: { page: "rendered" } };
      if (shouldThrow) throw new Error("Target unavailable");
      return visible;
    }, () => visible);
    await app.request();
    const result = app.sent.at(-1)!;
    assert.equal(result.status, "failed");
    assert.equal(result.context.generation, 1);
    assert.equal(result.context.viewId, "changed-page");
    assert.equal(result.context.state.page, "rendered");
    assert.match(result.error, /Target unavailable|different view/);
    await app.request("old-generation", 0);
    assert.equal(app.sent.at(-1)!.status, "stale");
    assert.equal(app.sent.some((message) => message.status === "applied"), false);
  }
});

function explanationDOM() {
  class Element {
    style: Record<string, string> = {};
    children: Element[] = [];
    textContent = "";
    hidden = false;
    isConnected = true;
    attributes: Record<string, string> = {};
    parent?: Element;
    onclick?: () => void;
    setAttribute(key: string, value: string) { this.attributes[key] = value; }
    set innerHTML(_value: string) { assert.fail("Explanations must never interpret HTML"); }
    append(...nodes: Element[]) { for (const node of nodes) { node.parent = this; this.children.push(node); } }
    remove() { this.isConnected = false; if (this.parent) this.parent.children = this.parent.children.filter(node => node !== this); }
    contains(node: Element): boolean { return this === node || this.children.some(child => child.contains(node)); }
    getBoundingClientRect() { return { left: 100, top: 100, right: 300, bottom: 180, width: 200, height: 80 }; }
  }
  const body = new Element();
  return { target: new Element(), document: { body, createElement: () => new Element() } };
}

test("explanation is literal text, rendered before applied, readable and cleared by manual navigation", async () => {
  const dom = explanationDOM();
  const render = deferred<Context>();
  const app = await setup(async () => render.promise, () => ({viewId: "room"}), dom);
  const text = '<img src=x onerror=alert(1)> — qualified evidence';
  const request = app.message({ type: "relay.present", commandId: "note", expectedGeneration: 0, intent: {viewId: "room", explanation: text} });
  assert.equal(dom.document.body.children.length, 0);
  render.resolve({viewId: "room"});
  await request;
  const note = dom.document.body.children[0];
  assert.equal(note.children[1].textContent, text);
  assert.equal(app.sent.at(-1)!.status, "applied");
  assert.ok(note.style.left);
  await app.dispatch("pointerdown", {target: note.children[1]});
  assert.equal(dom.document.body.children.length, 1, "Reading or selecting note text does not dismiss it");
  await app.dispatch("pointerdown", {target: dom.target});
  assert.equal(dom.document.body.children.length, 0);
  assert.equal(app.sent.at(-1)!.type, "relay.context");
});

test("unsupported, oversized and missing-target explanations fail without false applied", async () => {
  for (const text of ["Supported only by newer apps", " ", "x".repeat(601)]) {
    let calls = 0;
    const app = await setup(async intent => {calls++; return intent;});
    await app.message({type: "relay.present", commandId: "invalid", expectedGeneration: 0, intent: {viewId: "room", explanation: text}});
    assert.equal(app.sent.at(-1)!.status, "failed");
    assert.equal(calls, 0);
  }
  const dom = explanationDOM(); dom.target.isConnected = false;
  const app = await setup(async intent => intent, () => ({viewId: "room"}), dom);
  await app.message({type: "relay.present", commandId: "missing", expectedGeneration: 0, intent: {viewId: "room", explanation: "Evidence"}});
  assert.equal(app.sent.at(-1)!.status, "failed");
  assert.equal(dom.document.body.children.length, 0);
});

test("cancelling before presentation finishes never leaves an explanation behind", async () => {
  const dom = explanationDOM(); const render = deferred<Context>();
  const app = await setup(async () => render.promise, () => ({viewId: "room"}), dom);
  const request = app.message({type: "relay.present", commandId: "cancelled-note", expectedGeneration: 0, intent: {viewId: "room", explanation: "Evidence"}});
  await app.message({type: "relay.cancel", commandId: "cancelled-note"});
  render.resolve({viewId: "room"}); await request;
  assert.equal(dom.document.body.children.length, 0);
  assert.equal(app.sent.some(message => message.status === "applied"), false);
});

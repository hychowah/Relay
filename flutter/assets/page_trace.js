// While a bug is recorded, notes what a Browser tab's page sees of the
// mouse and scrolling, which Relay cannot see from outside the page (WebKit
// gets the mouse from macOS directly), and sends the notes to Relay in small
// batches for the bug report. Relay runs this in each loaded document while
// it records and calls `__relayTrace.stop()` when the recording ends. The
// page's focus, size and visibility are noted too: a web view that the
// window removes and adds back would change them.
//
// A note says which element was involved by its tag, id, role and first few
// words. Key presses and the text in fields are never noted.
(() => {
  if (window.__relayTrace) return window.__relayTrace.start();
  const words = 40, jump = 40, sampleMs = 200, batchMs = 250;
  let on = false, queue = [], timer = null;
  let moved = null, sampledAt = 0, hovered = null, wheel = null;
  const scrolled = new Set();

  // The first few words of an element's text, read without layout.
  function text(element) {
    if (element.isContentEditable || element.matches("input, textarea, select")) return "";
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    let found = "";
    for (let node; found.length < words && (node = walker.nextNode());) {
      // A field or editor inside the element, such as a chat's draft, too.
      const parent = node.parentElement;
      if (!parent || parent.isContentEditable || parent.closest("script, style, noscript, textarea")) continue;
      found = `${found} ${node.data}`.replace(/\s+/g, " ");
    }
    return found.trim().slice(0, words);
  }

  function describe(target) {
    if (target === document || target === window) return "document";
    const element = target?.nodeType === 1 ? target : target?.parentElement;
    if (!element) return String(target?.nodeName ?? "");
    const role = element.getAttribute("role");
    const name = element.getAttribute("aria-label")?.slice(0, words) || text(element);
    return element.tagName.toLowerCase() + (element.id ? `#${element.id.slice(0, words)}` : "")
      + (role ? `[role=${role}]` : "") + (name ? ` "${name}"` : "");
  }

  // The control or item under the pointer rather than a span inside it, so
  // moving within one link or row notes nothing.
  const item = (target) => (target?.nodeType === 1
    ? target.closest("a, button, input, textarea, select, label, summary, li, [role], [tabindex], [contenteditable]")
    : null) ?? target;

  // An event a page's script made, not the user, is marked synthetic.
  const push = (kind, fields = {}, event) =>
    queue.push({ at: Date.now(), kind, ...fields, ...(event && !event.isTrusted ? { synthetic: true } : {}) });
  const later = () => { timer ??= setTimeout(flush, batchMs); };
  const note = (kind, fields, event) => {
    if (!on) return;
    push(kind, fields, event);
    later();
  };

  function flush() {
    clearTimeout(timer);
    timer = null;
    // A scroll is noted once per batch, where it ended up.
    for (const target of scrolled) {
      const box = target === document ? document.scrollingElement : target;
      if (box) push("scroll", {
        target: describe(target), top: Math.round(box.scrollTop), left: Math.round(box.scrollLeft), height: box.scrollHeight,
      });
    }
    scrolled.clear();
    if (wheel) push("wheel", wheel);
    wheel = null;
    if (!queue.length) return;
    const batch = queue;
    queue = [];
    try { RelayBrowser.postMessage("trace:" + JSON.stringify(batch)); } catch (_) { /* No Relay. */ }
  }

  const point = (event) => ({ x: Math.round(event.clientX), y: Math.round(event.clientY) });
  const options = { capture: true, passive: true };
  addEventListener("mousemove", (event) => {
    if (!on) return;
    const now = Date.now(), at = point(event);
    const far = moved && Math.hypot(at.x - moved.x, at.y - moved.y) > jump;
    if (far) note("pointer jump", { ...at, fromX: moved.x, fromY: moved.y, afterMs: now - moved.time }, event);
    else if (now - sampledAt >= sampleMs) note("pointer", at, event);
    if (far || now - sampledAt >= sampleMs) sampledAt = now;
    moved = { ...at, time: now };
  }, options);
  addEventListener("mouseover", (event) => {
    if (!on) return;
    const target = item(event.target);
    if (target === hovered) return;
    hovered = target;
    note("hover", { ...point(event), target: describe(target) }, event);
  }, options);
  // WebKit says the mouse left the page. If the window redrawing its web
  // view makes WebKit drop and restore the hover, the item shows as
  // "hover lost" and then "hover" again with the mouse still.
  addEventListener("mouseout", (event) => {
    if (!on || event.relatedTarget) return;
    hovered = null;
    note("hover lost", point(event), event);
  }, options);
  addEventListener("wheel", (event) => {
    if (!on) return;
    wheel ??= { dx: 0, dy: 0, events: 0 };
    wheel.dx += Math.round(event.deltaX);
    wheel.dy += Math.round(event.deltaY);
    wheel.events++;
    later();
  }, options);
  addEventListener("scroll", (event) => {
    if (!on) return;
    scrolled.add(event.target);
    later();
  }, options);
  addEventListener("focus", (event) => event.target === window && note("page focus"), true);
  addEventListener("blur", (event) => event.target === window && note("page blur"), true);
  addEventListener("resize", () => note("resize", { width: innerWidth, height: innerHeight }));
  document.addEventListener("visibilitychange", () => note("visibility", { state: document.visibilityState }));

  // The page's own code scrolling (or focusing, which can scroll) is noted
  // with the element, the value and where in the page's code the call came
  // from, at most every 100 ms per element. A scroll with no such note was
  // the user's or the browser's own. The page's methods are wrapped only
  // while the trace is on.
  const wrapped = [], called = new WeakMap();
  // A note must never break the page's own call.
  function noteCall(method, receiver, value) {
    if (!on) return;
    try {
      const target = receiver == null || receiver === window ? document : receiver;
      const now = Date.now(), last = called.get(target);
      if (last && now - last.at < 100) {
        last.skipped++;
        return;
      }
      // Past this function and the wrapper; Chromium starts with an "Error" line.
      const stack = String(new Error().stack ?? "").split("\n").map((line) => line.trim())
        .filter((line) => line && line !== "Error").slice(2, 5).map((line) => line.slice(0, 160)).join(" < ");
      note("script scroll", {
        method, target: describe(target), value: shown(value), stack,
        ...(last?.skipped ? { skippedBefore: last.skipped } : {}),
      });
      called.set(target, { at: now, skipped: 0 });
    } catch (_) { /* The call goes on unnoted. */ }
  }
  // The call's value or arguments, read without running the page's getters:
  // numbers and strings as they are, and an options object's own plain
  // values for the scroll and focus options.
  const optionNames = ["top", "left", "behavior", "block", "inline", "preventScroll"];
  function shown(value) {
    const one = (item) => {
      if (item === null || typeof item !== "object") return typeof item === "function" ? "function" : item;
      return Object.fromEntries(optionNames.flatMap((name) => {
        const own = Object.getOwnPropertyDescriptor(item, name);
        return own && "value" in own && typeof own.value !== "object" ? [[name, own.value]] : [];
      }));
    };
    return JSON.stringify(Array.isArray(value) ? value.slice(0, 3).map(one) : one(value))?.slice(0, 120);
  }
  // Stopping puts back only what is still the trace's own: a page that
  // replaced one of these meanwhile keeps its version.
  function wrap(owner, name, replace) {
    const original = Object.getOwnPropertyDescriptor(owner, name);
    if (!original) return;
    const mine = replace(original);
    Object.defineProperty(owner, name, mine);
    wrapped.push([owner, name, original, mine]);
  }
  function watchScripts() {
    for (const name of ["scrollTop", "scrollLeft"]) {
      wrap(Element.prototype, name, (original) => ({
        ...original, set(value) { noteCall(name, this, value); original.set.call(this, value); },
      }));
    }
    const methods = [
      [Element.prototype, ["scrollTo", "scroll", "scrollBy", "scrollIntoView"]],
      [HTMLElement.prototype, ["focus"]],
      [window, ["scrollTo", "scroll", "scrollBy"]],
    ];
    for (const [owner, names] of methods) {
      for (const name of names) {
        wrap(owner, name, (original) => ({
          ...original,
          value(...args) {
            noteCall(name, this, args);
            return original.value.apply(this, args);
          },
        }));
      }
    }
  }

  window.__relayTrace = {
    start() {
      if (on) return;
      on = true;
      moved = null;
      hovered = null;
      watchScripts();
      note("trace start", {
        url: location.href.slice(0, 2000), width: innerWidth, height: innerHeight,
        pixelRatio: devicePixelRatio, zoom: visualViewport?.scale ?? 1, focused: document.hasFocus(),
      });
    },
    stop() {
      if (!on) return;
      flush();
      on = false;
      for (const [owner, name, original, mine] of wrapped.splice(0)) {
        const now = Object.getOwnPropertyDescriptor(owner, name);
        if (now && now.value === mine.value && now.set === mine.set) Object.defineProperty(owner, name, original);
      }
    },
  };
  window.__relayTrace.start();
})();

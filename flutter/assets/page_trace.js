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
      if (node.parentElement?.closest("script, style, noscript")) continue;
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
      if (box) push("scroll", { target: describe(target), top: Math.round(box.scrollTop), left: Math.round(box.scrollLeft) });
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

  window.__relayTrace = {
    start() {
      if (on) return;
      on = true;
      moved = null;
      hovered = null;
      note("trace start", {
        url: location.href.slice(0, 2000), width: innerWidth, height: innerHeight,
        pixelRatio: devicePixelRatio, zoom: visualViewport?.scale ?? 1, focused: document.hasFocus(),
      });
    },
    stop() {
      if (!on) return;
      flush();
      on = false;
    },
  };
  window.__relayTrace.start();
})();

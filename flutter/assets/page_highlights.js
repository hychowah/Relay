// Highlights on web pages in a Browser tab. Relay runs this in the page once
// it has loaded, then calls `__relayHighlights.set` with the highlights kept
// for the page's address, and `add`, `recolor` or `remove` from its
// highlight menu. This script tells Relay where to show that menu: next to
// selected text once the mouse is released, or next to a clicked highlight.
//
// A highlight is the quoted text and a little of the text around it, not a
// place in the page. It shows wherever that text is, and only while it is
// there, so it survives a page that redraws itself or changes its content
// under one address (a single-page app). It is painted with the CSS custom
// highlight API, which adds nothing to the page's own elements: a page that
// rebuilds its elements cannot trip over a highlight.
(() => {
  if (window.__relayHighlights) return;
  const name = "relay-highlight", around = 40, longest = 4000;
  const paints = !!(window.CSS && CSS.highlights && window.Highlight);
  // Kept in step with highlight_menu.dart, BrowserPDF.swift and the server's
  // highlightColors, which refuses any other.
  const colors = { yellow: "255,214,10", green: "52,199,89", blue: "10,132,255", pink: "255,55,95", purple: "175,82,222" };
  const colorOf = (highlight) => colors[highlight.color] ? highlight.color : "yellow";
  let kept = [];
  // Where each highlight is painted, and the text that was there.
  const ranges = new Map(), painted = new Map();
  let watching = false, timer, changing = 0, lastRead = 0, retry;

  let sheet;
  if (paints) {
    try {
      sheet = new CSSStyleSheet();
      sheet.replaceSync(Object.entries(colors).map(([color, rgb]) =>
        `::highlight(${name}-${color}){background-color:rgba(${rgb},.45);color:inherit}`).join(""));
    } catch (_) { /* The highlight keeps the browser's default look. */ }
  }

  const unread = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEXTAREA", "TITLE"]);

  // The page's text as one string with each run of white space as one space,
  // and for every character the text node and offset it came from.
  function read() {
    const nodes = [], node = [], offset = [];
    let text = "", spaced = true;
    if (!document.body) return { nodes, node, offset, text };
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => unread.has(n.parentElement?.tagName) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
    });
    for (let n; (n = walker.nextNode());) {
      const data = n.data, at = nodes.push(n) - 1;
      for (let i = 0; i < data.length; i++) {
        const space = /\s/.test(data[i]);
        if (space && spaced) continue;
        spaced = space;
        text += space ? " " : data[i];
        node.push(at);
        offset.push(i);
      }
    }
    return { nodes, node, offset, text };
  }

  function rangeAt(page, start, end) {
    const range = document.createRange();
    range.setStart(page.nodes[page.node[start]], page.offset[start]);
    range.setEnd(page.nodes[page.node[end - 1]], page.offset[end - 1] + 1);
    return range;
  }

  // Where the quote is in the page: of several places, the one whose
  // surrounding text matches best.
  function find(page, highlight) {
    let best = -1, bestScore = -1;
    for (let at = page.text.indexOf(highlight.text); at >= 0; at = page.text.indexOf(highlight.text, at + 1)) {
      let score = 0;
      const before = highlight.prefix || "", after = highlight.suffix || "";
      while (score < before.length && page.text[at - 1 - score] === before[before.length - 1 - score]) score++;
      const end = at + highlight.text.length;
      let ahead = 0;
      while (ahead < after.length && page.text[end + ahead] === after[ahead]) ahead++;
      if (score + ahead > bestScore) [best, bestScore] = [at, score + ahead];
    }
    return best < 0 ? null : rangeAt(page, best, best + highlight.text.length);
  }

  function paint() {
    if (!paints) return;
    const shades = new Map();
    for (const highlight of kept) {
      const range = ranges.get(highlight.id), color = colorOf(highlight);
      if (range) shades.get(color)?.push(range) ?? shades.set(color, [range]);
    }
    for (const color in colors) {
      if (shades.has(color)) CSS.highlights.set(`${name}-${color}`, new Highlight(...shades.get(color)));
      else CSS.highlights.delete(`${name}-${color}`);
    }
    if (!ranges.size) return;
    // A page that replaces its style sheets takes the colour away with them.
    try {
      if (sheet && !document.adoptedStyleSheets.includes(sheet))
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    } catch (_) { /* The highlight keeps the browser's default look. */ }
  }

  function put(id, range) {
    ranges.set(id, range);
    painted.set(id, range.toString());
  }

  function drop(id) {
    ranges.delete(id);
    painted.delete(id);
  }

  // Puts every kept highlight on the text it quotes, and takes one off text
  // that has changed. The page is read again only for those, and for text
  // that is not on the page no more than once a second: an old highlight on
  // a busy page must not have the page read over and over.
  function place() {
    changing = 0;
    clearTimeout(retry);
    const rest = lastRead + 1000 - Date.now();
    let page, later = false;
    for (const highlight of kept) {
      const range = ranges.get(highlight.id);
      if (range && range.startContainer.isConnected && range.toString() === painted.get(highlight.id)) continue;
      if (!range && rest > 0) {
        later = true;
        continue;
      }
      page ??= read();
      const found = find(page, highlight);
      if (found) put(highlight.id, found);
      else drop(highlight.id);
    }
    if (page) lastRead = Date.now();
    if (later) retry = setTimeout(place, rest);
    paint();
  }

  // Waits for the page to settle, but no more than about two seconds on a
  // page that never does.
  const observer = new MutationObserver(() => {
    clearTimeout(timer);
    changing ||= Date.now();
    timer = setTimeout(place, Date.now() - changing > 1600 ? 0 : 400);
  });

  // The page is watched only while it has highlights to keep in place.
  function watch() {
    const needed = kept.length > 0;
    if (needed === watching) return;
    watching = needed;
    if (needed) observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true });
    else observer.disconnect();
  }

  // The character of the page's text at or after a place in the page.
  function position(page, container, offset) {
    const point = document.createRange();
    point.setStart(container, offset);
    let low = 0, high = page.node.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (point.comparePoint(page.nodes[page.node[middle]], page.offset[middle]) < 0) low = middle + 1;
      else high = middle;
    }
    return low;
  }

  // Where Relay shows its menu: a box in the viewport's CSS pixels, with
  // the id of the highlight clicked, or nothing to hide it.
  let pressed = false, shown = null, settle;
  // The text last selected on the page. A click on Relay's menu or toolbar
  // takes focus from the page, and WKWebView then clears its selection,
  // possibly while the page still reports focus; the highlight goes on
  // this. A press in the page, which starts a new selection, clears it.
  let lastRange = null;
  const post = (menu) => {
    try { RelayBrowser.postMessage("menu:" + (menu ? JSON.stringify(menu) : "")); } catch (_) { /* No Relay. */ }
  };
  function hide() {
    if (shown === null) return;
    shown = null;
    post(null);
  }
  // The part of [rects] in view, or null.
  function box(rects) {
    let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
    for (const rect of rects) {
      if (rect.bottom < 0 || rect.top > innerHeight || rect.right < 0 || rect.left > innerWidth) continue;
      left = Math.min(left, rect.left);
      top = Math.min(top, rect.top);
      right = Math.max(right, rect.right);
      bottom = Math.max(bottom, rect.bottom);
    }
    return left > right ? null : { left, top, right, bottom };
  }
  // The selected text that can be highlighted: not in a text field.
  function selected() {
    const selection = getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount || !selection.toString().trim()) return null;
    const at = selection.anchorNode, element = at?.nodeType === 1 ? at : at?.parentElement;
    if (element?.isContentEditable || element?.closest("input, textarea")
      || document.activeElement?.matches?.("input, textarea")) return null;
    return selection.getRangeAt(0);
  }
  function showSelection() {
    const range = selected(), rect = range && box(range.getClientRects());
    if (!rect) return hide();
    shown = "selection";
    post({ rect });
  }
  // The highlight under a point; of several, the one made last.
  function showHighlightAt(x, y) {
    for (let i = kept.length - 1; i >= 0; i--) {
      const range = ranges.get(kept[i].id);
      if (!range) continue;
      const rects = range.getClientRects();
      if (![...rects].some((r) => x >= r.left && x <= r.right && y >= r.top && y <= r.bottom)) continue;
      shown = kept[i].id;
      post({ id: shown, rect: box(rects) });
      return;
    }
  }
  if (paints) {
    addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      pressed = true;
      lastRange = null;
      hide();
    }, true);
    addEventListener("pointerup", (event) => {
      if (!pressed) return;
      pressed = false;
      // After the page has finished with the click's own selection change.
      setTimeout(() => (selected() ? showSelection() : showHighlightAt(event.clientX, event.clientY)), 0);
    }, true);
    // Text selected with the keyboard, or selected text that went away.
    document.addEventListener("selectionchange", () => {
      const range = selected();
      if (range) lastRange = range.cloneRange();
      if (pressed) return;
      clearTimeout(settle);
      settle = setTimeout(() => (selected() ? showSelection() : shown === "selection" && hide()), 300);
    });
    // The menu hides while the page moves, and comes back by selected text.
    const moved = () => {
      if (shown === null && getSelection()?.isCollapsed !== false) return;
      hide();
      clearTimeout(settle);
      settle = setTimeout(() => selected() && showSelection(), 250);
    };
    addEventListener("scroll", moved, { capture: true, passive: true });
    addEventListener("resize", moved, { passive: true });
    addEventListener("keydown", (event) => event.key === "Escape" && hide(), true);
  }

  window.__relayHighlights = {
    /** Shows the highlights kept for this address: [{id, text, prefix, suffix, color}]. */
    set(list) {
      kept = list;
      ranges.clear();
      painted.clear();
      lastRead = 0;
      hide();
      place();
      watch();
    },
    /**
     * Highlights the selected text, or else the text last selected before
     * a click outside the page cleared it, as [id] in [color]. Answers
     * {added: {text, prefix, suffix}}, or null when there is neither.
     */
    add(id, color) {
      const chosen = selected() ?? lastRange;
      if (!paints || !chosen?.startContainer.isConnected || !chosen.endContainer.isConnected) return null;
      const page = read();
      let start = position(page, chosen.startContainer, chosen.startOffset);
      let end = position(page, chosen.endContainer, chosen.endOffset);
      while (start < end && page.text[start] === " ") start++;
      while (end > start && page.text[end - 1] === " ") end--;
      // A long quote is cut, but not inside a character or before a space.
      end = Math.min(end, start + longest);
      if ((page.text.charCodeAt(end - 1) & 0xfc00) === 0xd800) end--;
      while (end > start && page.text[end - 1] === " ") end--;
      if (start >= end) return null;
      const made = {
        id, color, text: page.text.slice(start, end),
        prefix: page.text.slice(Math.max(0, start - around), start),
        suffix: page.text.slice(end, end + around),
      };
      kept.push(made);
      put(id, rangeAt(page, start, end));
      getSelection()?.removeAllRanges();
      lastRange = null;
      shown = null;
      paint();
      watch();
      return { added: { text: made.text, prefix: made.prefix, suffix: made.suffix } };
    },
    /** Paints the highlight [id] in [color]. */
    recolor(id, color) {
      const highlight = kept.find((item) => item.id === id);
      if (highlight) highlight.color = color;
      shown = null;
      paint();
    },
    /** Takes the highlight [id] off the page. */
    remove(id) {
      kept = kept.filter((item) => item.id !== id);
      drop(id);
      shown = null;
      paint();
      watch();
    },
  };
})();

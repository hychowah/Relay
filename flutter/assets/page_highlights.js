// Highlights on web pages in a Browser tab. Relay runs this in the page once
// it has loaded, then calls `__relayHighlights.set` with the highlights kept
// for the page's address and `toggle` when the user presses Highlight.
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
  let kept = [];
  // Where each highlight is painted, and the text that was there.
  const ranges = new Map(), painted = new Map();
  let watching = false, timer, changing = 0, lastRead = 0, retry;

  let sheet;
  if (paints) {
    try {
      sheet = new CSSStyleSheet();
      sheet.replaceSync(`::highlight(${name}){background-color:rgba(255,214,10,.5);color:inherit}`);
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
    if (!ranges.size) {
      CSS.highlights.delete(name);
      return;
    }
    CSS.highlights.set(name, new Highlight(...ranges.values()));
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

  window.__relayHighlights = {
    /** Shows the highlights kept for this address: [{id, text, prefix, suffix}]. */
    set(list) {
      kept = list;
      ranges.clear();
      painted.clear();
      lastRead = 0;
      place();
      watch();
    },
    /**
     * Highlights the selected text as [id], or removes the highlights the
     * selection touches. Answers {added: {text, prefix, suffix}},
     * {removed: [ids]}, or null when there is nothing to do.
     */
    toggle(id) {
      const selection = getSelection();
      if (!paints || !selection || selection.isCollapsed || !selection.rangeCount) return null;
      const chosen = selection.getRangeAt(0);
      const touched = [...ranges].filter(([, range]) =>
        range.compareBoundaryPoints(Range.START_TO_END, chosen) > 0
        && range.compareBoundaryPoints(Range.END_TO_START, chosen) < 0).map(([key]) => key);
      if (touched.length) {
        kept = kept.filter((highlight) => !touched.includes(highlight.id));
        for (const key of touched) drop(key);
        selection.removeAllRanges();
        paint();
        watch();
        return { removed: touched };
      }
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
        id, text: page.text.slice(start, end),
        prefix: page.text.slice(Math.max(0, start - around), start),
        suffix: page.text.slice(end, end + around),
      };
      kept.push(made);
      put(id, rangeAt(page, start, end));
      selection.removeAllRanges();
      paint();
      watch();
      return { added: { text: made.text, prefix: made.prefix, suffix: made.suffix } };
    },
  };
})();

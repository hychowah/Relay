// Lists the icons a Browser tab's page declares, best first, and posts
// `icons:{"page":location.href,"icons":[...]}` on RelayBrowser now and
// whenever the list changes (flutter/lib/site_icon.dart reads it). Relay runs
// this in each loaded document; the watcher is installed once per document.
//
// Order: `rel~=icon` links by closeness to 32 px, then `apple-touch-icon`,
// then the site's `/favicon.ico`. At most 4, absolute http/https only, no
// duplicates. SVG and `mask-icon` are left out: Relay cannot draw them. A
// page that is not http/https posts an empty list.
(() => {
  const listed = () => {
    if (!/^https?:$/.test(location.protocol)) return [];
    const size = (link) => {
      const sizes = (link.getAttribute("sizes") || "").toLowerCase();
      if (sizes === "any") return Infinity;
      const widths = [...sizes.matchAll(/(\d+)x\d+/g)].map((m) => Number(m[1]));
      return widths.length ? Math.min(...widths.map((w) => Math.abs(w - 32))) : 16;
    };
    const svg = (link, url) =>
      /svg/i.test(link.getAttribute("type") || "") || /\.svg$/i.test(url.pathname);
    // A link whose address cannot be parsed is skipped.
    const links = (rel) =>
      [...document.querySelectorAll(`link[rel~="${rel}" i][href]`)]
        .flatMap((link) => URL.canParse(link.href) ? [{ link, url: new URL(link.href) }] : [])
        .filter(({ link, url }) => /^https?:$/.test(url.protocol) && !svg(link, url));
    const icons = [
      ...links("icon").sort((a, b) => size(a.link) - size(b.link)),
      ...links("apple-touch-icon"),
    ].map(({ url }) => url.href);
    icons.push(new URL("/favicon.ico", location.origin).href);
    return [...new Set(icons)].slice(0, 4);
  };
  const post = (message) =>
    (window.webkit?.messageHandlers?.RelayBrowser ?? window.RelayBrowser)?.postMessage(message);
  let last = "";
  const report = () => {
    const icons = JSON.stringify(listed());
    if (icons === last) return;
    last = icons;
    post(`icons:${JSON.stringify({ page: location.href, icons: JSON.parse(icons) })}`);
  };
  report();
  if (window.__relayIcons) return;
  window.__relayIcons = true;
  new MutationObserver(report).observe(document.head || document.documentElement, {
    childList: true, subtree: true, attributes: true, attributeFilter: ["href", "rel", "sizes", "type"],
  });
})();

// Desktop only. Runs in every frame of a Browser tab before the page's own
// scripts. WKWebView ships with page fullscreen switched off, so video
// players' fullscreen buttons do nothing. This gives pages the standard
// fullscreen calls and makes the chosen element fill the web view, which is
// the tab's pane: in split view a fullscreen video fills its zone, and Relay
// shows a tab that is alone on the whole screen.
//
// The page's own scripts run later and may replace any built-in object, so
// everything that decides whether Relay hides its controls, or lets the user
// out again, is taken here first and never looked up again.
(() => {
  const apply = Reflect.apply;
  const getter = (prototype, name) => Object.getOwnPropertyDescriptor(prototype, name).get;
  const activation = navigator.userActivation;
  const isActive = getter(UserActivation.prototype, "isActive");
  const keyOf = getter(KeyboardEvent.prototype, "key");
  const isConnected = getter(Node.prototype, "isConnected");
  const preventDefault = Event.prototype.preventDefault;
  const stopNow = Event.prototype.stopImmediatePropagation;
  const top = window === window.top;
  const topWindow = window.top, parentWindow = window.parent;
  // A popup window shares its tab's channel; it fills only its own window.
  const popup = top && window.opener != null;

  // Every frame can post on Relay's channel, so Relay accepts fullscreen
  // messages only with this tab's key, which Relay puts in this script.
  const key = RELAY_KEY;
  const channel = window.webkit?.messageHandlers?.RelayBrowser ?? window.RelayBrowser;
  const post = channel?.postMessage.bind(channel);

  // Like a browser, only a click or key press may take the screen. A click
  // inside a frame also counts for the frames that contain it.
  const clicked = () => apply(isActive, activation, []);

  // As in a browser, starting fullscreen uses up the click: after fullscreen
  // starts or ends, the next start needs a new click or key press other than
  // Escape, or WebKit's 5-second activation must have run out. Clicks inside
  // a frame are not seen here, so a frame's request within those seconds
  // waits for a click on this page.
  const now = performance.now.bind(performance);
  let fresh = true, spentAt = -Infinity;
  const unspent = () => fresh || now() - spentAt > 5000;
  const spend = () => { fresh = false; spentAt = now(); };
  addEventListener("pointerdown", (event) => { if (event.isTrusted) fresh = true; }, true);

  let current = null, addedPopover = false;
  const sheet = new CSSStyleSheet();

  const tell = (state) => {
    try {
      if (!top) parentWindow.postMessage({ relayFullscreen: state }, "*");
      else if (!popup) post("fullscreen:" + state + ":" + key);
    } catch {}
  };
  const announce = (element) => queueMicrotask(() => {
    const target = element.isConnected ? element : document;
    for (const type of ["fullscreenchange", "webkitfullscreenchange"]) {
      target.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
    }
  });

  // The same rules as the browser's own fullscreen style. The popover top
  // layer keeps the element above the page and free of its ancestors'
  // transforms; the :where() rules undo the popover's own default look. A
  // constructed style sheet is not blocked by a site's style policy.
  const css = `:not(:root)[data-relay-fullscreen]{object-fit:contain;position:fixed!important;inset:0!important;margin:0!important;box-sizing:border-box!important;min-width:0!important;max-width:none!important;min-height:0!important;max-height:none!important;width:100%!important;height:100%!important;transform:none!important;z-index:2147483647!important}
iframe[data-relay-fullscreen]{border:none!important;padding:0!important}
:where(:not(:root)[data-relay-fullscreen]){background:#000}
:where([data-relay-fullscreen][popover]){border:0;padding:0;overflow:visible;color:inherit}
[data-relay-fullscreen]::backdrop{background:#000}
html[data-relay-fullscreen-root]{overflow:hidden!important}`;
  sheet.replaceSync(css);
  function addStyle() {
    if (!document.adoptedStyleSheets.includes(sheet)) {
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    }
  }

  // Browsers end fullscreen when its element leaves the page, as when a
  // single-page site rebuilds its player.
  const removal = new MutationObserver(() => {
    if (current && !apply(isConnected, current, [])) exit();
  });

  // Takes the element out of fullscreen: its style marks, its popover and any
  // fullscreen inside it, if it is a frame.
  function release() {
    const element = current;
    if (!element) return null;
    current = null;
    try {
      removal.disconnect();
      if (addedPopover) {
        addedPopover = false;
        element.hidePopover();
        element.removeAttribute("popover");
      }
    } catch {}
    try {
      element.removeAttribute("data-relay-fullscreen");
      document.documentElement.removeAttribute("data-relay-fullscreen-root");
      if (element.localName === "iframe") {
        element.contentWindow?.postMessage({ relayFullscreen: "exit" }, "*");
      }
    } catch {}
    return element;
  }

  // Relay hears of the exit before the page's element is touched, so a page
  // that breaks DOM calls cannot keep Relay's controls hidden.
  function exit() {
    const element = current;
    if (!element) return;
    spend();
    tell("exit");
    release();
    announce(element);
  }

  function enter(element) {
    if (current === element) return;
    spend();
    const previous = release();
    if (previous) announce(previous);
    current = element;
    addStyle();
    element.setAttribute("data-relay-fullscreen", "");
    document.documentElement.setAttribute("data-relay-fullscreen-root", "");
    if (element !== document.documentElement && element.showPopover && !element.hasAttribute("popover")) {
      element.setAttribute("popover", "manual");
      try {
        element.showPopover();
        addedPopover = true;
      } catch {
        element.removeAttribute("popover");
      }
    }
    removal.observe(document, { childList: true, subtree: true });
    announce(element);
    tell("enter");
  }

  function request() {
    if (this === current) return Promise.resolve();
    const allowed = this instanceof Element && this.isConnected && clicked() && unspent();
    if (!allowed) {
      if (this instanceof Element) {
        queueMicrotask(() => this.dispatchEvent(new Event("fullscreenerror", { bubbles: true, composed: true })));
      }
      return Promise.reject(new TypeError("Fullscreen needs a click or key press."));
    }
    enter(this);
    return Promise.resolve();
  }
  function leave() {
    exit();
    return Promise.resolve();
  }

  const define = (prototype, names, descriptor) => {
    for (const name of names) {
      try { Object.defineProperty(prototype, name, { configurable: true, ...descriptor }); } catch {}
    }
  };
  define(Element.prototype, ["requestFullscreen", "webkitRequestFullscreen", "webkitRequestFullScreen"], { writable: true, value: request });
  define(Document.prototype, ["exitFullscreen", "webkitExitFullscreen", "webkitCancelFullScreen"], { writable: true, value: leave });
  define(Document.prototype, ["fullscreenElement", "webkitFullscreenElement", "webkitCurrentFullScreenElement"], { get: () => current });
  define(Document.prototype, ["fullscreenEnabled", "webkitFullscreenEnabled"], { get: () => true });
  define(Document.prototype, ["fullscreen", "webkitIsFullScreen"], { get: () => current !== null });
  // With fullscreen off, WebKit also leaves out the handler properties such as
  // document.onfullscreenchange, which YouTube uses to switch its layout.
  const handlers = new WeakMap();
  for (const prototype of [Document.prototype, Element.prototype]) {
    for (const name of ["onfullscreenchange", "onwebkitfullscreenchange"]) {
      if (name in prototype) continue;
      define(prototype, [name], {
        get() { return handlers.get(this)?.[name] ?? null; },
        set(handler) {
          let own = handlers.get(this);
          if (!own) handlers.set(this, own = {});
          if (!(name in own)) {
            this.addEventListener(name.slice(2), (event) => {
              if (typeof own[name] === "function") apply(own[name], this, [event]);
            });
          }
          own[name] = typeof handler === "function" ? handler : null;
        },
      });
    }
  }
  // Safari's video-only calls, which some players use instead.
  define(HTMLVideoElement.prototype, ["webkitEnterFullscreen", "webkitEnterFullScreen"], { writable: true, value: request });
  define(HTMLVideoElement.prototype, ["webkitExitFullscreen", "webkitExitFullScreen"], {
    writable: true, value() { if (current === this) exit(); },
  });
  define(HTMLVideoElement.prototype, ["webkitSupportsFullscreen"], { get: () => true });
  define(HTMLVideoElement.prototype, ["webkitDisplayingFullscreen"], { get() { return current === this; } });

  // Relay ends fullscreen when the window leaves macOS fullscreen.
  Object.defineProperty(window, "__relayExitFullscreen", { value: exit });

  // The first listener on the window, so the page cannot stop it. Escape in a
  // frame inside the fullscreen element reaches the top page, which ends it
  // for every frame.
  addEventListener("keydown", (event) => {
    if (apply(keyOf, event, []) !== "Escape") {
      if (event.isTrusted) fresh = true;
      return;
    }
    if (!current) {
      if (!top) topWindow.postMessage({ relayFullscreen: "exit" }, "*");
      return;
    }
    exit();
    try {
      apply(preventDefault, event, []);
      apply(stopNow, event, []);
    } catch {}
  }, true);

  // An embedded player asks its parent to fill the parent's page with its
  // frame. As in a browser, the frame must allow fullscreen, and the user
  // must have clicked or pressed a key. Any frame may end fullscreen.
  addEventListener("message", (event) => {
    const state = event.data?.relayFullscreen;
    if (state === "exit") return exit();
    if (state !== "enter") return;
    const frame = [...document.getElementsByTagName("iframe")].find((f) => f.contentWindow === event.source);
    if (!frame || !(frame.allowFullscreen || /\bfullscreen\b/.test(frame.allow))) return;
    if (clicked() && unspent()) return enter(frame);
    // Refused, so the player leaves the fullscreen it took inside its frame.
    frame.contentWindow.postMessage({ relayFullscreen: "exit" }, "*");
  });
})();

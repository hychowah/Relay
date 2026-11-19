// Desktop only. Runs in every frame of a Browser tab before the page's own
// scripts. WKWebView ships with page fullscreen switched off, so video
// players' fullscreen buttons do nothing. This gives pages the standard
// fullscreen calls and makes the chosen element fill the web view, which is
// the tab's pane: in split view a fullscreen video fills its zone, and Relay
// shows a tab that is alone on the whole screen.
(() => {
  const top = window === window.top;
  let current = null, addedPopover = false, style = null;

  // Every frame can post on Relay's channel, so Relay accepts fullscreen
  // messages only with this tab's key, which Relay puts in this script. The
  // channel is taken before the page's scripts run, so they cannot wrap it.
  const key = RELAY_KEY;
  const channel = window.webkit?.messageHandlers?.RelayBrowser ?? window.RelayBrowser;
  const post = channel?.postMessage.bind(channel);
  const tell = (state) => {
    if (!top) return parent.postMessage({ relayFullscreen: state }, "*");
    try { post("fullscreen:" + state + ":" + key); } catch {}
  };
  const announce = (element) => queueMicrotask(() => {
    const target = element.isConnected ? element : document;
    for (const type of ["fullscreenchange", "webkitfullscreenchange"]) {
      target.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
    }
  });

  // The same rules as the browser's own fullscreen style. The popover top
  // layer keeps the element above the page and free of its ancestors'
  // transforms; the :where() rules undo the popover's own default look.
  const css = `:not(:root)[data-relay-fullscreen]{object-fit:contain;position:fixed!important;inset:0!important;margin:0!important;box-sizing:border-box!important;min-width:0!important;max-width:none!important;min-height:0!important;max-height:none!important;width:100%!important;height:100%!important;transform:none!important;z-index:2147483647!important}
iframe[data-relay-fullscreen]{border:none!important;padding:0!important}
:where(:not(:root)[data-relay-fullscreen]){background:#000}
:where([data-relay-fullscreen][popover]){border:0;padding:0;overflow:visible;color:inherit}
[data-relay-fullscreen]::backdrop{background:#000}
html[data-relay-fullscreen-root]{overflow:hidden!important}`;

  function release() {
    const element = current;
    if (!element) return null;
    current = null;
    if (addedPopover) {
      try { element.hidePopover(); } catch {}
      element.removeAttribute("popover");
      addedPopover = false;
    }
    element.removeAttribute("data-relay-fullscreen");
    document.documentElement.removeAttribute("data-relay-fullscreen-root");
    if (element.localName === "iframe") {
      element.contentWindow?.postMessage({ relayFullscreen: "exit" }, "*");
    }
    return element;
  }

  function enter(element) {
    if (current === element) return;
    const previous = release();
    if (previous) announce(previous);
    current = element;
    if (!style?.isConnected) {
      style = document.createElement("style");
      style.textContent = css;
      (document.head || document.documentElement).append(style);
    }
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
    announce(element);
    tell("enter");
  }

  function exit() {
    const element = release();
    if (!element) return;
    announce(element);
    tell("exit");
  }

  function request() {
    // Like a browser, only a click or key press may take the screen.
    const allowed = this instanceof Element && this.isConnected &&
      (navigator.userActivation?.isActive ?? true);
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
  // Safari's video-only calls, which some players use instead.
  define(HTMLVideoElement.prototype, ["webkitEnterFullscreen", "webkitEnterFullScreen"], { writable: true, value: request });
  define(HTMLVideoElement.prototype, ["webkitExitFullscreen", "webkitExitFullScreen"], {
    writable: true, value() { if (current === this) exit(); },
  });
  define(HTMLVideoElement.prototype, ["webkitSupportsFullscreen"], { get: () => true });
  define(HTMLVideoElement.prototype, ["webkitDisplayingFullscreen"], { get() { return current === this; } });

  // Relay ends fullscreen when the window leaves macOS fullscreen.
  Object.defineProperty(window, "__relayExitFullscreen", { value: exit });

  addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !current) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    exit();
  }, true);

  // An embedded player asks its parent to fill the parent's page with its
  // frame. As in a browser, the frame must allow fullscreen.
  addEventListener("message", (event) => {
    const state = event.data?.relayFullscreen;
    if (state === "exit" && !top && event.source === parent) return exit();
    if (state === "exit" && current?.contentWindow === event.source) return exit();
    if (state !== "enter") return;
    const frame = [...document.getElementsByTagName("iframe")].find((f) => f.contentWindow === event.source);
    if (frame && (frame.allowFullscreen || /\bfullscreen\b/.test(frame.allow))) enter(frame);
  });
})();

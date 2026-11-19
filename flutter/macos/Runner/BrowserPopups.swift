import Cocoa
import FlutterMacOS
import WebKit

/// Desktop only. Opens a Browser tab's new windows (`window.open`, links that
/// target a new window) as popup windows that are real children of the page.
///
/// webview_flutter_wkwebview 3.27.2 loads such a request into the opener's own
/// web view, which replaces the opener and breaks sign-in popups. This object
/// becomes the web view's UI delegate, answers only WebKit's create-web-view
/// and close calls, and forwards every other call (page dialogs, permission
/// requests) to the plugin's own delegate, which it keeps alive.
final class BrowserPopups: NSObject, WKUIDelegate {
  static let windowIdentifier = NSUserInterfaceItemIdentifier("RelayBrowserPopup")
  private static var key: UInt8 = 0

  private let channel: FlutterMethodChannel
  private let inner: WKUIDelegate?
  private var popups: [Popup] = []
  /// Set for a popup's own web view: its page called `window.close()`.
  fileprivate var onClose: (() -> Void)?

  fileprivate init(channel: FlutterMethodChannel, forwardingTo inner: WKUIDelegate?) {
    self.channel = channel
    self.inner = inner
  }

  deinit {
    for popup in popups { popup.window.close() }
  }

  /// Makes a tab's web view open new windows as popups; returns how many are open.
  static func install(on webView: WKWebView, channel: FlutterMethodChannel) -> Int {
    if let existing = objc_getAssociatedObject(webView, &key) as? BrowserPopups {
      return existing.popups.count
    }
    let popups = BrowserPopups(channel: channel, forwardingTo: webView.uiDelegate)
    // WKWebView holds its UI delegate weakly; the web view keeps this one.
    objc_setAssociatedObject(webView, &key, popups, .OBJC_ASSOCIATION_RETAIN)
    // WebKit reads which delegate methods exist when the delegate is set.
    webView.uiDelegate = popups
    return 0
  }

  /// Closes a tab's popups, with theirs; returns how many were open.
  static func close(on webView: WKWebView) -> Int {
    (objc_getAssociatedObject(webView, &key) as? BrowserPopups)?.closeAll() ?? 0
  }

  @discardableResult
  fileprivate func closeAll() -> Int {
    let open = popups
    for popup in open { popup.window.close() }
    return open.count
  }

  override func responds(to aSelector: Selector!) -> Bool {
    super.responds(to: aSelector) || inner?.responds(to: aSelector) == true
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    if let inner = inner, inner.responds(to: aSelector) { return inner }
    return super.forwardingTarget(for: aSelector)
  }

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    let popup = Popup(configuration: configuration, opener: webView, features: windowFeatures, channel: channel)
    popup.onClosed = { [weak self, weak popup] in self?.popups.removeAll { $0 === popup } }
    popups.append(popup)
    return popup.webView
  }

  func webViewDidClose(_ webView: WKWebView) {
    onClose?()
  }
}

/// One popup window. Its web view is made from the configuration WebKit passed,
/// so `window.opener`, `postMessage`, cookies and the opener's handle all work.
private final class Popup: NSObject, WKNavigationDelegate, NSWindowDelegate {
  let webView: WKWebView
  let window: NSWindow
  var onClosed: (() -> Void)?
  private let children: BrowserPopups
  private let channel: FlutterMethodChannel
  private var committed = false
  private var address: NSKeyValueObservation?

  init(
    configuration: WKWebViewConfiguration, opener: WKWebView, features: WKWindowFeatures,
    channel: FlutterMethodChannel
  ) {
    self.channel = channel
    webView = WKWebView(frame: .zero, configuration: configuration)
    // The user agent belongs to the web view, not its configuration.
    webView.customUserAgent = opener.customUserAgent
    let screen = (opener.window?.screen ?? NSScreen.main)?.visibleFrame.size
      ?? NSSize(width: 1200, height: 900)
    func side(_ asked: NSNumber?, _ fallback: CGFloat, _ limit: CGFloat) -> CGFloat {
      min(max(asked.map { CGFloat($0.doubleValue) } ?? fallback, 240), limit)
    }
    let size = NSSize(
      width: side(features.width, 900, screen.width), height: side(features.height, 700, screen.height - 40))
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    children = BrowserPopups(channel: channel, forwardingTo: nil)
    super.init()

    window.isReleasedWhenClosed = false
    window.identifier = BrowserPopups.windowIdentifier
    window.tabbingMode = .disallowed
    window.minSize = NSSize(width: 240, height: 160)
    window.contentView = webView
    window.delegate = self
    webView.navigationDelegate = self
    webView.uiDelegate = children
    children.onClose = { [weak self] in self?.window.close() }
    // The title bar names the site, since the popup has no address bar.
    address = webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
      self?.window.title = view.url?.host ?? view.url?.absoluteString ?? ""
    }
    if let parent = opener.window?.frame {
      window.setFrameOrigin(NSPoint(x: parent.midX - size.width / 2, y: parent.midY - size.height / 2))
    } else {
      window.center()
    }
    window.makeKeyAndOrderFront(nil)
  }

  deinit {
    window.delegate = nil
  }

  func windowWillClose(_ notification: Notification) {
    children.closeAll()
    address = nil
    webView.stopLoading()
    // Let AppKit finish closing before the window and its web view are released.
    DispatchQueue.main.async { self.onClosed?() }
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    committed = true
  }

  // The Browser's address rule (Dart `publicPageAllowed`) decides every
  // main-frame load. A popup refused before it shows any page closes.
  private func decide(_ action: WKNavigationAction, _ done: @escaping (Bool) -> Void) {
    guard action.targetFrame?.isMainFrame == true, let url = action.request.url?.absoluteString else {
      done(true)
      return
    }
    channel.invokeMethod("allowPopupPage", arguments: url) { [weak self] result in
      let allowed = result as? Bool == true
      done(allowed)
      if !allowed, self?.committed == false { self?.window.close() }
    }
  }

  #if compiler(>=6.0)
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      decide(navigationAction) { allowed in
        DispatchQueue.main.async { decisionHandler(allowed ? .allow : .cancel) }
      }
    }
  #else
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      decide(navigationAction) { allowed in
        DispatchQueue.main.async { decisionHandler(allowed ? .allow : .cancel) }
      }
    }
  #endif
}

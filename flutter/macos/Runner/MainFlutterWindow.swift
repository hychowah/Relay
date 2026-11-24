import Cocoa
import FlutterMacOS
import Network
import WebKit
import webview_flutter_wkwebview

class MainFlutterWindow: NSWindow {
  /// The Browser tab whose fullscreen page fills the screen, and whether
  /// Relay put the window into macOS fullscreen for it.
  private var screenPage: Int64?
  private var ownsFullScreen = false

  override func awakeFromNib() {
    MainFlutterWindow.keepWebViewsAttached()
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.setContentSize(NSSize(width: 1280, height: 800))
    self.minSize = NSSize(width: 720, height: 600)
    self.center()
    // AppKit reopens the window at the size and position it was last left.
    self.setFrameAutosaveName("RelayMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)

    let browser = FlutterMethodChannel(
      name: "app.relay/browser", binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    browser.setMethodCallHandler { [weak self, weak flutterViewController] call, result in
      if call.method == "documentStartScript" || call.method == "fillScreen" {
        guard let registry = flutterViewController, let window = self,
              let arguments = call.arguments as? [String: Any],
              let identifier = arguments["view"] as? NSNumber else {
          result(FlutterError(code: call.method, message: "The page has no web view.", details: nil))
          return
        }
        if let on = arguments["on"] as? Bool {
          window.fillScreen(identifier.int64Value, on)
        } else if let source = arguments["source"] as? String,
                  let view = FWFWebViewFlutterWKWebViewExternalAPI.webView(
                    forIdentifier: identifier.int64Value, withPluginRegistry: registry
                  ) {
          view.configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
          )
        }
        result(nil)
        return
      }
      // A VPN tab's profile sends every load through the Relay backend's
      // tunnel (HTTP CONNECT), with no fallback to a direct connection. The
      // tunnel carries only TCP, so WebRTC, whose UDP would show the Mac's
      // address, is turned off with WebKit's private setting, which also
      // covers frames and popups; a VPN tab without it does not load.
      if call.method == "vpnProxy" {
        guard let registry = flutterViewController, let arguments = call.arguments as? [String: Any],
              let identifier = arguments["view"] as? NSNumber, let host = arguments["host"] as? String,
              let port = arguments["port"] as? Int,
              let view = FWFWebViewFlutterWKWebViewExternalAPI.webView(
                forIdentifier: identifier.int64Value, withPluginRegistry: registry
              ) else {
          result(FlutterError(code: "vpnProxy", message: "The page has no web view.", details: nil))
          return
        }
        let preferences = view.configuration.preferences
        guard preferences.responds(to: Selector(("_setPeerConnectionEnabled:"))) else {
          result(FlutterError(code: "vpnProxy", message: "WebRTC cannot be turned off on this macOS.", details: nil))
          return
        }
        preferences.setValue(false, forKey: "peerConnectionEnabled")
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(
          host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port))))
        proxy.allowFailover = false
        view.configuration.websiteDataStore.proxyConfigurations = [proxy]
        result(nil)
        return
      }
      if call.method == "popups" || call.method == "closePopups" {
        guard let registry = flutterViewController, let identifier = call.arguments as? NSNumber,
              let view = FWFWebViewFlutterWKWebViewExternalAPI.webView(
                forIdentifier: identifier.int64Value, withPluginRegistry: registry
              ) else {
          result(FlutterError(code: "popups", message: "The page has no web view.", details: nil))
          return
        }
        result(call.method == "popups"
          ? BrowserPopups.install(on: view, channel: browser) : BrowserPopups.close(on: view))
        return
      }
      #if DEBUG
        // Mac checks send real mouse input this way: queued AppKit events
        // reach Flutter, WebKit and PDFKit as a user's would, unlike a
        // test's own taps. `type` is down, dragged, up or moved, at Flutter's
        // logical `x` and `y` from the window's content top left.
        if call.method == "mouse" {
          guard let window = self, let view = window.contentView,
                let arguments = call.arguments as? [String: Any],
                let type = arguments["type"] as? String,
                let x = arguments["x"] as? Double, let y = arguments["y"] as? Double else {
            result(nil)
            return
          }
          let kinds: [String: NSEvent.EventType] = [
            "down": .leftMouseDown, "dragged": .leftMouseDragged, "up": .leftMouseUp,
            "moved": .mouseMoved,
          ]
          if type == "down" || (type == "moved" && !NSApp.isActive) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
          }
          let point = view.convert(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
          // A moved event also moves the real pointer there: WebKit finds the
          // item under the mouse from the pointer, not only from events.
          if type == "moved", let screen = NSScreen.screens.first {
            let global = window.convertPoint(toScreen: point)
            CGWarpMouseCursorPosition(CGPoint(x: global.x, y: screen.frame.height - global.y))
          }
          if let kind = kinds[type], let event = NSEvent.mouseEvent(
            with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == "up" ? 0 : 1) {
            NSApp.postEvent(event, atStart: false)
          }
          // Where AppKit sends a click at that point, for the check to report.
          let hit = view.superview.flatMap { view.hitTest($0.convert(point, from: nil)) }
          result([
            "hit": hit.map { String(describing: Swift.type(of: $0)) } ?? "none",
            "key": window.isKeyWindow, "active": NSApp.isActive,
          ])
          return
        }
      #endif
      if call.method == "pdf" {
        guard let registry = flutterViewController, let arguments = call.arguments as? [String: Any],
              let identifier = arguments["view"] as? NSNumber,
              let view = FWFWebViewFlutterWKWebViewExternalAPI.webView(
                forIdentifier: identifier.int64Value, withPluginRegistry: registry
              ) else {
          result(nil)
          return
        }
        BrowserPDF.perform(arguments, on: view, identifier: identifier.int64Value, channel: browser, result: result)
        return
      }
      // A preview is a small picture for the tab's hover card, kept only in
      // Flutter's memory while the card shows. A PDF in Relay's viewer gives
      // none, rather than a full-size picture encoded on every hover.
      if call.method == "snapshot" || call.method == "selection" || call.method == "preview" {
        guard let registry = flutterViewController, let identifier = call.arguments as? NSNumber,
              let view = FWFWebViewFlutterWKWebViewExternalAPI.webView(
                forIdentifier: identifier.int64Value, withPluginRegistry: registry
              ), !view.bounds.isEmpty else {
          if call.method != "snapshot" { result(nil); return }
          result(FlutterError(code: "capture", message: "Open the page before capturing it.", details: nil))
          return
        }
        // A PDF shown in Relay's own viewer answers for the page under it.
        if let pdf = BrowserPDF.shown(on: view) {
          if call.method == "preview" {
            result(nil)
          } else if call.method == "selection" {
            result(pdf.selection)
          } else if let png = pdf.snapshot() {
            result(FlutterStandardTypedData(bytes: png))
          } else {
            result(FlutterError(code: "capture", message: "Page capture failed.", details: nil))
          }
          return
        }
        if call.method == "selection" {
          // WebKit's Services interface also reads the focused embedded PDF.
          // PDF selections use AppKit's legacy plain-text pasteboard type.
          let board = NSPasteboard.withUniqueName()
          defer { board.releaseGlobally() }
          let textType = NSPasteboard.PasteboardType("NSStringPboardType")
          let requestor: AnyObject = view
          if requestor.writeSelection?(to: board, types: [textType]) == true,
             let text = board.string(forType: textType), !text.isEmpty {
            result(String(text.prefix(4000)))
          } else {
            result(nil)
          }
          return
        }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: Double(min(view.bounds.width, call.method == "preview" ? 240 : 1600)))
        view.takeSnapshot(with: config) { image, error in
          guard let data = image?.tiffRepresentation,
                let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            result(FlutterError(code: "capture", message: error?.localizedDescription ?? "Page capture failed.", details: nil))
            return
          }
          result(FlutterStandardTypedData(bytes: png))
        }
        return
      }
      if call.method == "playing" {
        // WebKit's private flag behind Safari's sound icon: audible media or
        // Web Audio in any frame of the page. Nil when WebKit lacks it.
        let key = "_isPlayingAudio"
        guard let registry = flutterViewController, let identifier = call.arguments as? NSNumber,
              let view = FWFWebViewFlutterWKWebViewExternalAPI.webView(
                forIdentifier: identifier.int64Value, withPluginRegistry: registry
              ), view.responds(to: NSSelectorFromString(key)) else {
          result(nil)
          return
        }
        result((view.value(forKey: key) as? NSNumber)?.boolValue)
        return
      }
      if call.method == "memory" {
        // One call reads Relay and every listed tab, so a reading costs one
        // lookup and one system call per tab.
        guard let registry = flutterViewController else {
          result(nil)
          return
        }
        var views: [NSNumber: [NSNumber]] = [:]
        for identifier in call.arguments as? [NSNumber] ?? [] {
          guard let view = FWFWebViewFlutterWKWebViewExternalAPI.webView(
                  forIdentifier: identifier.int64Value, withPluginRegistry: registry
                ) else { continue }
          let process = MainFlutterWindow.webProcess(of: view)
          if process > 0, let bytes = MainFlutterWindow.footprint(of: process) {
            views[identifier] = [NSNumber(value: process), NSNumber(value: bytes)]
          }
        }
        result(["app": NSNumber(value: MainFlutterWindow.footprint(of: getpid()) ?? 0), "views": views])
        return
      }
      guard call.method == "safariVersion" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
      let safari = url.flatMap { Bundle(url: $0) }
      result(safari?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    // Leaving macOS fullscreen by hand also ends the page's fullscreen.
    NotificationCenter.default.addObserver(
      forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main
    ) { [weak self] _ in
      guard let window = self else { return }
      window.ownsFullScreen = false
      if window.screenPage != nil {
        window.screenPage = nil
        browser.invokeMethod("leftScreen", arguments: nil)
      }
    }

    super.awakeFromNib()
  }

  /// On every frame Flutter adds each web view's container to its parent
  /// again, under a view of Flutter's own that it then puts back on top. To
  /// reorder them AppKit takes the container out of the window and puts it
  /// back, and WebKit then finds the item under the mouse from the wrong
  /// place: as far below and to the right of the mouse as the page is inside
  /// the window, until the mouse moves (bug reports of 2026-11-24). Flutter's
  /// two container classes skip adding a view to the parent it already has;
  /// the views end in the same order. If a Flutter update renames them or
  /// adds its own `addSubview:`, nothing is changed.
  private static func keepWebViewsAttached() {
    let selector = #selector(NSView.addSubview(_:))
    guard let method = class_getInstanceMethod(NSView.self, selector) else { return }
    typealias AddSubview = @convention(c) (NSView, Selector, NSView) -> Void
    let add = unsafeBitCast(method_getImplementation(method), to: AddSubview.self)
    let keep: @convention(block) (NSView, NSView) -> Void = { parent, child in
      if child.superview === parent { return }
      add(parent, selector, child)
    }
    for name in ["FlutterMutatorView", "FlutterPathClipView"] {
      guard let type = NSClassFromString(name) else { continue }
      class_addMethod(type, selector, imp_implementationWithBlock(keep), method_getTypeEncoding(method))
    }
  }

  /// Puts the window into macOS fullscreen for a Browser tab's fullscreen
  /// page, and takes it back out only if Relay put it there.
  private func fillScreen(_ page: Int64, _ on: Bool) {
    let full = styleMask.contains(.fullScreen)
    if on {
      screenPage = page
      if !full {
        ownsFullScreen = true
        toggleFullScreen(nil)
      }
    } else if screenPage == page {
      screenPage = nil
      if ownsFullScreen {
        ownsFullScreen = false
        if full { toggleFullScreen(nil) }
      }
    }
  }

  /// The web view's WebContent process, from WebKit's private
  /// `_webProcessIdentifier`; 0 before the page's process starts.
  private static func webProcess(of view: WKWebView) -> pid_t {
    let key = "_webProcessIdentifier"
    guard view.responds(to: NSSelectorFromString(key)) else { return 0 }
    return (view.value(forKey: key) as? NSNumber)?.int32Value ?? 0
  }

  /// A process's physical footprint in bytes: Activity Monitor's Memory.
  private static func footprint(of process: pid_t) -> UInt64? {
    var usage = rusage_info_v2()
    let status = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(process, RUSAGE_INFO_V2, $0)
      }
    }
    return status == 0 ? usage.ri_phys_footprint : nil
  }

  // Browser popups never outlive the window whose tabs opened them.
  override func close() {
    for window in NSApp.windows where window.identifier == BrowserPopups.windowIdentifier {
      window.close()
    }
    super.close()
  }
}

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
        // test's own taps. `type` is down, dragged or up, at Flutter's
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
          ]
          if type == "down" {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
          }
          let point = view.convert(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
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
      if call.method == "snapshot" || call.method == "selection" {
        guard let registry = flutterViewController, let identifier = call.arguments as? NSNumber,
              let view = FWFWebViewFlutterWKWebViewExternalAPI.webView(
                forIdentifier: identifier.int64Value, withPluginRegistry: registry
              ), !view.bounds.isEmpty else {
          if call.method == "selection" { result(nil); return }
          result(FlutterError(code: "capture", message: "Open the page before capturing it.", details: nil))
          return
        }
        // A PDF shown in Relay's own viewer answers for the page under it.
        if let pdf = BrowserPDF.shown(on: view) {
          if call.method == "selection" {
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
        config.snapshotWidth = NSNumber(value: Double(min(view.bounds.width, 1600)))
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

  // Browser popups never outlive the window whose tabs opened them.
  override func close() {
    for window in NSApp.windows where window.identifier == BrowserPopups.windowIdentifier {
      window.close()
    }
    super.close()
  }
}

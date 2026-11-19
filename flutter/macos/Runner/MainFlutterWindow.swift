import Cocoa
import FlutterMacOS
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
      if call.method == "snapshot" || call.method == "selection" {
        guard let registry = flutterViewController, let identifier = call.arguments as? NSNumber,
              let view = FWFWebViewFlutterWKWebViewExternalAPI.webView(
                forIdentifier: identifier.int64Value, withPluginRegistry: registry
              ), !view.bounds.isEmpty else {
          if call.method == "selection" { result(nil); return }
          result(FlutterError(code: "capture", message: "Open the page before capturing it.", details: nil))
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

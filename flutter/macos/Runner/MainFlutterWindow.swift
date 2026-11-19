import Cocoa
import FlutterMacOS
import WebKit
import webview_flutter_wkwebview

class MainFlutterWindow: NSWindow {
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
    browser.setMethodCallHandler { [weak flutterViewController] call, result in
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

    super.awakeFromNib()
  }
}

import FlutterMacOS
import WebKit

/// Desktop only (macOS). Carries Browser tabs' downloads between WebKit and
/// `browser_downloads.dart`, which picks each file and shows the notices.
///
/// One per window. It asks Dart for each download's file (`start`, with the
/// address, the site's name for it and whether the tab is a VPN tab) and
/// reports its end (`ended`) on `app.relay/downloads`. It holds each download
/// until it ends, so a download outlives the tab it came from.
final class BrowserDownloads: NSObject, WKDownloadDelegate {
  private struct Running {
    let download: WKDownload
    let vpn: Bool
    var path: String?
  }

  private let channel: FlutterMethodChannel
  private var running: [ObjectIdentifier: Running] = [:]

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  /// Makes a Browser tab's web view download what it cannot show, an
  /// attachment, or a link marked `download`. Call it after the plugin set the
  /// web view's navigation delegate: setting another one replaces this.
  func install(on webView: WKWebView) {
    DownloadPolicy.install(on: webView, downloads: self)
  }

  fileprivate func track(_ download: WKDownload, from webView: WKWebView) {
    // A VPN tab's profile is the only one with an identifier.
    let vpn = webView.configuration.websiteDataStore.identifier != nil
    running[ObjectIdentifier(download)] = Running(download: download, vpn: vpn)
    download.delegate = self
  }

  func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse,
    suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void
  ) {
    let key = ObjectIdentifier(download)
    let url = response.url ?? download.originalRequest?.url
    channel.invokeMethod("start", arguments: [
      "url": url?.absoluteString ?? "", "name": suggestedFilename, "vpn": running[key]?.vpn == true,
    ]) { [weak self] result in
      let path = result as? String
      self?.running[key]?.path = path
      // No file cancels the download.
      DispatchQueue.main.async { completionHandler(path.map { URL(fileURLWithPath: $0) }) }
    }
  }

  func downloadDidFinish(_ download: WKDownload) {
    ended(download, saved: true)
  }

  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    ended(download, saved: false)
  }

  private func ended(_ download: WKDownload, saved: Bool) {
    guard let path = running.removeValue(forKey: ObjectIdentifier(download))?.path else { return }
    channel.invokeMethod("ended", arguments: ["path": path, "saved": saved])
  }
}

/// Becomes a Browser tab's navigation delegate, answers only the decisions
/// that start downloads, and forwards every other call to the plugin's own
/// delegate, which it keeps alive, as `BrowserPopups` does for the UI delegate.
private final class DownloadPolicy: NSObject, WKNavigationDelegate {
  private static var key: UInt8 = 0

  private let inner: WKNavigationDelegate?
  private weak var downloads: BrowserDownloads?

  private init(forwardingTo inner: WKNavigationDelegate?, downloads: BrowserDownloads) {
    self.inner = inner
    self.downloads = downloads
  }

  static func install(on webView: WKWebView, downloads: BrowserDownloads) {
    if webView.navigationDelegate is DownloadPolicy { return }
    let policy = DownloadPolicy(forwardingTo: webView.navigationDelegate, downloads: downloads)
    // WKWebView holds its navigation delegate weakly; the web view keeps this one.
    objc_setAssociatedObject(webView, &key, policy, .OBJC_ASSOCIATION_RETAIN)
    // WebKit reads which delegate methods exist when the delegate is set.
    webView.navigationDelegate = policy
  }

  override func responds(to aSelector: Selector!) -> Bool {
    super.responds(to: aSelector) || inner?.responds(to: aSelector) == true
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    if let inner = inner, inner.responds(to: aSelector) { return inner }
    return super.forwardingTarget(for: aSelector)
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    let scheme = navigationAction.request.url?.scheme
    guard navigationAction.shouldPerformDownload else {
      forward(webView, navigationAction) { decisionHandler($0) }
      return
    }
    // A blob: or data: link holds what the page itself made. Any other
    // download link first passes the Browser's address rule, as a page would.
    if scheme == "blob" || scheme == "data" {
      decisionHandler(.download)
    } else {
      forward(webView, navigationAction) { decisionHandler($0 == .allow ? .download : $0) }
    }
  }

  private func forward(
    _ webView: WKWebView, _ action: WKNavigationAction,
    _ done: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    let asked: Void? = inner?.webView?(webView, decidePolicyFor: action, decisionHandler: { done($0) })
    if asked == nil { done(.allow) }
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
  ) {
    let disposition = (navigationResponse.response as? HTTPURLResponse)?
      .value(forHTTPHeaderField: "Content-Disposition")
    if !navigationResponse.canShowMIMEType
      || disposition?.lowercased().hasPrefix("attachment") == true
    {
      decisionHandler(.download)
      return
    }
    let asked: Void? = inner?.webView?(webView, decidePolicyFor: navigationResponse, decisionHandler: {
      decisionHandler($0)
    })
    if asked == nil { decisionHandler(.allow) }
  }

  func webView(
    _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
  ) {
    downloads?.track(download, from: webView)
  }

  func webView(
    _ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload
  ) {
    downloads?.track(download, from: webView)
  }
}

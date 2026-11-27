import FlutterMacOS
import WebKit

/// Desktop only. Fetches a Browser tab's site icon for Relay's tab listings
/// (flutter/lib/site_icon.dart) over the tab's own route, so a VPN tab's
/// icon comes through its tunnel. The fetch sends no cookies, and its bytes
/// reach only Relay. The answer is the bytes, or nil for anything but a 2xx
/// answer within 10 s and 512 KB.
enum BrowserIcon {
  static func fetch(_ url: URL, for webView: WKWebView, result: @escaping FlutterResult) {
    let configuration = webView.tabFetches
    configuration.timeoutIntervalForResource = 10
    let session = URLSession(configuration: configuration, delegate: IconFetch(result), delegateQueue: nil)
    session.dataTask(with: url).resume()
    session.finishTasksAndInvalidate()
  }
}

private final class IconFetch: NSObject, URLSessionDataDelegate {
  private static let largest = 512 * 1024
  private let result: FlutterResult
  private var received = Data()

  init(_ result: @escaping FlutterResult) {
    self.result = result
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let wanted = (200..<300).contains(status) && response.expectedContentLength <= Int64(IconFetch.largest)
    completionHandler(wanted ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    received.append(data)
    if received.count > IconFetch.largest { dataTask.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let fetched = error == nil ? FlutterStandardTypedData(bytes: received) : nil
    DispatchQueue.main.async { self.result(fetched) }
  }
}

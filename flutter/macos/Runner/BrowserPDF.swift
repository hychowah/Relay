import Cocoa
import FlutterMacOS
import PDFKit
import WebKit

/// Desktop only. Shows the PDF a Browser tab has loaded in PDFKit's viewer,
/// laid over the tab's web view. The web view keeps the address, history and
/// Back; this view adds zoom, highlights and a selection Relay can read.
///
/// WebKit's own PDF view has no calls for zoom or highlights and does not
/// report selection changes. The PDF is fetched a second time, with the web
/// view's cookies; when that fails, WebKit's view stays as it was.
final class BrowserPDF: NSObject, PDFViewDelegate {
  private static var key: UInt8 = 0
  /// Page text given to the agent in one read, as for a web page.
  private static let textLimit = 24000

  private let viewer = PDFView()
  private let identifier: Int64
  private let channel: FlutterMethodChannel
  private var fetch: URLSessionDataTask?
  private var opened: FlutterResult?
  private weak var webView: WKWebView?
  /// The highlights made here. They last while the PDF stays open in the tab.
  private var marks: [PDFAnnotation] = []

  private init(identifier: Int64, channel: FlutterMethodChannel) {
    self.identifier = identifier
    self.channel = channel
  }

  /// The viewer over a tab's web view, once its PDF is showing.
  static func shown(on webView: WKWebView) -> BrowserPDF? {
    let pdf = objc_getAssociatedObject(webView, &key) as? BrowserPDF
    return pdf?.viewer.superview == nil ? nil : pdf
  }

  /// `open` answers the PDF's title and page count, or nil when the address
  /// gave no PDF. `close` removes the viewer. `text` answers the text from
  /// the page in view onward. `zoomIn`, `zoomOut`, `zoomFit` and `highlight`
  /// act on the viewer.
  static func perform(
    _ action: String, on webView: WKWebView, identifier: Int64, channel: FlutterMethodChannel,
    result: @escaping FlutterResult
  ) {
    let current = objc_getAssociatedObject(webView, &key) as? BrowserPDF
    switch action {
    case "open":
      current?.close()
      let pdf = BrowserPDF(identifier: identifier, channel: channel)
      objc_setAssociatedObject(webView, &key, pdf, .OBJC_ASSOCIATION_RETAIN)
      pdf.open(over: webView, result: result)
    case "close":
      current?.close()
      objc_setAssociatedObject(webView, &key, nil, .OBJC_ASSOCIATION_RETAIN)
      result(nil)
    case "text":
      result(shown(on: webView)?.text())
    default:
      shown(on: webView)?.act(action)
      result(nil)
    }
  }

  var selection: String? {
    guard let text = viewer.currentSelection?.string, !text.isEmpty else { return nil }
    // Counted as Dart counts it, which refuses a longer selection.
    return String(decoding: text.utf16.prefix(4000), as: UTF16.self)
  }

  /// A picture of the viewer as it shows, for captures and bug reports.
  func snapshot() -> Data? {
    guard let image = viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds) else { return nil }
    viewer.cacheDisplay(in: viewer.bounds, to: image)
    return image.representation(using: .png, properties: [:])
  }

  private func open(over webView: WKWebView, result: @escaping FlutterResult) {
    guard let url = webView.url, ["http", "https"].contains(url.scheme ?? "") else {
      result(nil)
      return
    }
    opened = result
    // WebKit keeps its cookies apart from URLSession's, so a signed-in PDF
    // needs them copied.
    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
      guard let pdf = self, pdf.opened != nil else { return }
      let configuration = URLSessionConfiguration.ephemeral
      for cookie in cookies { configuration.httpCookieStorage?.setCookie(cookie) }
      var request = URLRequest(url: url)
      if let agent = webView?.customUserAgent, !agent.isEmpty {
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
      }
      let session = URLSession(configuration: configuration)
      let task = session.dataTask(with: request) { [weak self, weak webView] data, _, _ in
        DispatchQueue.main.async {
          // A closed viewer has already answered.
          guard let pdf = self, let answer = pdf.opened else { return }
          pdf.opened = nil
          pdf.fetch = nil
          guard let webView = webView, webView.url == url, let data = data,
                let document = PDFDocument(data: data), document.pageCount > 0 else {
            answer(nil)
            return
          }
          pdf.show(document, over: webView)
          let attribute = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
          let named = attribute?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          let details: [String: Any] = [
            "title": named.isEmpty ? url.lastPathComponent : named, "pages": document.pageCount,
          ]
          answer(details)
        }
      }
      pdf.fetch = task
      task.resume()
      session.finishTasksAndInvalidate()
    }
  }

  private func close() {
    fetch?.cancel()
    fetch = nil
    opened?(nil)
    opened = nil
    NotificationCenter.default.removeObserver(self)
    NSObject.cancelPreviousPerformRequests(withTarget: self)
    viewer.removeFromSuperview()
  }

  // PDFKit would hand a clicked link to the Mac's default browser. The tab
  // loads it instead, through the Browser's address rule.
  func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
    webView?.load(URLRequest(url: url))
  }

  private func show(_ document: PDFDocument, over webView: WKWebView) {
    self.webView = webView
    viewer.delegate = self
    viewer.frame = webView.bounds
    viewer.autoresizingMask = [.width, .height]
    webView.addSubview(viewer)
    viewer.document = document
    viewer.displayMode = .singlePageContinuous
    viewer.autoScales = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: viewer)
  }

  // A drag changes the selection many times; Relay hears once it settles.
  @objc private func selectionChanged() {
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reportSelection), object: nil)
    self.perform(#selector(reportSelection), with: nil, afterDelay: 0.15)
  }

  @objc private func reportSelection() {
    let event: [String: Any] = ["view": NSNumber(value: identifier), "text": selection ?? ""]
    channel.invokeMethod("pdfSelection", arguments: event)
  }

  private func act(_ action: String) {
    switch action {
    case "zoomIn": viewer.zoomIn(nil)
    case "zoomOut": viewer.zoomOut(nil)
    case "zoomFit": viewer.autoScales = true
    case "highlight": toggleHighlight()
    #if DEBUG
      // The Mac check cannot drag over a native view; debug builds only.
      case "selectAll": viewer.selectAll(nil)
    #endif
    default: break
    }
  }

  private func text() -> [String: Any]? {
    guard let document = viewer.document else { return nil }
    let inView = viewer.currentPage.map { document.index(for: $0) } ?? 0
    let first = inView == NSNotFound ? 0 : inView
    var text = ""
    var index = first
    while index < document.pageCount, text.count < BrowserPDF.textLimit {
      text += (document.page(at: index)?.string ?? "") + "\n"
      index += 1
    }
    return [
      "text": String(text.prefix(BrowserPDF.textLimit)), "page": first + 1, "pages": document.pageCount,
    ]
  }

  /// Highlights the selected lines, or removes the highlights they lie on.
  private func toggleHighlight() {
    guard let selection = viewer.currentSelection else { return }
    var lines: [(page: PDFPage, bounds: NSRect)] = []
    for line in selection.selectionsByLine() {
      for page in line.pages {
        let bounds = line.bounds(for: page)
        if !bounds.isEmpty { lines.append((page, bounds)) }
      }
    }
    if lines.isEmpty { return }
    // Neighbouring lines' boxes touch, so only a real overlap counts.
    let covered = marks.filter { mark in
      lines.contains { line in
        let overlap = line.bounds.intersection(mark.bounds)
        return line.page === mark.page && overlap.width > 1
          && overlap.height > min(line.bounds.height, mark.bounds.height) / 2
      }
    }
    if covered.isEmpty {
      for line in lines {
        let mark = PDFAnnotation(bounds: line.bounds, forType: .highlight, withProperties: nil)
        mark.color = NSColor.systemYellow.withAlphaComponent(0.5)
        line.page.addAnnotation(mark)
        marks.append(mark)
      }
    } else {
      for mark in covered { mark.page?.removeAnnotation(mark) }
      marks.removeAll { mark in covered.contains { $0 === mark } }
    }
    viewer.clearSelection()
  }
}

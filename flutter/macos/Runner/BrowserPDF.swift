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
  /// The highlights shown, each with the marks drawn for its lines. Relay
  /// keeps them on its server and gives them back when the PDF opens.
  private var highlights: [String: [PDFAnnotation]] = [:]

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
  /// gave no PDF this viewer can show. `close` removes the viewer. `text`
  /// answers the text from the page in view onward. `zoomIn`, `zoomOut` and
  /// `zoomFit` act on the viewer. `highlight` marks the selection as the
  /// highlight `id`, or removes the highlights it lies on, and answers which.
  /// `marks` draws the kept highlights given.
  static func perform(
    _ arguments: [String: Any], on webView: WKWebView, identifier: Int64, channel: FlutterMethodChannel,
    result: @escaping FlutterResult
  ) {
    let current = objc_getAssociatedObject(webView, &key) as? BrowserPDF
    switch arguments["do"] as? String {
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
    case "highlight":
      result((arguments["id"] as? String).flatMap { shown(on: webView)?.toggleHighlight(as: $0) })
    case "marks":
      shown(on: webView)?.draw(arguments["highlights"] as? [[String: Any]] ?? [])
      result(nil)
    case "zoomIn":
      shown(on: webView)?.viewer.zoomIn(nil)
      result(nil)
    case "zoomOut":
      shown(on: webView)?.viewer.zoomOut(nil)
      result(nil)
    case "zoomFit":
      shown(on: webView)?.viewer.autoScales = true
      result(nil)
    #if DEBUG
      // The Mac check cannot drag over a native view; debug builds only.
      case "selectAll":
        shown(on: webView)?.viewer.selectAll(nil)
        result(nil)
    #endif
    default:
      result(nil)
    }
  }

  var selection: String? {
    guard let text = viewer.currentSelection?.string, !text.isEmpty else { return nil }
    // Counted as Dart counts it, which refuses a longer selection.
    return String(decoding: text.utf16.prefix(4000), as: UTF16.self)
  }

  /// A picture of the pages in view, with their highlights, for captures and
  /// bug reports. PDFKit draws its pages on layers that AppKit's view capture
  /// leaves blank, so each page in view is drawn again here.
  func snapshot() -> Data? {
    let bounds = viewer.bounds
    let scale = viewer.window?.backingScaleFactor ?? 2
    guard !bounds.isEmpty,
          let context = CGContext(
            data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(viewer.backgroundColor.cgColor)
    context.fill(CGRect(origin: .zero, size: bounds.size))
    let box = viewer.displayBox
    for page in viewer.visiblePages {
      let frame = viewer.convert(page.bounds(for: box), from: page)
      // A page turned on its side is drawn with its sides swapped.
      var size = page.bounds(for: box).size
      if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
      if frame.isEmpty || size.width <= 0 || size.height <= 0 { continue }
      context.saveGState()
      // The picture's origin is at the bottom left.
      context.translateBy(x: frame.minX, y: viewer.isFlipped ? bounds.height - frame.maxY : frame.minY)
      context.scaleBy(x: frame.width / size.width, y: frame.height / size.height)
      context.setFillColor(CGColor.white)
      context.fill(CGRect(origin: .zero, size: size))
      page.draw(with: box, to: context)
      context.restoreGState()
    }
    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
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
      let session = URLSession(configuration: configuration, delegate: SameAddress(), delegateQueue: nil)
      let task = session.dataTask(with: request) { [weak self, weak webView] data, response, _ in
        DispatchQueue.main.async {
          // A closed viewer has already answered.
          guard let pdf = self, let answer = pdf.opened else { return }
          pdf.opened = nil
          pdf.fetch = nil
          // A PDF that needs a password stays with WebKit, which asks for it.
          guard let webView = webView, webView.url == url, let data = data,
                let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
                let document = PDFDocument(data: data), document.pageCount > 0, !document.isLocked else {
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

  private func mark(_ bounds: NSRect, on page: PDFPage) -> PDFAnnotation {
    let mark = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
    mark.color = NSColor.systemYellow.withAlphaComponent(0.5)
    page.addAnnotation(mark)
    return mark
  }

  /// Draws kept highlights: each has an `id` and, for every line, a
  /// [page, x, y, width, height] in `marks`.
  private func draw(_ kept: [[String: Any]]) {
    guard let document = viewer.document else { return }
    for item in kept {
      guard let id = item["id"] as? String, highlights[id] == nil,
            let lines = item["marks"] as? [[NSNumber]] else { continue }
      var drawn: [PDFAnnotation] = []
      for line in lines where line.count == 5 {
        let index = line[0].intValue
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { continue }
        let bounds = NSRect(
          x: line[1].doubleValue, y: line[2].doubleValue, width: line[3].doubleValue,
          height: line[4].doubleValue)
        drawn.append(mark(bounds, on: page))
      }
      if !drawn.isEmpty { highlights[id] = drawn }
    }
  }

  /// Highlights the selected lines as `id` and answers `added` with their
  /// text and marks, or removes the highlights the selection lies on and
  /// answers `removed` with their ids.
  private func toggleHighlight(as id: String) -> [String: Any]? {
    guard let selection = viewer.currentSelection, let document = viewer.document else { return nil }
    var lines: [(page: PDFPage, bounds: NSRect)] = []
    for line in selection.selectionsByLine() {
      for page in line.pages {
        let bounds = line.bounds(for: page)
        if !bounds.isEmpty { lines.append((page, bounds)) }
      }
    }
    if lines.isEmpty { return nil }
    defer { viewer.clearSelection() }
    // Neighbouring lines' boxes touch, so only a real overlap counts.
    let covered = highlights.filter { _, drawn in
      drawn.contains { mark in
        lines.contains { line in
          let overlap = line.bounds.intersection(mark.bounds)
          return line.page === mark.page && overlap.width > 1
            && overlap.height > min(line.bounds.height, mark.bounds.height) / 2
        }
      }
    }.map { $0.key }
    if !covered.isEmpty {
      for key in covered {
        for mark in highlights.removeValue(forKey: key) ?? [] { mark.page?.removeAnnotation(mark) }
      }
      return ["removed": covered]
    }
    var drawn: [PDFAnnotation] = []
    var marks: [[Double]] = []
    for line in lines {
      drawn.append(mark(line.bounds, on: line.page))
      marks.append([
        Double(document.index(for: line.page)), Double(line.bounds.minX), Double(line.bounds.minY),
        Double(line.bounds.width), Double(line.bounds.height),
      ])
    }
    highlights[id] = drawn
    let quoted = String(decoding: (selection.string ?? "").utf16.prefix(4000), as: UTF16.self)
    let added: [String: Any] = ["text": quoted, "marks": marks]
    return ["added": added]
  }
}

/// The viewer's own fetch goes only to the address the tab shows. That address
/// passed the Browser's rule; a redirect could lead to one that would not, such
/// as a private address, so a redirected fetch is given up.
private final class SameAddress: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

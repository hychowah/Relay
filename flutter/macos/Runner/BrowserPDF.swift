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
  /// Highlight colours, kept in step with page_highlights.js,
  /// highlight_menu.dart and the server's highlightColors.
  private static let colors: [String: NSColor] = ([
    "yellow": (255, 214, 10), "green": (52, 199, 89), "blue": (10, 132, 255), "pink": (255, 55, 95),
    "purple": (175, 82, 222),
  ] as [String: (CGFloat, CGFloat, CGFloat)]).mapValues { NSColor(srgbRed: $0.0 / 255, green: $0.1 / 255, blue: $0.2 / 255, alpha: 0.45) }
  private static func color(_ name: Any?) -> NSColor { colors[name as? String ?? ""] ?? colors["yellow"]! }

  private let viewer = PDFView()
  private let identifier: Int64
  private let channel: FlutterMethodChannel
  private var fetch: URLSessionDataTask?
  private var opened: FlutterResult?
  private weak var webView: WKWebView?
  /// The highlights shown, each with the marks drawn for its lines. Relay
  /// keeps them on its server and gives them back when the PDF opens.
  private var highlights: [String: [PDFAnnotation]] = [:]
  /// Whether Relay shows its highlight menu for this viewer.
  private var menuShown = false
  /// Whether the menu hid for a scroll or zoom and may come back.
  private var returning = false
  /// The app's watch on mouse presses, while the viewer shows, and whether
  /// a press began on the viewer and has not been handled yet.
  private var monitor: Any?
  private var pressing = false

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
  /// highlight `id` in `color` and answers its text and marks. `recolor` and
  /// `remove` change the highlight `id`. `marks` draws the kept highlights.
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
      result((arguments["id"] as? String).flatMap { shown(on: webView)?.addHighlight(as: $0, in: arguments["color"]) })
    case "recolor":
      shown(on: webView)?.recolor(arguments["id"] as? String ?? "", to: arguments["color"])
      result(nil)
    case "remove":
      shown(on: webView)?.remove(arguments["id"] as? String ?? "")
      result(nil)
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
      // pdf_viewer_test selects without mouse input; debug builds only.
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
    // A VPN tab's PDF comes through the tab's proxy too.
    let proxies = webView.configuration.websiteDataStore.proxyConfigurations
    // WebKit keeps its cookies apart from URLSession's, so a signed-in PDF
    // needs them copied.
    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
      guard let pdf = self, pdf.opened != nil else { return }
      let configuration = URLSessionConfiguration.ephemeral
      for cookie in cookies { configuration.httpCookieStorage?.setCookie(cookie) }
      configuration.proxyConfigurations = proxies
      var request = URLRequest(url: url)
      if let agent = webView?.customUserAgent, !agent.isEmpty {
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
      }
      let fetched = PDFFetch { [weak self, weak webView] data in
        // A closed viewer has already answered.
        guard let pdf = self, let answer = pdf.opened else { return }
        pdf.opened = nil
        pdf.fetch = nil
        // A PDF that needs a password stays with WebKit, which asks for it.
        guard let webView = webView, webView.url == url, let data = data,
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
      let session = URLSession(configuration: configuration, delegate: fetched, delegateQueue: nil)
      let task = session.dataTask(with: request)
      pdf.fetch = task
      task.resume()
      session.finishTasksAndInvalidate()
    }
  }

  // A web view that goes before its close call arrives takes this with it.
  deinit {
    if let watching = monitor { NSEvent.removeMonitor(watching) }
  }

  private func close() {
    fetch?.cancel()
    fetch = nil
    opened?(nil)
    opened = nil
    NotificationCenter.default.removeObserver(self)
    if let watching = monitor { NSEvent.removeMonitor(watching) }
    monitor = nil
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
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
      self?.mouse(event)
      return event
    }
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: viewer)
    center.addObserver(self, selector: #selector(moved), name: .PDFViewScaleChanged, object: viewer)
    if let clip = viewer.documentView?.enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      center.addObserver(self, selector: #selector(moved), name: NSView.boundsDidChangeNotification, object: clip)
    }
  }

  /// Tells Relay where to show its highlight menu: by `rects`, in the
  /// viewer's points from its top left, and for the highlight `id` when
  /// one was clicked. Nothing in view hides it.
  private func showMenu(_ rects: [NSRect], id: String? = nil) {
    let visible = viewer.bounds
    var box = NSRect.null
    for rect in rects {
      let part = rect.intersection(visible)
      if !part.isEmpty { box = box.union(part) }
    }
    if box.isNull { return hideMenu() }
    let top = viewer.isFlipped ? box.minY - visible.minY : visible.maxY - box.maxY
    let rect = ["left": box.minX - visible.minX, "top": top, "right": box.maxX - visible.minX, "bottom": top + box.height]
    var menu: [String: Any] = ["rect": rect]
    if let id = id { menu["id"] = id }
    menuShown = true
    channel.invokeMethod("pdfMenu", arguments: ["view": NSNumber(value: identifier), "menu": menu])
  }

  private func hideMenu() {
    guard menuShown else { return }
    menuShown = false
    channel.invokeMethod("pdfMenu", arguments: ["view": NSNumber(value: identifier)])
  }

  /// Shows the menu by the selected text in view, if any. Only the pages in
  /// view are measured, and the text is not read: a whole long PDF can be
  /// selected.
  private func showSelectionMenu() -> Bool {
    guard let selection = viewer.currentSelection else { return false }
    let rects = viewer.visiblePages.map { viewer.convert(selection.bounds(for: $0), from: $0) }
      .filter { !$0.isEmpty }
    if rects.isEmpty { return false }
    showMenu(rects)
    return true
  }

  /// PDFKit's own page views take the viewer's mouse events, so presses are
  /// watched as the app receives them, and only those on the viewer itself,
  /// not on Relay's menu drawn over it. A press hides the menu. Once it
  /// ends, after PDFKit has handled it, the menu goes by the selected text
  /// or the highlight clicked. PDFKit may follow a drag in a loop of its
  /// own that keeps the release from this watch, so the end is also looked
  /// for once the press has been handled.
  private func mouse(_ event: NSEvent) {
    guard let window = viewer.window, event.window === window else { return }
    let point = viewer.convert(event.locationInWindow, from: nil)
    let at = NSValue(point: point)
    if event.type == .leftMouseDown {
      // A press elsewhere, such as on Relay's menu, ends any press here
      // whose release a tracking loop took.
      pressing = false
      guard let content = window.contentView, let frame = content.superview,
            content.hitTest(frame.convert(event.locationInWindow, from: nil))?.isDescendant(of: viewer) == true
      else { return }
      pressing = true
      returning = false
      hideMenu()
      // In the default run loop mode only, so not inside a tracking loop,
      // such as a scroller's, while the button is still down.
      perform(#selector(pressHandled(_:)), with: at, afterDelay: 0)
    } else if pressing {
      perform(#selector(ended(at:)), with: at, afterDelay: 0)
    }
  }

  @objc private func pressHandled(_ at: NSValue) {
    if NSEvent.pressedMouseButtons & 1 == 0 { ended(at: at) }
  }

  @objc private func ended(at value: NSValue) {
    guard pressing else { return }
    pressing = false
    released(at: value.pointValue)
  }

  // The mouse is up at `point`: the menu goes by the selected text, or by
  // the highlight clicked.
  private func released(at point: NSPoint) {
    if showSelectionMenu() { return }
    guard let page = viewer.page(for: point, nearest: false) else { return }
    let onPage = viewer.convert(point, to: page)
    guard let hit = highlights.first(where: { _, marks in
      marks.contains { $0.page === page && $0.bounds.contains(onPage) }
    }) else { return }
    showMenu(hit.value.compactMap { mark in mark.page.map { viewer.convert(mark.bounds, from: $0) } }, id: hit.key)
  }

  // The menu hides while the pages scroll or zoom, and comes back by
  // selected text once they stop.
  @objc private func moved() {
    guard menuShown || returning else { return }
    hideMenu()
    returning = true
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(stopped), object: nil)
    self.perform(#selector(stopped), with: nil, afterDelay: 0.25)
  }

  @objc private func stopped() {
    guard returning else { return }
    returning = false
    _ = showSelectionMenu()
  }

  // A drag changes the selection many times; Relay hears once it settles.
  @objc private func selectionChanged() {
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reportSelection), object: nil)
    self.perform(#selector(reportSelection), with: nil, afterDelay: 0.15)
  }

  @objc private func reportSelection() {
    let event: [String: Any] = ["view": NSNumber(value: identifier), "text": selection ?? ""]
    channel.invokeMethod("pdfSelection", arguments: event)
    // Text selected with the keyboard; a drag shows the menu once released.
    if NSEvent.pressedMouseButtons & 1 == 0 { _ = showSelectionMenu() }
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

  private func mark(_ bounds: NSRect, on page: PDFPage, in color: Any?) -> PDFAnnotation {
    let mark = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
    mark.color = BrowserPDF.color(color)
    page.addAnnotation(mark)
    return mark
  }

  /// Draws the kept highlights in place of those shown: each has an `id`, a
  /// `color` and, for every line, a [page, x, y, width, height] in `marks`.
  private func draw(_ kept: [[String: Any]]) {
    guard let document = viewer.document else { return }
    for id in Array(highlights.keys) { remove(id) }
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
        drawn.append(mark(bounds, on: page, in: item["color"]))
      }
      if !drawn.isEmpty { highlights[id] = drawn }
    }
  }

  /// Highlights the selected lines as `id` in `color` and answers `added`
  /// with their text and marks.
  private func addHighlight(as id: String, in color: Any?) -> [String: Any]? {
    guard let selection = viewer.currentSelection, let document = viewer.document else { return nil }
    var drawn: [PDFAnnotation] = []
    var marks: [[Double]] = []
    for line in selection.selectionsByLine() {
      for page in line.pages {
        let bounds = line.bounds(for: page)
        if bounds.isEmpty { continue }
        drawn.append(mark(bounds, on: page, in: color))
        marks.append([
          Double(document.index(for: page)), Double(bounds.minX), Double(bounds.minY), Double(bounds.width),
          Double(bounds.height),
        ])
      }
    }
    if drawn.isEmpty { return nil }
    menuShown = false
    viewer.clearSelection()
    highlights[id] = drawn
    let quoted = String(decoding: (selection.string ?? "").utf16.prefix(4000), as: UTF16.self)
    let added: [String: Any] = ["text": quoted, "marks": marks]
    return ["added": added]
  }

  private func recolor(_ id: String, to color: Any?) {
    menuShown = false
    for mark in highlights[id] ?? [] { mark.color = BrowserPDF.color(color) }
  }

  private func remove(_ id: String) {
    menuShown = false
    for mark in highlights.removeValue(forKey: id) ?? [] { mark.page?.removeAnnotation(mark) }
  }
}

/// The viewer's own fetch: it answers, on the main queue, the PDF's bytes or
/// nil. It goes only to the address the tab shows. That address passed the
/// Browser's rule; a redirect could lead to one that would not, such as a
/// private address, so a redirected fetch is given up. A page can also claim
/// to be a PDF when it is not, so the reply must say it is one and may not
/// outgrow what the app can hold.
private final class PDFFetch: NSObject, URLSessionDataDelegate {
  private static let largest = 256 * 1024 * 1024
  private let done: (Data?) -> Void
  private var received = Data()

  init(done: @escaping (Data?) -> Void) {
    self.done = done
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let wanted = (200..<300).contains(status) && response.mimeType?.lowercased() == "application/pdf"
      && response.expectedContentLength <= Int64(PDFFetch.largest)
    completionHandler(wanted ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    received.append(data)
    if received.count > PDFFetch.largest { dataTask.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let fetched = error == nil ? received : nil
    DispatchQueue.main.async { self.done(fetched) }
  }
}

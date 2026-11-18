import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationWillFinishLaunching(_ notification: Notification) {
    // The first prototype was sandboxed. Preserve its draft and device identity
    // when moving to the outside-App-Store build that can replace its own bundle.
    let identifier = Bundle.main.bundleIdentifier!
    let defaults = UserDefaults.standard
    if defaults.string(forKey: "flutter.device") == nil {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let previous = home.appendingPathComponent("Library/Containers/\(identifier)/Data/Library/Preferences/\(identifier).plist")
      if let saved = NSDictionary(contentsOf: previous) as? [String: Any] {
        for (key, value) in saved where key.hasPrefix("flutter.") { defaults.set(value, forKey: key) }
      }
    }
    super.applicationWillFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

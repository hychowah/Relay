// Desktop only. Browser tabs' downloads: where each file goes, and the notice
// that says so. Each platform's web view only passes its downloads here.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'browser_address.dart';
import 'windows_web_view.dart';

const _browserChannel = MethodChannel('app.relay/browser');
const _downloadsChannel = MethodChannel('app.relay/downloads');

/// Desktop only. Saves what Browser tabs download straight to the user's
/// Downloads folder, under a name no file there has yet ("report (1).pdf"
/// after "report.pdf"), and says so in a notice at the bottom of the window:
/// "Downloading `name`…" until it ends, then "Saved `name`" with Show, which
/// reveals the file in Finder or Explorer, or "Couldn't download `name`".
/// Nothing is saved over an existing file. A download belongs to the window,
/// not its tab: closing or unloading the tab does not stop it.
class BrowserDownloads {
  BrowserDownloads(this._messenger, {this._folder = getDownloadsDirectory}) {
    // The Mac window reports downloads from startup, whichever tab they
    // came from.
    if (Platform.isMacOS) _downloadsChannel.setMethodCallHandler(_call);
  }

  final GlobalKey<ScaffoldMessengerState> _messenger;
  final Future<Directory?> Function() _folder;
  // Paths given to downloads still running: a second download of the same
  // name gets the next free one even before the first file exists.
  final _running = <String>{};

  /// Makes [controller]'s Browser page save its downloads here. On macOS,
  /// call it after the page's navigation delegate is set: setting another
  /// one later replaces the download handling.
  Future<void> attach(WebViewController controller) async {
    if (Platform.isMacOS) {
      final webKit = controller.platform as WebKitWebViewController;
      await _browserChannel.invokeMethod<void>(
        'downloads',
        webKit.webViewIdentifier,
      );
    } else if (Platform.isWindows) {
      await saveWindowsDownloads(
        controller.platform,
        start: start,
        ended: ended,
      );
    }
  }

  /// The file to save a download of [url], which the site names
  /// [suggested], to: a new file in the Downloads folder, held for it until
  /// [ended]. Null, with the failure notice, when the Browser's address
  /// rule refuses [url] or there is no Downloads folder.
  Future<String?> start(
    String url,
    String suggested, {
    bool vpn = false,
  }) async {
    final name = _cleanName(suggested);
    final scheme = Uri.tryParse(url)?.scheme;
    // blob: and data: downloads come from the page itself, not the network.
    final allowed = scheme == 'blob' || scheme == 'data'
        ? true
        : ['http', 'https'].contains(scheme) &&
              await publicPageAllowed(url, vpn: vpn);
    final folder = allowed ? await _folder() : null;
    if (folder == null) {
      _notice(_failed(name));
      return null;
    }
    final path = _freePath(folder.path, name);
    _running.add(path);
    _notice(
      SnackBar(content: Text('Downloading ${_base(path)}…'), persist: true),
    );
    return path;
  }

  /// The download that [start] gave [path] has ended, [saved] or not.
  void ended(String path, {required bool saved}) {
    final held = _running.remove(path);
    assert(held, 'No download was started at $path.');
    final name = _base(path);
    _notice(
      saved
          ? SnackBar(
              content: Text('Saved $name'),
              persist: false,
              action: SnackBarAction(
                label: 'Show',
                onPressed: () => _show(path),
              ),
            )
          : _failed(name),
    );
  }

  Future<Object?> _call(MethodCall call) async {
    final arguments = call.arguments as Map;
    switch (call.method) {
      case 'start':
        return start(
          arguments['url'] as String,
          arguments['name'] as String,
          vpn: arguments['vpn'] == true,
        );
      case 'ended':
        ended(arguments['path'] as String, saved: arguments['saved'] == true);
    }
    return null;
  }

  SnackBar _failed(String name) =>
      SnackBar(content: Text("Couldn't download $name"));

  void _notice(SnackBar notice) {
    final messenger = _messenger.currentState;
    if (messenger == null) return;
    // Each notice replaces any shown or waiting, so a "Downloading" one that
    // stays until dismissed never sits in front of a later notice.
    messenger.clearSnackBars();
    messenger.showSnackBar(notice);
  }

  // The site names the file, so its name loses any folder and the
  // characters Windows or macOS do not allow in a file name.
  static String _cleanName(String suggested) {
    final last = suggested.split(RegExp(r'[/\\]')).last;
    final name = last.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '_').trim();
    return name.isEmpty || name == '.' || name == '..' ? 'download' : name;
  }

  String _freePath(String folder, String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    var path = '$folder${Platform.pathSeparator}$name';
    for (var n = 1; _running.contains(path) || File(path).existsSync(); n++) {
      path = '$folder${Platform.pathSeparator}$stem ($n)$extension';
    }
    return path;
  }

  static String _base(String path) => path.split(Platform.pathSeparator).last;

  static Future<void> _show(String path) => Platform.isWindows
      ? Process.run('explorer.exe', ['/select,$path'])
      : Process.run('open', ['-R', path]);
}

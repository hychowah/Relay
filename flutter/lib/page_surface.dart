import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'relay_api.dart';

class PageSpec {
  PageSpec({
    required this.id,
    required this.appId,
    required this.name,
    required this.sessionId,
    required this.relayOrigin,
    this.appView,
    this.report,
  });
  final String id, appId, name, sessionId;
  final Uri relayOrigin;
  final Json? appView;
  final Json? report;
  bool get browser => appId == WorkspaceApp.browserId;
  Uri get hostUri => relayOrigin
      .resolve('/flutter-host.html')
      .replace(
        queryParameters: {'view': id},
        // Encode the nested URL's percent escapes too; the host decodes this once.
        fragment: Uri.encodeComponent(
          jsonEncode({...appView!, 'protocolVersion': report == null ? 2 : 1}),
        ),
      );
}

typedef MessageContext = ({Json fields, Json? savedSource, bool anchorsView});

/// The workspace owns tab/context policy; this boundary owns native page lifetime.
abstract class PageSurface {
  Widget get widget;
  String get title;
  String get url;
  Json? get context;
  Future<void> get ready;
  BrowserSurface? get browser => null;
  Future<void> refreshSelection() async {}
  bool get canCapture => false;
  Future<Uint8List> snapshot() =>
      throw UnsupportedError('Page capture is unavailable.');

  /// Desktop only (macOS). A small picture of the page for its tab's hover
  /// card; null where there is none.
  Future<Uint8List?> preview() async => null;
  Future<Json> present(Json command);
  Future<Json> presentOnCurrentView(Json command) =>
      present({...command, 'expectedGeneration': context?['generation'] ?? 0});

  /// A [selection] chosen outside the page replaces the page's own.
  MessageContext? messageContext(
    String appId,
    String? token, {
    String? selection,
  }) {
    final surface = context;
    if (surface == null) return null;
    return (
      fields: {
        'appContext': {
          'appId': appId,
          'viewToken': token,
          'surface': {...surface, 'selection': ?selection},
        },
      },
      savedSource: null,
      anchorsView: true,
    );
  }

  void cancel(String commandId);
  void dispose();
}

const pdfZoomActions = ['zoomOut', 'zoomIn', 'zoomFit'];

mixin BrowserSurface {
  Future<Json> read();

  /// Whether the page plays sound now, which keeps a hidden tab loaded. On
  /// the Mac WebKit answers for the whole page; elsewhere only the audio and
  /// video elements in the page's own document are seen.
  Future<bool> playing() async => false;
  Future<Json> loadTranscript();

  /// The video's play time in seconds, or null when no video content plays.
  Future<double?> playbackTime();

  /// A [restoring] load reopens a saved tab; its page is not a new visit.
  Future<void> navigate(String text, {bool restoring = false});
  bool get canGoBack => false;
  bool get canGoForward => false;
  Future<void> browserAction(String action) async {}

  /// Whether the `highlight` action of [browserAction] works here: it marks
  /// the selected text in yellow. Relay's menu by the selection also
  /// recolours and removes.
  bool get canHighlight => false;

  /// Desktop only. Whether the tab shows a PDF in the Mac's own PDF viewer,
  /// which takes the [pdfZoomActions] through [browserAction].
  bool get pdf => false;

  /// Desktop only. Whether the page shows an element fullscreen, such as a
  /// video. The element fills the page's own view, so in a split pane it
  /// fills that pane.
  bool get fullScreen => false;

  /// Desktop only. Shows the page on the whole screen, or stops; stopping
  /// also ends the page's fullscreen.
  Future<void> fillScreen(bool on) async {}
}

typedef PageFactory = PageSurface Function(
  PageSpec spec,
  void Function(bool manual) changed,
);

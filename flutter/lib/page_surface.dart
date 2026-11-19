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

mixin BrowserSurface {
  Future<Json> read();
  Future<Json> loadTranscript();

  /// The video's play time in seconds, or null when no video content plays.
  Future<double?> playbackTime();
  Future<void> navigate(String text);
  bool get canGoBack => false;
  bool get canGoForward => false;
  Future<void> browserAction(String action) async {}

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

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/relay_api.dart';

class FakePage extends PageSurface with BrowserSurface {
  @override
  BrowserSurface? get browser => spec.browser ? this : null;
  FakePage(this.spec, this.changed);
  final PageSpec spec;
  final void Function(bool) changed;
  bool disposed = false;
  Json? lastCommand, result;
  Completer<Json>? pending;
  Completer<void>? loading;
  Uint8List? frame;
  final navigated = <String>[];
  @override
  Widget get widget => SizedBox.expand(
    key: ValueKey('page-${spec.id}'),
    child: Text('View ${spec.name}'),
  );
  @override
  String get title => spec.name;
  @override
  String url = 'https://example.com/desk';
  Json? transcript;
  StateError? transcriptError;
  int transcriptLoads = 0, timeReads = 0;
  double? time;
  String selection = 'selected passage';
  int generation = 5;
  @override
  Json get context => {
    'viewId': spec.browser ? 'browser' : 'room',
    'generation': generation,
    'selection': selection,
    'state': spec.browser
        ? {'sessionId': spec.sessionId, 'tabId': spec.id}
        : {'zone': 'work'},
  };
  @override
  Future<void> get ready => loading?.future ?? Future.value();
  @override
  bool get canCapture => frame != null;
  @override
  Future<Uint8List> snapshot() async => frame!;
  @override
  Future<Json> read() async => {'text': 'Desk: 150 by 80 cm', 'url': url};
  bool sound = false;
  @override
  Future<bool> playing() async => sound;
  @override
  Future<Json> loadTranscript() async {
    transcriptLoads++;
    if (transcriptError case final error?) throw error;
    return transcript!;
  }

  @override
  Future<double?> playbackTime() async {
    timeReads++;
    return time;
  }

  static Object? navigateError;
  @override
  Future<void> navigate(String text, {bool restoring = false}) async {
    if (navigateError != null) throw navigateError!;
    navigated.add(restoring ? 'restore $text' : text);
    changed(true);
  }

  @override
  bool pdf = false;
  @override
  bool canGoBack = false, canGoForward = false;
  @override
  bool get canHighlight => spec.browser;
  final actions = <String>[];
  @override
  Future<void> browserAction(String action) async => actions.add(action);

  @override
  bool fullScreen = false;
  final screenFills = <bool>[];
  @override
  Future<void> fillScreen(bool on) async {
    screenFills.add(on);
    if (!on) fullScreen = false;
  }

  @override
  Future<Json> present(Json command) async {
    lastCommand = command;
    return pending == null
        ? result ?? {'status': 'applied', 'context': context}
        : await pending!.future;
  }

  @override
  void cancel(String id) {}
  @override
  void dispose() {
    disposed = true;
  }
}

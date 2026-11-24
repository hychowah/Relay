import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'relay_records.dart';

/// Development recording of user actions, server exchanges and errors, saved
/// on the server as a report: a bug, feature request or update request.
class BugRecorder extends ChangeNotifier {
  static const maxEvents = 2000, maxText = 4000;
  final events = <Json>[];
  final _lastReply = <String, String>{};
  DateTime? startedAt, endedAt;
  bool recording = false;
  int dropped = 0;

  void start() {
    events.clear();
    _lastReply.clear();
    dropped = 0;
    startedAt = DateTime.now().toUtc();
    endedAt = null;
    recording = true;
    notifyListeners();
  }

  void stop() {
    endedAt = DateTime.now().toUtc();
    recording = false;
    notifyListeners();
  }

  /// Continues a stopped recording, for example after its save failed.
  void resume() {
    recording = true;
    notifyListeners();
  }

  Json get report => {
    'startedAt': startedAt?.toIso8601String(),
    'endedAt': endedAt?.toIso8601String(),
    'droppedEvents': dropped,
    'events': List.of(events),
  };

  /// [at] is when an event noted elsewhere and sent later, such as in a web
  /// page, happened; the event goes in time order among the others.
  void add(String type, Json details, {DateTime? at}) {
    if (!recording) return;
    if (events.length >= maxEvents) {
      events.removeAt(0);
      dropped++;
    }
    final time = (at ?? DateTime.now()).toUtc();
    var index = events.length;
    while (index > 0 &&
        time.isBefore(DateTime.parse(events[index - 1]['at'] as String))) {
      index--;
    }
    events.insert(index, {
      'at': time.toIso8601String(),
      'type': type,
      ..._trim(details) as Json,
    });
  }

  void action(String name, [Json details = const {}]) =>
      add('action', {'name': name, ...details});

  void exchange(
    String method,
    String path,
    String? body, {
    int? status,
    String? reply,
    Object? failure,
    required Duration elapsed,
  }) {
    if (!recording) return;
    // The workspace polls every second; a reply that has not changed is
    // noted without its body, so its time still shows (each poll redraws
    // the window, which a page trace may need to line up with).
    final unchanged =
        method == 'GET' && reply != null && _lastReply[path] == reply;
    if (method == 'GET' && reply != null) _lastReply[path] = reply;
    add('request', {
      'method': method,
      'path': path,
      'body': ?_decode(body),
      'status': ?status,
      if (unchanged) 'unchanged': true else 'reply': ?_decode(reply),
      'failure': ?failure?.toString(),
      'ms': elapsed.inMilliseconds,
    });
  }

  static Object? _decode(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  // Long values such as image data would bury the useful events.
  static Object? _trim(Object? value) => switch (value) {
    String text when text.length > maxText =>
      '${text.substring(0, maxText)}… (${text.length} characters)',
    Map map => map.map((key, item) => MapEntry(key.toString(), _trim(item))),
    List list => list.map(_trim).toList(),
    _ => value,
  };
}

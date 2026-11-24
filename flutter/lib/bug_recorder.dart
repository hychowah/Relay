import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'relay_records.dart';

/// Development recording of user actions, server exchanges and errors, saved
/// on the server as a report: a bug or a request.
class BugRecorder extends ChangeNotifier {
  static const maxEvents = 2000, maxText = 4000;

  /// The most notes web pages may hold in one recording, so that a page
  /// cannot push Relay's own events out. Past it the oldest page note goes,
  /// counted in [dropped]: the newest tell most about the bug being shown.
  static const maxPageNotes = 1000;
  int _pageNotes = 0;

  /// Notes that are not ones the page trace sends, counted apart from the
  /// events let go in [dropped].
  int refusedPageNotes = 0;
  final events = <Json>[];
  final _lastReply = <String, String>{};
  DateTime? startedAt, endedAt;
  bool recording = false;
  int dropped = 0;

  void start() {
    events.clear();
    _lastReply.clear();
    dropped = 0;
    _pageNotes = 0;
    refusedPageNotes = 0;
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
    if (refusedPageNotes > 0) 'refusedPageNotes': refusedPageNotes,
    'events': List.of(events),
  };

  /// Adds a note that a web page sent about itself a moment after it
  /// happened, at [atMs] on the page's clock. Any script in the page can
  /// send these, so the time is kept within the recording's last two
  /// seconds, which also keeps each insert near the end of the list.
  void pageNote(Json details, int atMs) {
    if (!recording) return;
    if (_pageNotes >= maxPageNotes) {
      events.removeAt(events.indexWhere((event) => event['type'] == 'page'));
      _pageNotes--;
      dropped++;
    }
    _pageNotes++;
    final now = DateTime.now().microsecondsSinceEpoch;
    final earliest = max(startedAt!.microsecondsSinceEpoch, now - 2000000);
    add(
      'page',
      details,
      at: DateTime.fromMicrosecondsSinceEpoch(
        (atMs * 1000).clamp(earliest, now),
        isUtc: true,
      ),
    );
  }

  /// [at] places an event that happened earlier in time order.
  void add(String type, Json details, {DateTime? at}) {
    if (!recording) return;
    if (events.length >= maxEvents) {
      if (events.removeAt(0)['type'] == 'page') _pageNotes--;
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
    // The workspace polls every second; keep only replies that changed.
    if (method == 'GET' && reply != null) {
      if (_lastReply[path] == reply) return;
      _lastReply[path] = reply;
    }
    add('request', {
      'method': method,
      'path': path,
      'body': ?_decode(body),
      'status': ?status,
      'reply': ?_decode(reply),
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

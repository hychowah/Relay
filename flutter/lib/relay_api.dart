import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'bug_recorder.dart';
import 'relay_records.dart';

export 'bug_recorder.dart';
export 'relay_records.dart';

class RelayApiException implements Exception {
  RelayApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

class RelayApi {
  RelayApi(this.origin, {http.Client? client})
    : _client = client ?? http.Client();
  final Uri origin;
  final http.Client _client;
  BugRecorder? recorder;
  Future<T> _request<T>(
    String path, [
    Json? body,
    String? method,
    bool private = false,
  ]) async {
    final recorder = private ? null : this.recorder;
    final url = origin.resolve(path);
    final request = http.Request(
      method ?? (body == null ? 'GET' : 'POST'),
      url,
    );
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final watch = Stopwatch()..start();
    final http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20));
    } catch (error) {
      recorder?.exchange(
        request.method,
        path,
        request.body,
        failure: error,
        elapsed: watch.elapsed,
      );
      rethrow;
    }
    recorder?.exchange(
      request.method,
      path,
      request.body,
      status: response.statusCode,
      reply: response.body,
      elapsed: watch.elapsed,
    );
    if (response.statusCode >= 400) {
      var message = response.body;
      try {
        final data = jsonDecode(message) as Json;
        message = (data['error'] ?? data['message'] ?? message).toString();
      } on FormatException {
        /* Non-JSON server errors remain readable. */
      }
      throw RelayApiException(response.statusCode, message);
    }
    return (response.statusCode == 204 ? null : jsonDecode(response.body)) as T;
  }

  Future<({List<WorkspaceApp> apps, Json provider})> config() async {
    final data = await _request<Json>('/api/config');
    return (
      apps: (data['apps'] as List)
          .cast<Json>()
          .map(WorkspaceApp.fromJson)
          .toList(),
      provider: (data['provider'] as Json?) ?? {},
    );
  }

  Future<List<Json>> bots() async =>
      (await _request<List>('/api/bots')).cast<Json>();
  Future<void> saveBot(String? id, Json body) =>
      _request(id == null ? '/api/bots' : '/api/bots/$id', body);

  Future<List<Json>> memories(String? botId) async => (await _request<List>(
    '/api/memories${botId == null ? '' : '?botId=$botId'}',
  )).cast<Json>();
  Future<void> saveMemory(String? id, Json body) =>
      _request(id == null ? '/api/memories' : '/api/memories/$id', body);
  Future<void> forgetMemory(String id) =>
      _request('/api/memories/$id', null, 'DELETE');

  Future<Json> providerSettings(String? mode) =>
      _request('/api/settings/provider${mode == null ? '' : '?mode=$mode'}');
  Future<List<Json>> providerModels(Json body) async {
    final result = await _request<Json>('/api/settings/provider/models', body);
    return (result['models'] as List).cast<Json>();
  }

  Future<void> saveProvider(Json body) =>
      _request('/api/settings/provider', body);

  Future<List<Json>> searchApp(String id, String query) async {
    final params = Uri(queryParameters: {'q': query});
    return (await _request<List>('/api/apps/$id/search?${params.query}'))
        .cast<Json>();
  }

  Future<Json> appView(String appId, String token, {Json? source}) {
    final params = Uri(
      queryParameters: {
        if (source != null) 'resourceId': source['resourceId'] as String,
        if (source != null) 'revision': source['revision'] as String,
        'token': token,
        'parentOrigin': origin.origin,
      },
    );
    return _request(
      '/api/apps/${Uri.encodeComponent(appId)}/view?${params.query}',
    );
  }

  Future<Json> readSource(Json source) {
    if (source['revision'] != null) return savedReport(source);
    final params = Uri(
      queryParameters: {'resourceId': source['resourceId'] as String},
    );
    return _request('/api/apps/${source['appId']}/read?${params.query}');
  }

  Future<Json> savedReport(Json source) {
    final params = Uri(
      queryParameters: {
        'resourceId': source['resourceId'] as String,
        'revision': source['revision'] as String,
      },
    );
    return _request('/api/apps/${source['appId']}/report?${params.query}');
  }

  Future<ConversationSnapshot> snapshot(String id) async =>
      ConversationSnapshot.fromJson(await _request('/api/conversations/$id'));

  Future<List<Conversation>> conversations({
    required String query,
    required bool trash,
  }) async {
    final params = Uri(queryParameters: {'q': query});
    final items = await _request<List>(
      trash ? '/api/trash' : '/api/conversations?${params.query}',
    );
    return items.cast<Json>().map(Conversation.fromJson).toList();
  }

  Future<String> createConversation(String? botId, String? effort) async =>
      (await _request<Json>('/api/conversations', {
            'botId': botId,
            'reasoningEffort': effort,
          }))['id']
          as String;
  Future<void> setEffort(String id, String? effort) =>
      _request('/api/conversations/$id/settings', {'reasoningEffort': effort});
  Future<String> forwardConversation(String id, Json body) async =>
      (await _request<Json>('/api/conversations/$id/forward', body))['id']
          as String;
  Future<void> trashConversation(String id) =>
      _request('/api/conversations/${Uri.encodeComponent(id)}', null, 'DELETE');
  Future<void> restoreConversation(String id) =>
      _request('/api/conversations/${Uri.encodeComponent(id)}/restore', {});

  Future<String> sendMessage(String id, Json body) async =>
      (await _request<Json>('/api/conversations/$id/messages', body))['id']
          as String;
  Uri captureUrl(String conversationId, String messageId) => origin.resolve(
    '/api/conversations/${Uri.encodeComponent(conversationId)}'
    '/messages/${Uri.encodeComponent(messageId)}/capture',
  );
  Future<void> cancelRun(String id) => _request('/api/runs/$id/cancel', {});
  Future<void> acknowledge(String id, Json body) =>
      _request('/api/commands/$id/ack', body);

  Future<Json> saveBugReport(Json report) =>
      _request('/api/bug-reports', report);
  Future<List<Json>> bugReports() async =>
      (await _request<List>('/api/bug-reports')).cast<Json>();
  Future<Json> bugReport(String id) =>
      _request('/api/bug-reports/${Uri.encodeComponent(id)}');
  Future<void> setBugReportStatus(String id, String status) => _request(
    '/api/bug-reports/${Uri.encodeComponent(id)}',
    {'status': status},
    'PATCH',
  );
  Future<void> deleteBugReport(String id) =>
      _request('/api/bug-reports/${Uri.encodeComponent(id)}', null, 'DELETE');
  Future<Uint8List> bugReportScreenshot(String id) async {
    final response = await _client
        .get(
          origin.resolve(
            '/api/bug-reports/${Uri.encodeComponent(id)}/screenshot',
          ),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode >= 400) {
      throw RelayApiException(response.statusCode, 'Screenshot unavailable.');
    }
    return response.bodyBytes;
  }

  // Per-keystroke history calls would flood bug recordings; recordings leave
  // them out. Recording never holds up or breaks browsing, so failures are
  // ignored.
  void browserVisit(String url, String? title) =>
      _quietly('visit', {'url': url, 'title': ?title});
  void browserTyped(String url) => _quietly('typed', {'url': url});
  void browserTitle(String url, String title) =>
      _quietly('title', {'url': url, 'title': title});
  void _quietly(String kind, Json body) =>
      _request<void>('/api/browser-history/$kind', body, 'POST', true).ignore();

  /// Saves this device's open tabs, so another device can open them. Like
  /// the browsing history it is left out of recordings.
  Future<void> saveDeviceTabs(String deviceId, String name, Json tabs) =>
      _request<void>(
        '/api/devices/${Uri.encodeComponent(deviceId)}',
        {'name': name, 'tabs': tabs},
        'PUT',
        true,
      );

  /// Every device's last saved tabs, most recently updated first.
  Future<List<Json>> devices() async =>
      (await _request<List>('/api/devices', null, null, true)).cast<Json>();

  /// The conversation last opened on any device, if it is not in Trash.
  Future<String?> currentConversation() async =>
      (await _request<Json>('/api/current-conversation'))['id'] as String?;

  Future<void> setCurrentConversation(String id) =>
      _request<void>('/api/current-conversation', {'id': id}, 'PUT');

  /// The visited pages that best match [text]; none when the request fails.
  Future<List<({String url, String title})>> browserSuggestions(
    String text,
  ) async {
    final params = Uri(queryParameters: {'q': text});
    try {
      final pages = await _request<List>(
        '/api/browser-history?${params.query}',
        null,
        null,
        true,
      );
      return [
        for (final page in pages.cast<Json>())
          (url: page['url'] as String, title: page['title'] as String),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// The highlights kept for a page address; none when the request fails.
  /// Like the history calls, these stay out of bug recordings.
  Future<List<Json>> highlights(String url) async {
    final params = Uri(queryParameters: {'url': url});
    try {
      final kept = await _request<List>(
        '/api/highlights?${params.query}',
        null,
        null,
        true,
      );
      return kept.cast<Json>();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveHighlight(String url, Json highlight) =>
      _request('/api/highlights', {...highlight, 'url': url}, 'POST', true);
  Future<void> forgetHighlight(String id) => _request(
    '/api/highlights/${Uri.encodeComponent(id)}',
    null,
    'DELETE',
    true,
  );

  /// Each kind of data the server keeps, with its size and how long it is
  /// kept (`autoCleanDays`, null for ever).
  Future<List<Json>> storedData() async =>
      (await _request<List>('/api/stored-data')).cast<Json>();

  /// Sets how long a kind is kept. A period that would delete items now is
  /// not saved without [deleteOlder]: the answer is then how many items, and
  /// otherwise 0.
  Future<int> setAutoClean(
    String id,
    int? days, {
    bool deleteOlder = false,
  }) async {
    final reply = await _request<Json>('/api/stored-data/$id', {
      'autoCleanDays': days,
      if (deleteOlder) 'deleteOlder': true,
    }, 'PUT');
    return reply['saved'] == true ? 0 : reply['older'] as int;
  }

  Future<void> clearStoredData(String id) =>
      _request('/api/stored-data/$id', null, 'DELETE');

  Future<void> checkIdleBeforeRestart(
    String deviceId,
    String windowId, {
    required bool allowOffline,
  }) async {
    final params = Uri(
      queryParameters: {'deviceId': deviceId, 'tabId': windowId},
    );
    try {
      final activity = await _request<Json>(
        '/api/desktop/busy?${params.query}',
      );
      if (activity['busy'] == true) {
        throw StateError(
          'A response is still running. Wait for it before restarting.',
        );
      }
    } on SocketException {
      // A stopped test backend must not strand its client on a preview.
      if (!allowOffline) rethrow;
    }
  }

  Future<http.StreamedResponse> _releaseFile(String file) => _client.send(
    http.Request('GET', origin.resolve('/flutter-updates/$file'))
      ..followRedirects = false,
  );
  Future<http.Response> updateFeed(String file) async =>
      http.Response.fromStream(await _releaseFile(file))
          .timeout(const Duration(seconds: 20));
  Future<http.StreamedResponse> updateArchive(String file) =>
      _releaseFile(file).timeout(const Duration(seconds: 20));

  void close() => _client.close();
}

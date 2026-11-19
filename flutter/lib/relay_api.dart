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
  Future<T> _request<T>(String path, [Json? body, String? method]) async {
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

  Future<String> createConversation(String? botId) async =>
      (await _request<Json>('/api/conversations', {'botId': botId}))['id']
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
  Future<void> cancelRun(String id) => _request('/api/runs/$id/cancel', {});
  Future<void> acknowledge(String id, Json body) =>
      _request('/api/commands/$id/ack', body);

  Future<Json> saveBugReport(Json report) =>
      _request('/api/bug-reports', report);
  Future<List<Json>> bugReports() async =>
      (await _request<List>('/api/bug-reports')).cast<Json>();
  Future<Json> bugReport(String id) =>
      _request('/api/bug-reports/${Uri.encodeComponent(id)}');
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

/// Matches the existing Browser broker: only scoped page reads travel this socket.
class BrowserConnection {
  BrowserConnection(this.origin, this.sessionId, this.read, this.changed);
  final Uri origin;
  final String sessionId;
  final Future<Json> Function(String) read;
  final void Function(bool) changed;
  WebSocket? _socket;
  Timer? _retry;
  bool _closed = false;
  Future<void> connect() async {
    try {
      final url = origin
          .resolve('/desktop/connect')
          .replace(
            scheme: origin.scheme == 'https' ? 'wss' : 'ws',
            queryParameters: {'session': sessionId},
          );
      final socket = await WebSocket.connect(url.toString())
          .timeout(const Duration(seconds: 8));
      if (_closed) {
        await socket.close();
        return;
      }
      _socket = socket;
      changed(true);
      socket.listen(
        (raw) async {
          Json? request;
          try {
            request = jsonDecode(raw as String) as Json;
            if (request['type'] != 'read' ||
                request['id'] is! String ||
                request['tabId'] is! String) {
              return;
            }
            final data = await read(request['tabId'] as String);
            if (socket.readyState == WebSocket.open) {
              socket.add(jsonEncode({'id': request['id'], 'data': data}));
            }
          } catch (error) {
            if (socket.readyState == WebSocket.open) {
              socket.add(
                jsonEncode({'id': request?['id'], 'error': error.toString()}),
              );
            }
          }
        },
        onDone: _disconnected,
        onError: (Object _) {
          _disconnected();
        },
        cancelOnError: true,
      );
    } catch (_) {
      _disconnected();
    }
  }

  void _disconnected() {
    if (_closed) return;
    changed(false);
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), connect);
  }

  void close() {
    _closed = true;
    _retry?.cancel();
    unawaited(_socket?.close());
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'browser_transcript.dart';
import 'page_surface.dart';
import 'relay_api.dart';

/// The desktop Browser's link to Relay: only scoped page reads and video
/// transcript pages travel this socket.
class BrowserConnection {
  BrowserConnection(this.origin, this.sessionId, this.browser, this.changed);
  final Uri origin;
  final String sessionId;
  final BrowserSurface Function(String tabId) browser;
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
            if (!['read', 'transcript'].contains(request['type']) ||
                request['id'] is! String ||
                request['tabId'] is! String) {
              return;
            }
            final tab = browser(request['tabId'] as String);
            final data = request['type'] == 'read'
                ? await tab.read()
                : transcriptPage(
                    await tab.loadTranscript(),
                    (request['offset'] as num?)?.toInt() ?? 0,
                  );
            if (socket.readyState == WebSocket.open) {
              socket.add(jsonEncode({'id': request['id'], 'data': data}));
            }
          } catch (error) {
            if (socket.readyState == WebSocket.open) {
              socket.add(
                jsonEncode({
                  'id': request?['id'],
                  'error': error is StateError ? error.message : '$error',
                }),
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

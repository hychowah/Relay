import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'browser_transcript.dart';
import 'page_surface.dart';
import 'relay_api.dart';

const _requests = {'read', 'transcript', 'form', 'fill'};

/// The desktop Browser's link to Relay: only scoped page reads, video
/// transcript pages and form fills travel this socket.
class BrowserConnection {
  BrowserConnection(
    this.origin,
    this.sessionId,
    this.browser,
    this.shownBrowser,
    this.changed,
  );
  final Uri origin;
  final String sessionId;
  final Future<BrowserSurface> Function(String tabId) browser;

  /// Form reads and fills reach only a tab on screen.
  final Future<BrowserSurface> Function(String tabId) shownBrowser;
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
            if (!_requests.contains(request['type']) ||
                request['id'] is! String ||
                request['tabId'] is! String) {
              return;
            }
            final tabId = request['tabId'] as String;
            final tab = ['form', 'fill'].contains(request['type'])
                ? await shownBrowser(tabId)
                : await browser(tabId);
            final data = switch (request['type']) {
              'read' => await tab.read(),
              'form' => await tab.readForm(),
              'fill' => await tab.fillForm(
                request['token'] as String? ?? '',
                request['fields'] as List? ?? [],
              ),
              _ => transcriptPage(
                await tab.loadTranscript(),
                (request['offset'] as num?)?.toInt() ?? 0,
              ),
            };
            final reply = jsonEncode({'id': request['id'], 'data': data});
            // Relay's end takes 256 KB a message and closes the socket, and
            // every request waiting on it, for a larger one.
            if (socket.readyState == WebSocket.open) {
              socket.add(
                utf8.encode(reply).length < 250 * 1024
                    ? reply
                    : jsonEncode({
                        'id': request['id'],
                        'error': 'The answer was too large to send.',
                      }),
              );
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/browser_connection.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/relay_api.dart';

class FakeBrowser with BrowserSurface {
  @override
  Future<Json> read() async => {'text': 'Page text'};
  @override
  Future<Json> loadTranscript() async => {
    'url': 'u',
    'title': 'Video',
    'language': 'English',
    'text': '[0:01] First\n[0:40] Second',
  };
  @override
  Future<Json> readForm() async => {
    'fields': [
      {'id': 'f1', 'type': 'email'},
    ],
  };
  @override
  Future<Json> fillForm(List<Object?> fields) async => {
    'filled': fields.length,
    'submitted': false,
  };
  @override
  Future<double?> playbackTime() async => null;
  @override
  Future<void> navigate(String text, {bool restoring = false}) async {}
}

void main() {
  test('the Browser socket answers reads, transcripts and fills', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final peer = Completer<WebSocket>();
    server.listen(
      (request) async =>
          peer.complete(await WebSocketTransformer.upgrade(request)),
    );
    final connection = BrowserConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'session',
      (tabId) async => tabId == 'tab'
          ? FakeBrowser()
          : throw StateError('The requested browser tab is closed.'),
      (_) {},
    );
    addTearDown(connection.close);
    await connection.connect();
    final socket = await peer.future;
    final replies = StreamIterator(
      socket.map((raw) => jsonDecode(raw as String) as Map),
    );
    Future<Map> ask(Map request) async {
      socket.add(jsonEncode(request));
      await replies.moveNext();
      return replies.current;
    }

    expect(await ask({'type': 'read', 'id': '1', 'tabId': 'tab'}), {
      'id': '1',
      'data': {'text': 'Page text'},
    });
    final page = await ask({
      'type': 'transcript',
      'id': '2',
      'tabId': 'tab',
      'offset': 13,
    });
    expect(page['data'], {
      'url': 'u',
      'title': 'Video',
      'language': 'English',
      'offset': 13,
      'totalLength': 26,
      'text': '[0:40] Second',
    });
    expect((await ask({'type': 'form', 'id': '4', 'tabId': 'tab'}))['data'], {
      'fields': [
        {'id': 'f1', 'type': 'email'},
      ],
    });
    expect(
      (await ask({
        'type': 'fill',
        'id': '5',
        'tabId': 'tab',
        'fields': [
          {'id': 'f1', 'value': 'ada@example.com'},
        ],
      }))['data'],
      {'filled': 1, 'submitted': false},
    );
    expect(await ask({'type': 'transcript', 'id': '3', 'tabId': 'gone'}), {
      'id': '3',
      'error': 'The requested browser tab is closed.',
    });
  });
}

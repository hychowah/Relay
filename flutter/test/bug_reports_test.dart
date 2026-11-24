import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/bug_reports.dart';
import 'package:relay_flutter/relay_api.dart';

// A one-pixel PNG.
const pixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

void main() {
  testWidgets('a request the backend never answers fails plainly', (
    tester,
  ) async {
    final api = RelayApi(
      Uri.parse('http://localhost:3250'),
      client: MockClient((_) => Completer<http.Response>().future),
    );
    Object? failure;
    unawaited(
      api.conversationText('c').then<void>((_) {}, onError: (e) => failure = e),
    );
    await tester.pump(const Duration(seconds: 21));
    expect(failure.toString(), 'Relay did not answer in 20 seconds.');
  });

  testWidgets('lists saved bug reports and opens their event timeline', (
    tester,
  ) async {
    const id = '2026-11-19T01-00-00-000Z-1a2b3c4d';
    // Room for the screenshot above the events.
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = RelayApi(
      Uri.parse('http://localhost:3250'),
      client: MockClient((request) async {
        final reply = switch (request.url.path) {
          '/api/bug-reports' => [
            {
              'id': id,
              'savedAt': '2026-11-19T01:00:00.000Z',
              'description': 'Stop did nothing',
              'events': 3,
              'screenshot': true,
            },
          ],
          '/api/bug-reports/$id' => {
            'id': id,
            'description': 'Stop did nothing',
            'startedAt': '2026-11-19T00:59:50.000Z',
            'endedAt': '2026-11-19T01:00:00.000Z',
            'client': {
              'provider': {'mode': 'fixture', 'model': 'Scripted'},
            },
            'events': [
              {
                'at': '2026-11-19T00:59:51.000Z',
                'type': 'action',
                'name': 'stop reply',
              },
              {
                'at': '2026-11-19T00:59:51.500Z',
                'type': 'request',
                'method': 'POST',
                'path': '/api/runs/run/cancel',
                'status': 409,
                'ms': 12,
              },
              {
                'at': '2026-11-19T00:59:52.000Z',
                'type': 'error',
                'message': 'Run already finished',
              },
            ],
          },
          _ => null,
        };
        if (request.url.path == '/api/bug-reports/$id/screenshot') {
          return http.Response.bytes(base64Decode(pixel), 200);
        }
        return reply == null
            ? http.Response('Not found', 404)
            : http.Response(jsonEncode(reply), 200);
      }),
    );
    await tester.pumpWidget(MaterialApp(home: BugReportsDialog(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('Stop did nothing'), findsOneWidget);

    await tester.tap(find.text('Stop did nothing'));
    await tester.pumpAndSettle();
    expect(find.textContaining('bug-reports/$id.json'), findsOneWidget);
    expect(find.text('Events (3)'), findsOneWidget);
    expect(find.text('stop reply'), findsOneWidget);
    expect(
      find.text('POST /api/runs/run/cancel → 409 (12 ms)'),
      findsOneWidget,
    );
    expect(find.text('+2.0s'), findsOneWidget);

    await tester.tap(find.text('Run already finished'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"type": "error"'), findsOneWidget);

    // The picture has a size once the engine has decoded it.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Open the screenshot full size'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Close').last);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);

    await tester.tap(find.byTooltip('All bug reports'));
    await tester.pumpAndSettle();
    expect(find.text('Bug reports'), findsOneWidget);
  });

  testWidgets('marks a bug report solved and deletes another', (tester) async {
    final saved = {
      for (final id in ['a', 'b'])
        id: <String, Object?>{
          'id': id,
          'savedAt': '2026-11-19T01:00:00.000Z',
          'description': 'Bug $id',
          'status': 'open',
          'events': 0,
          'screenshot': false,
        },
    };
    final api = RelayApi(
      Uri.parse('http://localhost:3250'),
      client: MockClient((request) async {
        if (request.url.path == '/api/bug-reports') {
          return http.Response(jsonEncode(saved.values.toList()), 200);
        }
        final id = request.url.pathSegments.last;
        if (request.method == 'PATCH') {
          saved[id]!['status'] = (jsonDecode(request.body) as Map)['status'];
          return http.Response(jsonEncode(saved[id]), 200);
        }
        saved.remove(id);
        return http.Response('', 204);
      }),
    );
    await tester.pumpWidget(MaterialApp(home: BugReportsDialog(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('2 open · 0 solved'), findsOneWidget);

    await tester.tap(find.byTooltip('Mark solved').first);
    await tester.pumpAndSettle();
    expect(saved['a']!['status'], 'solved');
    expect(find.text('1 open · 1 solved'), findsOneWidget);
    expect(find.byTooltip('Mark open'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete bug report').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(saved.keys, ['a']);
    expect(find.text('Bug b'), findsNothing);
    expect(find.text('0 open · 1 solved'), findsOneWidget);
  });
}

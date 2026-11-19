import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/bug_reports.dart';
import 'package:relay_flutter/relay_api.dart';

void main() {
  testWidgets('lists saved bug reports and opens their event timeline', (
    tester,
  ) async {
    const id = '2026-11-19T01-00-00-000Z-1a2b3c4d';
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
              'screenshot': false,
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

    await tester.tap(find.byTooltip('All bug reports'));
    await tester.pumpAndSettle();
    expect(find.text('Bug reports'), findsOneWidget);
  });
}

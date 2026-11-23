import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/stored_data.dart';

void main() {
  test('sizes read as people write them', () {
    expect(dataSize(0), '0 B');
    expect(dataSize(812), '812 B');
    expect(dataSize(3400), '3.4 KB');
    expect(dataSize(12300000), '12 MB');
    expect(dataSize(2500000000), '2.5 GB');
  });

  testWidgets('stored data shows each kind, clears it and sets auto-clean', (
    tester,
  ) async {
    // A stand-in server that keeps what the screen changes. Its highlights
    // are 100 days old, so a shorter period would delete them.
    final kinds = <Map<String, Object?>>[
      {
        'id': 'browser-history',
        'name': 'Browsing history',
        'description': 'Pages visited in Browser tabs.',
        'items': 128,
        'bytes': 34200,
        'autoCleanDays': 90,
      },
      {
        'id': 'highlights',
        'name': 'Highlights',
        'description': 'Text you highlighted.',
        'items': 3,
        'bytes': 420,
        'autoCleanDays': null,
      },
    ];
    final calls = <String>[];
    final api = RelayApi(
      Uri.parse('http://localhost:3250'),
      client: MockClient((request) async {
        if (request.method == 'GET') return http.Response(jsonEncode(kinds), 200);
        calls.add('${request.method} ${request.url.path} ${request.body}'.trim());
        final kind = kinds.firstWhere(
          (kind) => request.url.path.endsWith('/${kind['id']}'),
        );
        if (request.method == 'DELETE') {
          kind['items'] = 0;
          kind['bytes'] = 0;
          return http.Response('', 204);
        }
        final body = jsonDecode(request.body) as Map;
        final days = body['autoCleanDays'] as int?;
        if (days != null && days > 3650) {
          return http.Response('{"error":"Choose 1 to 3650 days."}', 400);
        }
        final older = kind['id'] == 'highlights' && days != null && days < 100
            ? kind['items'] as int
            : 0;
        if (older > 0 && body['deleteOlder'] != true) {
          return http.Response('{"saved":false,"older":$older}', 200);
        }
        if (older > 0) {
          kind['items'] = 0;
          kind['bytes'] = 0;
        }
        kind['autoCleanDays'] = days;
        return http.Response('{"saved":true,"older":$older}', 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: StoredDataDialog(api: api))),
    );
    await tester.pumpAndSettle();
    expect(find.text('128 items · 34 KB'), findsOneWidget);
    expect(find.text('3 items · 420 B'), findsOneWidget);
    expect(find.text('Auto-clean items older than'), findsOneWidget);
    expect(find.text('Auto-clean is off: kept until you clear it'), findsOne);
    expect(find.text('Save'), findsNothing);

    // A new number of days is saved with Save or Enter, not as it is typed.
    await tester.enterText(find.byType(TextField), '120');
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(calls, ['PUT /api/stored-data/browser-history {"autoCleanDays":120}']);

    // Turning auto-clean on sends nothing: it shows the period to save. A
    // period that would delete items now says how many and needs a second
    // click, and a double-click on Save is not that click.
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(find.text('Auto-clean items older than'), findsNWidgets(2));
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump();
    expect(calls.last, 'PUT /api/stored-data/highlights {"autoCleanDays":30}');
    await tester.tap(find.text('Delete 3 older items'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, hasLength(2));
    expect(find.text('3 items · 420 B'), findsOneWidget);

    // Typing another period takes the question back.
    await tester.enterText(find.byType(TextField).last, '200');
    await tester.pumpAndSettle();
    expect(find.text('Delete 3 older items'), findsNothing);
    await tester.enterText(find.byType(TextField).last, '30');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Delete 3 older items'));
    await tester.pumpAndSettle();
    expect(
      calls.last,
      'PUT /api/stored-data/highlights {"autoCleanDays":30,"deleteOlder":true}',
    );
    expect(find.text('0 items · 0 B'), findsOneWidget);

    // Turning it off keeps everything, so it is saved at once.
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(calls.last, 'PUT /api/stored-data/browser-history {"autoCleanDays":null}');

    // The server's refusal is shown and the saved period comes back.
    await tester.enterText(find.byType(TextField), '9999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Choose 1 to 3650 days.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '30');

    // Clearing asks for a second click, then shows the kind empty.
    await tester.tap(find.byTooltip('Clear browsing history'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(calls.last, 'DELETE /api/stored-data/browser-history');
    expect(find.text('0 items · 0 B'), findsNWidgets(2));
  });
}

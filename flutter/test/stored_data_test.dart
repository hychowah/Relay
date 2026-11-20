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
    // A stand-in server that keeps what the screen changes.
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
        'items': 1,
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
        } else {
          final days = (jsonDecode(request.body) as Map)['autoCleanDays'];
          if (days is int && days > 3650) {
            return http.Response('{"error":"Choose 1 to 3650 days."}', 400);
          }
          kind['autoCleanDays'] = days;
        }
        return http.Response('', 204);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: StoredDataDialog(api: api))),
    );
    await tester.pumpAndSettle();
    expect(find.text('128 items · 34 KB'), findsOneWidget);
    expect(find.text('1 item · 420 B'), findsOneWidget);
    expect(find.text('Auto-clean items older than'), findsOneWidget);
    expect(find.text('Auto-clean is off: kept until you clear it'), findsOne);

    // A new number of days is saved once typed.
    await tester.enterText(find.byType(TextField), '14');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(calls.last, 'PUT /api/stored-data/browser-history {"autoCleanDays":14}');

    // Turned on, auto-clean starts at a month; turned off, it keeps all.
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    expect(calls.last, 'PUT /api/stored-data/highlights {"autoCleanDays":30}');
    expect(find.text('Auto-clean items older than'), findsNWidgets(2));
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(calls.last, 'PUT /api/stored-data/browser-history {"autoCleanDays":null}');

    // The server's refusal is shown and the saved period stays.
    await tester.enterText(find.byType(TextField), '9999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Choose 1 to 3650 days.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '30');

    // Clearing asks for a second click, then shows the kind empty.
    await tester.tap(find.byTooltip('Clear highlights'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(calls.last, 'DELETE /api/stored-data/highlights');
    expect(find.text('0 items · 0 B'), findsOneWidget);
  });
}

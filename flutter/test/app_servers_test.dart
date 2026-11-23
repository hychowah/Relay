import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/app_servers.dart';
import 'package:relay_flutter/relay_api.dart';

/// A Relay service with two servers: a stopped one whose start can be made
/// to fail, and a running one that cannot start with the computer. [calls]
/// lists the changes and log reads, [listReads] counts list reads, and
/// [fileError] makes the list fail.
({
  RelayApi api,
  List<String> calls,
  int Function() listReads,
  void Function(String?) failStart,
})
fakeServers({String? fileError}) {
  final servers = <String, Json>{
    'ticker': {
      'id': 'ticker',
      'name': 'Ticker',
      'state': 'stopped',
      'autoStart': false,
    },
    'site': {
      'id': 'site',
      'name': 'Site',
      'state': 'running',
      'autoStart': null,
      'autoStartNote': 'Its service has no [Install] section.',
    },
  };
  final calls = <String>[];
  String? failure;
  var listReads = 0;
  final api = RelayApi(
    Uri.parse('http://localhost:3250'),
    client: MockClient((request) async {
      final path = request.url.pathSegments;
      if (request.method != 'GET' || path.last == 'logs') {
        calls.add('${request.method} ${request.url.path}');
      }
      if (path.length == 2) listReads++;
      if (path.length == 2 && fileError != null) {
        return http.Response(jsonEncode({'error': fileError}), 500);
      }
      if (path.length == 2) {
        return http.Response(jsonEncode(servers.values.toList()), 200);
      }
      final server = servers[path[2]]!;
      switch (path[3]) {
        case 'logs':
          return http.Response(jsonEncode({'text': 'tick\ntick\n'}), 200);
        case 'auto-start':
          server['autoStart'] = (jsonDecode(request.body) as Json)['on'];
          return http.Response(jsonEncode(server), 200);
        case 'start' when failure != null:
          server['state'] = 'failed';
          server['detail'] = 'It exited with status 1.';
          return http.Response(
            jsonEncode({'error': failure, 'server': server}),
            502,
          );
        case final action:
          server['state'] = action == 'stop' ? 'stopped' : 'running';
          return http.Response(jsonEncode({'server': server}), 200);
      }
    }),
  );
  return (
    api: api,
    calls: calls,
    listReads: () => listReads,
    failStart: (message) => failure = message,
  );
}

void main() {
  testWidgets('lists servers, starts and stops one, and turns auto-start on', (
    tester,
  ) async {
    final fake = fakeServers();
    await tester.pumpWidget(MaterialApp(home: AppServersDialog(api: fake.api)));
    await tester.pumpAndSettle();
    expect(find.text('Ticker'), findsOneWidget);
    expect(find.text('Stopped'), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    final unavailable = tester.widget<Switch>(find.byType(Switch).last);
    expect(unavailable.onChanged, isNull);
    expect(find.text('Start with the computer: not available'), findsOneWidget);

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Running'), findsNWidgets(2));
    await tester.tap(find.text('Stop').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(fake.calls, [
      'POST /api/app-servers/ticker/start',
      'POST /api/app-servers/ticker/stop',
      'PUT /api/app-servers/ticker/auto-start',
    ]);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);

    // It keeps the list current while it is open.
    final reads = fake.listReads();
    await tester.pump(appServersRefresh);
    expect(fake.listReads(), reads + 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed start shows its reason and the failed state', (
    tester,
  ) async {
    final fake = fakeServers()..failStart('Ticker did not stay running.');
    await tester.pumpWidget(MaterialApp(home: AppServersDialog(api: fake.api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Ticker: Ticker did not stay running.'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('It exited with status 1.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows a server\'s logs and reads them again every 10 seconds', (
    tester,
  ) async {
    final fake = fakeServers();
    await tester.pumpWidget(MaterialApp(home: AppServersDialog(api: fake.api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logs').first);
    await tester.pumpAndSettle();
    expect(find.text('Logs: Ticker'), findsOneWidget);
    expect(find.text('tick\ntick\n'), findsOneWidget);
    const read = 'GET /api/app-servers/ticker/logs';
    expect(fake.calls, [read]);
    await tester.pump(appServersRefresh);
    expect(fake.calls, [read]);
    await tester.pump(appServerLogsRefresh - appServersRefresh);
    expect(fake.calls, [read, read]);
    await tester.tap(find.byTooltip('Refresh logs'));
    await tester.pumpAndSettle();
    expect(fake.calls, [read, read, read]);

    await tester.tap(find.byTooltip('All app servers'));
    await tester.pumpAndSettle();
    expect(find.text('App servers'), findsOneWidget);
    await tester.pump(appServerLogsRefresh);
    expect(fake.calls, [read, read, read]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an unusable servers file shows its reason', (tester) async {
    final fake = fakeServers(
      fileError: 'The servers file is not valid: server "x" needs a name.',
    );
    await tester.pumpWidget(MaterialApp(home: AppServersDialog(api: fake.api)));
    await tester.pumpAndSettle();
    expect(
      find.text('The servers file is not valid: server "x" needs a name.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
}

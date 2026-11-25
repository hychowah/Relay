import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/workspace.dart';

import 'fake_page.dart';

const apps = [
  {'id': 'browser', 'name': 'Browser', 'description': 'Web pages'},
  {
    'id': 'room-layout',
    'name': 'Room layout',
    'description': 'Furniture',
    'protocolVersion': 2,
  },
  {'id': 'research', 'name': 'Research', 'description': 'Reports'},
];
const deskReport = {
  'appId': 'research',
  'resourceId': 'desk',
  'revision': '1',
  'title': 'Desk report',
};

class Fixture {
  Fixture({Json? session, bool newestTabFirst = false, Duration? unloadAfter}) {
    w = Workspace(
      api: RelayApi(
        Uri.parse('http://localhost:3250'),
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/api/config') {
            if (offline) return http.Response('Offline', 503);
            return reply({'apps': configApps});
          }
          if (path == '/api/bots') return reply([]);
          if (path.endsWith('/report')) {
            return reply({'source': deskReport, 'sections': []});
          }
          if (path == '/api/app-servers') return reply([]);
          if (path.contains('/view') && appDown) {
            return http.Response(jsonEncode({'error': 'App is down.'}), 502);
          }
          if (path.contains('/view')) {
            return reply({
              'url': 'http://localhost:3252/_relay/view?token=x',
              'origin': 'http://localhost:3252',
              'native': true,
            });
          }
          if (path.endsWith('/ack')) {
            acks.add(jsonDecode(request.body) as Json);
            return reply({});
          }
          if (path.endsWith('/messages')) {
            if (failSend) return http.Response('Send failed', 500);
            sentTo = path;
            sent = jsonDecode(request.body) as Json;
            return reply({'id': 'run'});
          }
          if (path == '/api/conversations') {
            return reply({'id': 'conversation'});
          }
          if (path.startsWith('/api/browser-history')) {
            if (request.method != 'GET') {
              history.add('${request.method} $path ${request.body}'.trim());
              return http.Response('', 204);
            }
            final q = request.url.queryParameters['q']!;
            history.add('suggest $q');
            await holdHistory[q]?.future;
            final pages = historyPages;
            if (pages == null) return http.Response('Not found', 404);
            return reply([
              for (final page in pages)
                if ('${page['url']} ${page['title']}'.toLowerCase().contains(
                  q.toLowerCase(),
                ))
                  page,
            ]);
          }
          if (path == '/api/current-conversation') {
            if (request.method == 'GET') {
              // The answer is the value when asked, however late it comes.
              final value = current;
              await holdCurrent?.future;
              return reply({'id': value});
            }
            current = (jsonDecode(request.body) as Json)['id'] as String;
            return http.Response('', 204);
          }
          if (path == '/api/devices') return reply(devices);
          if (path == '/api/bug-reports') {
            if (offline) return http.Response('Offline', 503);
            bugReport = jsonDecode(request.body) as Json;
            return reply({'id': 'report', 'file': 'bug-reports/report.json'});
          }
          final state = {
            'messages': messages,
            'runs': List.of(runs),
            'tools': [],
            'commands': commands,
          };
          if (failSnapshot) return http.Response('Snapshot failed', 500);
          await holdSnapshot?.future;
          return reply(state);
        }),
      ),
      deviceId: 'device',
      pendingSession: session,
      storeSession: (session) async => stored.add(session),
      pages: (spec, changed) {
        final page = FakePage(spec, changed);
        if (failRoomRestore && spec.appId == 'room-layout') {
          page.result = {'status': 'failed', 'error': 'Unavailable'};
        }
        page.loading = holdPages;
        pages.add(page);
        return page;
      },
      saveConversation: (_) async {},
      newestTabFirst: newestTabFirst,
      saveNewestTabFirst: (value) async => savedNewestFirst.add(value),
      unloadAfter: unloadAfter,
    );
  }
  final savedNewestFirst = <bool>[];
  // The server's conversation last opened on any device, and each device's
  // saved tabs as the server lists them.
  String? current, sentTo;
  Completer<void>? holdCurrent;
  List<Json> devices = [];
  bool offline = false, failRoomRestore = false, appDown = false;
  bool failSnapshot = false, failSend = false;
  List<Json> configApps = [...apps];
  late Workspace w;
  final pages = <FakePage>[];
  final acks = <Json>[];
  final stored = <Json>[];
  List<Json> commands = [], messages = [], runs = [];
  Completer<void>? holdSnapshot, holdPages;
  Json? sent, bugReport;
  // The server's browsing history: its calls, and pages already ranked;
  // null pages stand for an older backend without history.
  final history = <String>[];
  final holdHistory = <String, Completer<void>>{};
  List<Json>? historyPages;
  http.Response reply(Object data) => http.Response(jsonEncode(data), 200);
  Json command(String id, String target, {String? token}) => {
    'id': id,
    'runId': 'run',
    'kind': 'present',
    'status': 'pending',
    'deviceId': w.deviceId,
    'tabId': w.windowId,
    'appId': target,
    'expectedViewToken': token ?? w.active?.token,
    'expectedGeneration': 0,
    'intent': {
      'viewId': target == 'browser' ? 'browser' : 'room',
      'targetIds': ['desk'],
    },
  };
}

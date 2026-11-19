import 'dart:async';
import 'dart:convert';
import 'dart:math' show max;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/transcript_pane.dart';
import 'package:relay_flutter/workspace.dart';
import 'package:relay_flutter/capture_flight.dart';
import 'package:relay_flutter/region_capture.dart';
import 'package:relay_flutter/workspace_tabs.dart';

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

class FakePage extends PageSurface with BrowserSurface {
  @override
  BrowserSurface? get browser => spec.browser ? this : null;
  FakePage(this.spec, this.changed);
  final PageSpec spec;
  final void Function(bool) changed;
  bool disposed = false;
  Json? lastCommand, result;
  Completer<Json>? pending;
  Completer<void>? loading;
  Uint8List? frame;
  @override
  Widget get widget => SizedBox.expand(
    key: ValueKey('page-${spec.id}'),
    child: Text('View ${spec.name}'),
  );
  @override
  String get title => spec.name;
  @override
  String url = 'https://example.com/desk';
  Json? transcript;
  StateError? transcriptError;
  int transcriptLoads = 0, timeReads = 0;
  double? time;
  String selection = 'selected passage';
  @override
  Json get context => {
    'viewId': spec.browser ? 'browser' : 'room',
    'generation': 5,
    'selection': selection,
    'state': spec.browser
        ? {'sessionId': spec.sessionId, 'tabId': spec.id}
        : {'zone': 'work'},
  };
  @override
  Future<void> get ready => loading?.future ?? Future.value();
  @override
  bool get canCapture => frame != null;
  @override
  Future<Uint8List> snapshot() async => frame!;
  @override
  Future<Json> read() async => {'text': 'Desk: 150 by 80 cm', 'url': url};
  @override
  Future<Json> loadTranscript() async {
    transcriptLoads++;
    if (transcriptError case final error?) throw error;
    return transcript!;
  }

  @override
  Future<double?> playbackTime() async {
    timeReads++;
    return time;
  }

  @override
  Future<void> navigate(String text) async {
    changed(true);
  }

  @override
  Future<Json> present(Json command) async {
    lastCommand = command;
    return pending == null
        ? result ?? {'status': 'applied', 'context': context}
        : await pending!.future;
  }

  @override
  void cancel(String id) {}
  @override
  void dispose() {
    disposed = true;
  }
}

class Fixture {
  Fixture({Json? session}) {
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
          if (path.endsWith('/report')) return reply({'source': deskReport});
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
            sent = jsonDecode(request.body) as Json;
            return reply({'id': 'run'});
          }
          if (path == '/api/conversations') {
            return reply({'id': 'conversation'});
          }
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
    );
  }
  bool offline = false, failRoomRestore = false;
  List<Json> configApps = [...apps];
  late Workspace w;
  final pages = <FakePage>[];
  final acks = <Json>[];
  final stored = <Json>[];
  List<Json> commands = [], messages = [], runs = [];
  Completer<void>? holdSnapshot, holdPages;
  Json? sent, bugReport;
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

void main() {
  test(
    'saved tabs survive an offline start and reconnect retries a failed tab',
    () async {
      List<Object?> storedApps(Fixture f) => [
        for (final tab in f.stored.last['tabs'] as List) tab['appId'],
      ];
      final saved = <String, dynamic>{
        'active': 1,
        'tabs': [
          {
            'appId': 'browser',
            'url': 'about:blank',
            'context': {
              'viewId': 'browser',
              'state': {'url': 'about:blank'},
            },
          },
          {
            'appId': 'room-layout',
            'context': {
              'viewId': 'room',
              'state': {'zone': 'work'},
            },
          },
        ],
      };
      final f = Fixture(session: saved);
      addTearDown(f.w.dispose);
      f.offline = true;
      await f.w.start();
      f.w.newTab();
      f.w.closeTab(f.w.active!);
      expect(f.stored, isEmpty);
      expect(f.w.pendingSession, saved);
      f.offline = false;
      f.failRoomRestore = true;
      await f.w.start();
      expect(f.w.pendingSession, saved);
      expect(f.w.tabs.map((tab) => tab.appId), ['browser']);
      expect(storedApps(f), ['browser']);
      final browser = f.w.tabs.single;
      expect(
        (browser.page as FakePage).lastCommand,
        isNull,
        reason: 'an unused Browser tab reopens on its start page',
      );
      f.w.newTab();
      final userTab = f.w.active;
      f.failRoomRestore = false;
      await f.w.start();
      expect(f.w.pendingSession, isNull);
      expect(storedApps(f), ['browser', null, 'room-layout']);
      expect(
        f.w.tabs.where((tab) => tab.appId == 'browser').single,
        same(browser),
      );
      expect(f.w.active, same(userTab));
      expect(f.w.tabs.where((tab) => tab.appId == 'room-layout').length, 1);
      await f.w.start();
      expect(f.w.tabs.length, 3);
    },
  );
  test(
    'a bug recording keeps actions, changed replies and errors until saved',
    () async {
      final f = Fixture();
      addTearDown(f.w.dispose);
      await f.w.start();
      f.w.recorder.start();
      await f.w.openApp(f.w.apps[1]);
      await f.w.send('Where is the desk?');
      await f.w.refresh();
      f.w.error = 'Stop failed';
      f.w.changed();
      f.offline = true;
      await expectLater(f.w.saveBugReport('Desk missing'), throwsA(anything));
      expect(f.w.recorder.recording, isTrue, reason: 'a failed save can retry');
      f.offline = false;
      final file = await f.w.saveBugReport(
        'Desk missing',
        screenshot: Uint8List.fromList([1, 2]),
      );
      expect(file, 'bug-reports/report.json');
      expect(f.w.recorder.recording, isFalse);
      final report = f.bugReport!;
      expect(report['description'], 'Desk missing');
      expect(report['conversationId'], 'conversation');
      expect(report['screenshot'], base64Encode([1, 2]));
      final events = (report['events'] as List).cast<Json>();
      expect(
        events
            .where((event) => event['type'] == 'action')
            .map((e) => e['name']),
        ['open app', 'send message'],
      );
      expect(
        events.where((e) => e['path'] == '/api/conversations/conversation'),
        hasLength(1),
        reason: 'identical poll replies are recorded once',
      );
      expect(
        events.where((e) => e['type'] == 'error').map((e) => e['message']),
        ['Stop failed'],
      );
      await f.w.send('After saving');
      expect(f.w.recorder.events.length, events.length);
    },
  );
  test('tabs are saved as they change and reopen on the next start', () async {
    final first = Fixture();
    addTearDown(first.w.dispose);
    await first.w.start();
    final room = await first.w.openApp(first.w.apps[1]);
    first.w.newTab();
    await first.w.openApp(first.w.apps[0]);
    first.w.select(room);
    expect(first.stored.last['tabs'][0]['context'], {
      'viewId': 'room',
      'state': {'zone': 'work'},
    });
    final next = Fixture(
      session: jsonDecode(jsonEncode(first.stored.last)) as Json,
    );
    addTearDown(next.w.dispose);
    await next.w.start();
    expect(next.w.tabs.map((tab) => tab.appId), ['room-layout', 'browser']);
    expect(next.w.active!.appId, 'room-layout');
    expect(next.w.pendingSession, isNull);
  });
  test(
    'saved tabs open at once on the saved active tab and load together',
    () async {
      final f = Fixture(
        session: {
          'active': 1,
          'tabs': [
            {'appId': 'browser', 'url': 'https://example.com/desk'},
            {
              'appId': 'room-layout',
              'context': {
                'viewId': 'room',
                'state': {'zone': 'work'},
              },
            },
            {'appId': 'browser', 'url': 'about:blank'},
            {'appId': 'research', 'source': deskReport},
          ],
        },
      );
      addTearDown(f.w.dispose);
      f.w.conversationId = 'conversation';
      final hold = f.holdPages = Completer<void>();
      final starting = f.w.start();
      await pumpEventQueue();
      expect(f.w.tabs.map((tab) => tab.appId), [
        'browser',
        'room-layout',
        'browser',
        'research',
      ]);
      final report = f.w.tabs[3];
      expect(report.name, 'Desk report');
      expect(
        f.pages.map((page) => page.spec.id),
        unorderedEquals(f.w.tabs.map((tab) => tab.id)),
      );
      expect(f.w.active, same(f.w.tabs[1]));
      expect(f.stored, isEmpty, reason: 'the previous tabs stay saved');
      expect(f.w.snapshot, isNotNull, reason: 'chat loads without the tabs');
      final chosen = f.w.tabs[2];
      f.w.select(chosen);
      hold.complete();
      await starting;
      expect(f.w.pendingSession, isNull);
      expect(f.w.active, same(chosen));
      expect(f.w.tabs.length, 4);
      expect((f.w.tabs[1].page as FakePage).lastCommand!['intent']['state'], {
        'zone': 'work',
      });
      expect(report.report, isNotNull);
      expect((report.page as FakePage).spec.report, same(report.report));
    },
  );
  test('empty tabs fill in place, existing apps retain their page, closing releases it', () async {
    final f = Fixture();
    addTearDown(f.w.dispose);
    await f.w.start();
    f.w.newTab();
    final first = f.w.active!;
    f.w.newTab();
    final second = f.w.active!;
    f.w.select(first);
    final room = await f.w.openApp(f.w.apps[1]);
    expect(room.id, first.id);
    expect(f.w.tabs.map((tab) => tab.id), [first.id, second.id]);
    final page = room.page;
    f.w.select(second);
    await f.w.openApp(f.w.apps[1]);
    expect(f.w.tabs.length, 1);
    expect(f.w.active!.page, same(page));
    f.w.closeTab(room);
    expect((page as FakePage).disposed, isTrue);
    expect(f.w.tabs, isEmpty);
  });
  test(
    'a message sent during a poll still leaves the workspace busy',
    () async {
      final f = Fixture();
      addTearDown(f.w.dispose);
      await f.w.start();
      await f.w.send('First');
      final gate = f.holdSnapshot = Completer<void>();
      final poll = f.w.refresh();
      var returned = false;
      final sending = f.w.send('Second').then((_) => returned = true);
      await pumpEventQueue();
      expect(
        returned,
        isFalse,
        reason: 'the poll in flight holds the old state',
      );
      f.runs = [
        {'id': 'run', 'status': 'running'},
      ];
      f.holdSnapshot = null;
      gate.complete();
      await sending;
      await poll;
      expect(f.w.busy, isTrue);
    },
  );

  test('sends selected text and an explicit crop with the question', () async {
    final f = Fixture();
    addTearDown(f.w.dispose);
    await f.w.start();
    await f.w.openApp(f.w.apps[1]);
    final crop = (appId: f.w.apps[1].id, bytes: Uint8List.fromList([1, 2, 3]));
    await expectLater(
      f.w.send('Explain this', capture: crop),
      throwsStateError,
    );
    expect(f.sent, isNull);
    f.w.provider['supportsImageInput'] = true;
    await f.w.send('Explain this', capture: crop);
    expect(f.sent!['appContext']['surface']['selection'], 'selected passage');
    expect(f.sent!['capture'], {'appId': crop.appId, 'png': 'AQID'});
    await f.w.send('Another question');
    expect(f.sent!.containsKey('capture'), isFalse);
  });
  test('current-page context, scoped presentation, retained generation and manual invalidation', () async {
    final f = Fixture();
    addTearDown(f.w.dispose);
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    f.w.newTab();
    final browser = await f.w.openApp(f.w.apps[0]);
    await f.w.send('Compare this desk with my room');
    expect(f.sent!['appContext']['surface']['state']['tabId'], browser.id);
    expect(f.sent!['deviceId'], 'device');
    expect(f.sent!['tabId'], f.w.windowId);
    f.commands = [
      {...f.command('other', 'room-layout'), 'tabId': 'another-window'},
      f.command('open-room', 'room-layout'),
    ];
    await f.w.refresh();
    expect(f.w.active, same(room));
    expect(f.acks.length, 1);
    expect(f.acks.last['status'], 'applied');
    expect((room.page as FakePage).lastCommand!['expectedGeneration'], 5);
    final staleToken = room.token;
    f.w.select(browser);
    f.commands = [f.command('stale', 'room-layout', token: staleToken)];
    await f.w.refresh();
    expect(f.acks.last['status'], 'stale');
    final page = room.page as FakePage;
    page.pending = Completer<Json>();
    f.commands = [f.command('during-navigation', 'room-layout')];
    final refresh = f.w.refresh();
    while (page.lastCommand?['id'] != 'during-navigation') {
      await Future<void>.delayed(Duration.zero);
    }
    f.w.newTab();
    page.pending!.complete({'status': 'applied', 'context': page.context});
    await refresh;
    expect(f.acks.last['status'], 'stale');
    expect(f.w.active!.appId, isNull);
  });
  test(
    'failed presentations acknowledge the actual view for a corrected retry',
    () async {
      final f = Fixture();
      addTearDown(f.w.dispose);
      await f.w.start();
      final room = await f.w.openApp(f.w.apps[1]);
      final page = room.page as FakePage;
      await f.w.openApp(f.w.apps[0]);
      await f.w.send('Compare this page');
      page.result = {
        'status': 'failed',
        'context': {...page.context, 'generation': 6},
        'error': 'Invalid filter',
      };
      f.commands = [f.command('rejected', 'room-layout')];
      await f.w.refresh();
      expect(f.acks.last['status'], 'failed');
      expect(f.acks.last['viewToken'], f.w.active!.token);
      expect(f.acks.last['context']['generation'], 6);
      page.result = null;
      f.commands = [
        {
          ...f.command(
            'corrected',
            'room-layout',
            token: f.acks.last['viewToken'] as String,
          ),
          'expectedGeneration': 6,
        },
      ];
      await f.w.refresh();
      expect(f.acks.last['status'], 'applied');
      expect(page.lastCommand!['expectedGeneration'], 6);
    },
  );
  test('contextless requests navigate only while the originating view is unchanged', () async {
    final f = Fixture();
    addTearDown(f.w.dispose);
    await f.w.start();
    f.w.newTab();
    await f.w.send('Open Room');
    f.commands = [
      {...f.command('from-blank', 'room-layout'), 'expectedViewToken': null},
    ];
    await f.w.refresh();
    expect(f.acks.last['status'], 'applied');
    expect(f.w.active!.appId, 'room-layout');
    f.w.newTab();
    await f.w.send('Open Room again');
    f.w.newTab();
    f.commands = [
      {...f.command('after-switch', 'room-layout'), 'expectedViewToken': null},
    ];
    await f.w.refresh();
    expect(f.acks.last['status'], 'stale');
    expect(f.w.active!.appId, isNull);
  });
  test('bot scope excludes disallowed page context and saved sessions restore tabs', () async {
    final f = Fixture();
    addTearDown(f.w.dispose);
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    final browser = await f.w.openApp(f.w.apps[0]);
    f.w.select(room);
    f.w.selectedBotId = 'browser-bot';
    f.w.bots = [
      {
        'id': 'browser-bot',
        'appIds': ['browser'],
      },
    ];
    expect(f.w.allowedApps.map((a) => a.id), ['browser']);
    await f.w.send('A question without room access');
    expect(f.sent!.containsKey('appContext'), isFalse);
    f.w.select(browser);
    final session = f.w.session();
    for (final tab in f.w.tabs.toList()) {
      f.w.closeTab(tab);
    }
    await f.w.restoreSession(session);
    expect(f.w.tabs.map((t) => t.appId), ['room-layout', 'browser']);
    expect(f.w.active!.appId, 'browser');
    expect((f.w.tabs.first.page as FakePage).lastCommand!['intent']['state'], {
      'zone': 'work',
    });
  });
  test(
    'a split pair replaces, swaps, hides behind other tabs and ends',
    () async {
      final f = Fixture();
      addTearDown(f.w.dispose);
      await f.w.start();
      f.w.recorder.start();
      final room = await f.w.openApp(f.w.apps[1]);
      final browser = await f.w.openApp(f.w.apps[0]);
      f.w.newTab();
      final blank = f.w.active!;
      f.w.select(browser);
      expect(f.w.canSplitWith(browser), isFalse);
      f.w.dropInSplit(room, left: true);
      expect(f.w.split, [room, browser]);
      expect(f.w.active, room);
      f.w.splitWidth = .3;
      f.w.dropInSplit(room, left: false);
      expect(f.w.split, [browser, room]);
      f.w.dropInSplit(blank, left: false);
      expect(f.w.split, [browser, blank], reason: 'at most two panes');
      expect(f.w.splitWidth, .3, reason: 'swaps keep the divider');
      f.w.select(room);
      expect(f.w.splitShown, isFalse);
      f.w.select(browser);
      expect(f.w.splitShown, isTrue);
      f.w.leaveSplit(browser);
      expect(f.w.split, isNull);
      expect(f.w.active, blank);
      expect(
        f.w.recorder.events
            .where((event) => event['type'] == 'action')
            .map((event) => event['name'])
            .where((name) => name.toString().contains('split')),
        ['split tabs', 'split tabs', 'split tabs', 'end split'],
      );

      f.w.dropInSplit(room, left: true);
      expect(f.w.splitWidth, .5, reason: 'a new split starts at half');
      f.w.select(blank);
      final opened = await f.w.openApp(f.w.apps[0]);
      expect(opened.id, blank.id);
      expect(f.w.split, [room, opened], reason: 'the pane keeps its new app');
      f.w.closeTab(opened);
      expect(f.w.split, isNull);
      expect(f.w.active, room, reason: 'the partner stays shown');
    },
  );
  test(
    'the split pair is saved with the tabs and reopens on the next start',
    () async {
      final first = Fixture();
      addTearDown(first.w.dispose);
      await first.w.start();
      final room = await first.w.openApp(first.w.apps[1]);
      await first.w.openApp(first.w.apps[0]);
      first.w.dropInSplit(room, left: false);
      first.w
        ..splitWidth = .3
        ..changed();
      final saved = jsonDecode(jsonEncode(first.stored.last)) as Json;
      expect(saved['split'], [1, 0]);
      expect(saved['splitWidth'], .3);

      final next = Fixture(session: saved);
      addTearDown(next.w.dispose);
      await next.w.start();
      final tabs = next.w.tabs;
      expect(next.w.split, [tabs[1], tabs[0]]);
      expect(next.w.splitWidth, .3);
      expect(next.w.active, tabs[0]);
      expect(next.w.splitShown, isTrue);

      final failed = Fixture(session: saved)..failRoomRestore = true;
      addTearDown(failed.w.dispose);
      await failed.w.start();
      expect(failed.w.tabs.map((tab) => tab.appId), ['browser']);
      expect(
        failed.w.split,
        isNull,
        reason: 'a tab that failed ends the split',
      );
      expect(failed.stored.last.containsKey('split'), isFalse);
    },
  );
  test('reconnect does not bring back a split the user ended', () async {
    final f = Fixture(
      session: {
        'active': 0,
        'split': [0, 1],
        'tabs': [
          {'appId': 'browser', 'url': 'about:blank'},
          {'appId': 'research', 'source': deskReport},
          {
            'appId': 'room-layout',
            'context': {
              'viewId': 'room',
              'state': {'zone': 'work'},
            },
          },
        ],
      },
    )..failRoomRestore = true;
    addTearDown(f.w.dispose);
    await f.w.start();
    expect(f.w.tabs.map((tab) => tab.appId), ['browser', 'research']);
    expect(f.w.split, f.w.tabs);
    // Sessions saved before the divider existed have no width: start at half.
    expect(f.w.splitWidth, .5);
    f.w.leaveSplit(f.w.active!);
    f.failRoomRestore = false;
    await f.w.start();
    expect(f.w.tabs.length, 3);
    expect(f.w.split, isNull);
  });
  testWidgets('dragging tabs splits the page without recreating either view', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    final browser = await f.w.openApp(f.w.apps[0]);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final roomView = find.text('View Room layout', skipOffstage: false);
    final browserView = find.text('View Browser', skipOffstage: false);
    final roomElement = tester.element(roomView);
    final browserElement = tester.element(browserView);
    final page = tester.getRect(find.byKey(ValueKey('page-${browser.id}')));
    Finder chip(String title) => find.descendant(
      of: find.byType(WorkspaceTabs),
      matching: find.text(title),
    );

    final drag = await tester.startGesture(
      tester.getCenter(chip('Room layout')),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, 40));
    await drag.moveTo(Offset(page.left + 40, page.center.dy));
    await tester.pump();
    expect(find.byKey(const ValueKey('drop-left')), findsOneWidget);
    await drag.up();
    await tester.pumpAndSettle();
    expect(f.w.split, [room, browser]);
    expect(f.w.active, room);
    expect(tester.element(roomView), same(roomElement));
    expect(tester.element(browserView), same(browserElement));
    final left = tester.getRect(find.byKey(ValueKey('page-${room.id}')));
    final right = tester.getRect(find.byKey(ValueKey('page-${browser.id}')));
    expect(left.right, lessThan(right.left));
    expect(left.width, closeTo(right.width, 1));
    expect(find.byIcon(Icons.vertical_split), findsNWidgets(2));

    await tester.tapAt(right.center);
    await tester.pump();
    expect(f.w.active, browser);

    tester.view.physicalSize = const Size(700, 800);
    await tester.pumpAndSettle();
    expect(find.text('View Room layout'), findsNothing);
    expect(find.text('View Browser'), findsOneWidget);
    expect(find.byIcon(Icons.vertical_split), findsNothing);
    tester.view.physicalSize = const Size(1400, 800);
    await tester.pumpAndSettle();

    final back = await tester.startGesture(
      tester.getCenter(chip('Browser')),
      kind: PointerDeviceKind.mouse,
    );
    await back.moveBy(const Offset(0, 120));
    await back.moveTo(tester.getCenter(chip('Room layout')));
    await tester.pump();
    await back.up();
    await tester.pumpAndSettle();
    expect(f.w.split, isNull);
    expect(f.w.active, room);
    expect(find.text('View Browser'), findsNothing);
    expect(tester.element(roomView), same(roomElement));
    expect(tester.element(browserView), same(browserElement));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('the split divider resizes, resets and ends the split', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    final browser = await f.w.openApp(f.w.apps[0]);
    f.w.dropInSplit(room, left: true);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final roomView = find.text('View Room layout', skipOffstage: false);
    final browserView = find.text('View Browser', skipOffstage: false);
    final roomElement = tester.element(roomView);
    final browserElement = tester.element(browserView);
    Rect page(WorkspaceTab tab) =>
        tester.getRect(find.byKey(ValueKey('page-${tab.id}')));
    final width = page(browser).right - page(room).left;
    // Above the exit button in the middle of the divider.
    Offset grip() => tester
        .getRect(find.byKey(const ValueKey('split-divider')))
        .center
        .translate(0, -150);
    Future<void> dragDivider(double dx) async {
      final drag = await tester.startGesture(
        grip(),
        kind: PointerDeviceKind.mouse,
      );
      // The first pixels of a move only start the drag, as a mouse does.
      await drag.moveBy(Offset(dx.sign * 2, 0));
      await drag.moveBy(Offset(dx, 0));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
    }

    await dragDivider(150);
    expect(page(room).width, closeTo(width / 2 + 147, 2));
    expect(page(browser).width, closeTo(width / 2 - 153, 2));
    expect(f.stored.last['splitWidth'], closeTo(.5 + 150 / width, .01));
    expect(tester.element(roomView), same(roomElement));
    expect(tester.element(browserView), same(browserElement));

    await dragDivider(-2000);
    expect(page(room).width, closeTo(max(240, width * .2) - 3, 1));

    final reset = grip();
    await tester.tapAt(reset, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(reset, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(page(room).width, closeTo(page(browser).width, 1));
    expect(f.stored.last['splitWidth'], .5);

    await tester.tap(find.byTooltip('Exit split view'));
    await tester.pumpAndSettle();
    expect(f.w.split, isNull);
    expect(f.w.active, room, reason: 'the selected tab stays shown');
    expect(f.w.tabs, [room, browser]);
    expect(find.byKey(const ValueKey('split-divider')), findsNothing);
    expect(tester.element(roomView), same(roomElement));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('a click that moves a few pixels still selects the tab', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    await f.w.openApp(f.w.apps[0]);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final click = await tester.startGesture(
      tester.getCenter(
        find.descendant(
          of: find.byType(WorkspaceTabs),
          matching: find.text('Room layout'),
        ),
      ),
      kind: PointerDeviceKind.mouse,
    );
    await click.moveBy(const Offset(4, 3));
    await click.up();
    await tester.pumpAndSettle();
    expect(f.w.active, room);
    expect(f.w.split, isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'unready retained pages fail without blocking refresh and failed tabs reopen',
    (tester) async {
      final f = Fixture();
      addTearDown(f.w.dispose);
      await f.w.start();
      final room = await f.w.openApp(f.w.apps[1]);
      final oldPage = room.page as FakePage;
      oldPage.loading = Completer<void>();
      await f.w.openApp(f.w.apps[0]);
      await f.w.send('Open Room');
      f.commands = [f.command('unready', 'room-layout')];
      final refresh = f.w.refresh();
      await tester.pump();
      await tester.pump(const Duration(seconds: 21));
      await refresh;
      expect(f.acks.last['status'], 'failed');
      room.error = 'App did not finish loading';
      final reopened = await f.w.openApp(f.w.apps[1]);
      expect(reopened, same(room));
      expect(oldPage.disposed, isTrue);
      expect(reopened.page, isNot(same(oldPage)));
      expect(reopened.error, isNull);
      f.commands = [f.command('after-retry', 'room-layout')];
      await f.w.refresh();
      expect(f.acks.last['status'], 'applied');
    },
  );
  testWidgets('forwarded chat shows the handoff before the first message', (
    tester,
  ) async {
    final f = Fixture();
    f.w.snapshot = ConversationSnapshot.fromJson({
      'messages': [],
      'forwards': [
        {
          'sourceTitle': 'Room dimensions',
          'sourceConversationId': 'source-chat',
          'messageIds': ['message-1'],
          'note': 'Check doorway clearance',
        },
      ],
    });
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    expect(find.textContaining('Check doorway clearance'), findsOneWidget);
    await tester.tap(find.text('Forwarded: Room dimensions'));
    await tester.pumpAndSettle();
    expect(f.w.conversationId, 'source-chat');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'cold start publishes the app picker without a saved conversation',
    (tester) async {
      final f = Fixture();
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      expect(find.text('Room layout'), findsNothing);
      await f.w.start();
      await tester.pump();
      expect(find.text('Room layout'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'the app picker shows current registrations and keeps open tabs',
    (tester) async {
      final f = Fixture();
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      await f.w.start();
      final room = await f.w.openApp(f.w.apps[1]);
      f.configApps = [
        apps[0],
        {'id': 'garden', 'name': 'Garden', 'protocolVersion': 2},
      ];
      f.w.newTab();
      await tester.pump();
      await tester.pump();
      Finder picker(String name) => find.descendant(
        of: find.byType(NewTabPage),
        matching: find.text(name),
      );
      expect(picker('Garden'), findsOneWidget);
      expect(picker('Room layout'), findsNothing);
      expect(f.w.tabs, contains(room));
      expect((room.page as FakePage).disposed, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('the toolbar record button starts and finishes a bug recording', (
    tester,
  ) async {
    final f = Fixture();
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.tap(find.byTooltip('Record a bug'));
    await tester.pump();
    expect(f.w.recorder.recording, isTrue);
    await tester.tap(find.byTooltip('Recording a bug. Stop and save'));
    await tester.pumpAndSettle();
    expect(find.text('Save bug report'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(f.w.recorder.recording, isFalse);
    expect(find.byTooltip('Record a bug'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'compact chat keeps context, keyboard sending and grouped menus usable',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      await f.w.openApp(f.w.apps[1]);
      f.w.provider = {'model': 'DeepSeek', 'supportsReasoningEffort': true};
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byTooltip('Current page included. Click to exclude.'),
      );
      await tester.pump();
      expect(f.w.includeContext, isFalse);
      await tester.tap(find.byTooltip('Workspace menu'));
      await tester.pumpAndSettle();
      expect(find.text('WORKSPACE'), findsOneWidget);
      expect(find.text('Provider and model'), findsOneWidget);
      await tester.tap(find.text('Chat only'));
      await tester.pumpAndSettle();
      final input = find.byType(EditableText).last;
      await tester.enterText(input, 'First line');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(f.sent, isNull);
      await tester.enterText(input, 'First line\nSecond line');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(f.sent!['text'], 'First line\nSecond line');
      expect(f.sent!.containsKey('appContext'), isFalse);
      expect(tester.widget<EditableText>(input).controller.text, isEmpty);
      f.messages = [
        {'role': 'assistant', 'text': 'A readable reply'},
      ];
      await f.w.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Conversation options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show workspace'));
      await tester.pumpAndSettle();
      expect(find.text('A readable reply'), findsOneWidget);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(find.text('A readable reply'), findsOneWidget);
      await tester.tap(find.byTooltip('Workspace menu'));
      await tester.pumpAndSettle();
      expect(find.text('Provider and model'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'chat can reverse mid-slide and reduced motion closes immediately',
    (tester) async {
      final f = Fixture();
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dispatcher = tester.binding.platformDispatcher;
      addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pumpWidget(
        RelayApp(
          workspace: f.w,
          initialDraft: 'Keep this draft',
          saveDraft: (_) async {},
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.byTooltip('Toggle chat');
      final panel = find.byKey(const ValueKey('conversation-panel'));
      final docked = tester.getTopLeft(panel).dx;
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getTopLeft(panel).dx, inExclusiveRange(docked, 1200));
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(panel).dx, docked);
      expect(find.text('Keep this draft'), findsOneWidget);

      dispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pump();
      expect(panel, findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('chat reopens closed when it was left closed', (tester) async {
    final f = Fixture();
    final saved = <bool>[];
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(
        workspace: f.w,
        initialChatOpen: false,
        saveChatOpen: (open) async => saved.add(open),
        saveDraft: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('conversation-panel'));
    expect(panel, findsNothing);
    await tester.tap(find.byTooltip('Toggle chat'));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    expect(saved, [true]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('appearance follows the system until a theme is chosen', (
    tester,
  ) async {
    final f = Fixture();
    final saved = <ThemeMode>[];
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dispatcher = tester.binding.platformDispatcher;
    addTearDown(dispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      RelayApp(
        workspace: f.w,
        saveThemeMode: (mode) async => saved.add(mode),
        saveDraft: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    Brightness shown() =>
        Theme.of(tester.element(find.byType(RelayShell))).brightness;
    expect(shown(), Brightness.light);
    dispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(shown(), Brightness.dark);

    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(saved, [ThemeMode.light]);
    expect(shown(), Brightness.light);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'deleting a tab during insertion keeps the next tab interactive',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      final room = await f.w.openApp(f.w.apps[1]);
      final page = room.page!;
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      await tester.tap(find.byTooltip('New tab'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      f.w.closeTab(f.w.active!);
      await tester.tap(find.byTooltip('New tab'));
      await tester.pumpAndSettle();
      expect(f.w.tabs, [room, f.w.active]);
      expect(find.byTooltip('Close New tab'), findsOneWidget);
      await tester.tap(find.byTooltip('Close New tab'));
      await tester.pumpAndSettle();
      expect(f.w.active?.page, same(page));
      expect(find.byTooltip('Close New tab'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('desktop and phone picker, retained tabs and chat draft', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(
        workspace: f.w,
        initialDraft: 'Unsent thought',
        saveDraft: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New tab'));
    await tester.pumpAndSettle();
    expect(f.w.tabs.length, 1);
    await tester.enterText(find.byType(EditableText).first, 'Room');
    await tester.pumpAndSettle();
    expect(find.text('Browser'), findsNothing);
    await tester.tap(find.text('Room layout'));
    await tester.pumpAndSettle();
    expect(find.text('View Room layout'), findsOneWidget);
    expect(find.text('Unsent thought'), findsOneWidget);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New tab'));
    await tester.pumpAndSettle();
    expect(find.text('What would you like to open?'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Room layout').last);
    await tester.pumpAndSettle();
    expect(f.w.tabs.length, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a YouTube Browser tab offers a selectable transcript beside chat',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await f.w.openApp(f.w.apps[0]);
      final page = f.pages.last;
      await tester.pumpWidget(
        RelayApp(workspace: f.w, initialDraft: '', saveDraft: (_) async {}),
      );
      await tester.pumpAndSettle();
      expect(find.text('Transcript'), findsNothing);

      page.url = 'https://www.youtube.com/watch?v=video';
      f.w.changed();
      await tester.pumpAndSettle();
      expect(find.text('Transcript'), findsOneWidget);
      expect(page.transcriptLoads, 0);

      page.transcriptError = StateError('This video has no captions.');
      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();
      expect(find.text('This video has no captions.'), findsOneWidget);
      page
        ..transcriptError = null
        ..transcript = {
          'language': 'English',
          'text': '[0:01] Hello there\n[0:40] Second part',
        };
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(page.transcriptLoads, 2);
      final paragraph = find.text('[0:40] Second part');
      final panel = tester.getRect(
        find.byKey(const ValueKey('conversation-panel')),
      );
      expect(tester.getCenter(paragraph).dy, lessThan(panel.center.dy));

      final drag = await tester.startGesture(
        tester.getTopLeft(paragraph) + const Offset(1, 5),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(tester.getTopRight(paragraph) + const Offset(-1, 5));
      await drag.up();
      await tester.pumpAndSettle();
      expect(find.text('“[0:40] Second part”'), findsOneWidget);

      // Focus moving to the composer keeps the transcript selection.
      await tester.tap(find.byType(TextField).last);
      await tester.enterText(find.byType(TextField).last, 'What happens here?');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        f.sent!['appContext']['surface']['selection'],
        '[0:40] Second part',
      );
      await tester.tapAt(
        tester.getCenter(paragraph),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('“selected passage”'), findsOneWidget);

      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();
      expect(find.text('[0:40] Second part'), findsNothing);
      expect(find.text('“selected passage”'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'And now?');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(f.sent!['appContext']['surface']['selection'], 'selected passage');

      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();
      expect(find.text('[0:40] Second part'), findsOneWidget);

      // A newer selection on the page replaces the transcript's.
      final again = await tester.startGesture(
        tester.getTopLeft(paragraph) + const Offset(1, 5),
        kind: PointerDeviceKind.mouse,
      );
      await again.moveTo(tester.getTopRight(paragraph) + const Offset(-1, 5));
      await again.up();
      await tester.pumpAndSettle();
      expect(find.text('“[0:40] Second part”'), findsOneWidget);
      page.selection = 'newer page text';
      f.w.changed();
      await tester.pumpAndSettle();
      expect(find.text('“newer page text”'), findsOneWidget);
      page.selection = 'selected passage';

      // The expanded conversation keeps the transcript.
      await tester.tap(find.byTooltip('Conversation options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expand conversation'));
      await tester.pumpAndSettle();
      expect(find.text('[0:40] Second part'), findsOneWidget);
      await tester.tap(find.byTooltip('Conversation options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show workspace'));
      await tester.pumpAndSettle();
      expect(find.text('[0:40] Second part'), findsOneWidget);

      page.url = 'https://www.youtube.com/';
      f.w.changed();
      await tester.pumpAndSettle();
      expect(find.text('Transcript'), findsNothing);
      expect(find.text('“selected passage”'), findsOneWidget);

      page.url = 'https://www.youtube.com/watch?v=video';
      tester.view.physicalSize = const Size(390, 844);
      f.w.changed();
      await tester.pumpAndSettle();
      expect(find.text('Transcript'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the transcript follows the video until the user scrolls or selects',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await f.w.openApp(f.w.apps[0]);
      final page = f.pages.last
        ..url = 'https://www.youtube.com/watch?v=video'
        ..transcript = {
          'language': 'English',
          'text': [
            for (var i = 0; i < 30; i++)
              '[${i ~/ 3}:${(i % 3 * 20).toString().padLeft(2, '0')}] '
                  'Part $i ${'words ' * 100}',
          ].join('\n'),
        };
      await tester.pumpWidget(
        RelayApp(workspace: f.w, initialDraft: '', saveDraft: (_) async {}),
      );
      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();

      Finder part(int i) => find.textContaining(RegExp('] Part $i '));
      Color? shade(int i) =>
          (tester
                      .widget<DecoratedBox>(
                        find
                            .ancestor(
                              of: part(i),
                              matching: find.byType(DecoratedBox),
                            )
                            .first,
                      )
                      .decoration
                  as BoxDecoration)
              .color;
      final pane = tester.getRect(find.byType(TranscriptPane));
      final tint = Theme.of(tester.element(find.byType(TranscriptPane)))
          .colorScheme
          .primary
          .withValues(alpha: .14);
      bool shown(int i) => pane.contains(tester.getTopLeft(part(i)));
      final scroll = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byType(TranscriptPane),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      Future<void> play(double? seconds) async {
        page.time = seconds;
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
      }

      final follow = find.text('Follow video');
      expect(shade(0), isNull);
      // 2:30 is within Part 7, which starts at 2:20.
      await play(150);
      expect(shade(7), tint);
      expect(shown(7), isTrue);
      expect(follow, findsNothing);
      // A seek back moves it; an unknown time, as during an ad, keeps it.
      await play(5);
      expect([shade(0), shade(7)], [tint, null]);
      expect(shown(0), isTrue);
      await play(null);
      expect(shade(0), tint);

      // Scrolling by hand stops following; the highlight still moves.
      final wheel = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(wheel.hover(pane.center));
      await tester.sendEventToBinding(wheel.scroll(const Offset(0, 300)));
      await tester.pumpAndSettle();
      expect(follow, findsOneWidget);
      final offset = scroll.pixels;
      await play(570);
      expect(shade(28), tint);
      expect(scroll.pixels, offset);
      await tester.tap(follow);
      await tester.pumpAndSettle();
      expect(shown(28), isTrue);
      expect(follow, findsNothing);

      // Selecting stops following, which never disturbs the selection.
      final start = tester.getTopLeft(part(28)) + const Offset(1, 5);
      final drag = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(start + const Offset(150, 0));
      await drag.up();
      await tester.pumpAndSettle();
      final kept = find.textContaining('“[9:20] Part');
      expect(kept, findsOneWidget);
      expect(follow, findsOneWidget);
      await play(20);
      expect(shade(1), tint);
      expect(shown(28), isTrue);
      await tester.tap(follow);
      await tester.pumpAndSettle();
      expect(shown(1), isTrue);
      expect(kept, findsOneWidget);

      // Closing the pane stops reading the time.
      await tester.tap(find.text('Transcript'));
      await tester.pumpAndSettle();
      final reads = page.timeReads;
      await tester.pump(const Duration(seconds: 2));
      expect(page.timeReads, reads);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('screenshot selection opens inside the active tab beside chat', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await f.w.openApp(f.w.apps[1]);
    f.pages.last.frame = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
      final image = await recorder.endRecording().toImage(80, 60);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return png!.buffer.asUint8List();
    });
    await tester.pumpWidget(
      RelayApp(workspace: f.w, initialDraft: '', saveDraft: (_) async {}),
    );
    await tester.pumpAndSettle();
    final page = tester.getRect(find.text('View Room layout'));
    final panel = tester.getRect(
      find.byKey(const ValueKey('conversation-panel')),
    );

    Future<void> settle(Finder until) async {
      for (var i = 0; i < 30 && until.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    await tester.tap(find.byTooltip('Capture an area'));
    await settle(find.text('Drag over the area to attach'));
    expect(find.byType(Dialog), findsNothing);
    expect(tester.getRect(find.byType(RegionCapture)), page);
    expect(
      tester.getRect(find.byKey(const ValueKey('conversation-panel'))),
      panel,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(RegionCapture), findsNothing);

    Future<void> captureArea() async {
      await tester.tap(find.byTooltip('Capture an area'));
      await settle(find.byType(RegionCapture));
      await tester.dragFrom(
        page.topLeft + const Offset(20, 20),
        const Offset(200, 120),
      );
      await settle(find.byTooltip('Remove screenshot'));
    }

    final thumbnail = find.ancestor(
      of: find.byWidgetPredicate((w) => w is Image && w.image is! NetworkImage),
      matching: find.byType(Opacity),
    );

    // Reduced motion attaches the area at once.
    final dispatcher = tester.platformDispatcher;
    dispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
    addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    await captureArea();
    expect(find.byType(CaptureFlight), findsNothing);
    expect(tester.widget<Opacity>(thumbnail.first).opacity, 1);
    await tester.tap(find.byTooltip('Remove screenshot'));
    dispatcher.clearAccessibilityFeaturesTestValue();
    await tester.pump();

    await captureArea();
    expect(find.byType(RegionCapture), findsNothing);
    expect(find.text('Screenshot · room-layout'), findsOneWidget);
    // The picture flies to the composer, whose thumbnail shows once it lands.
    expect(find.byType(CaptureFlight), findsOneWidget);
    expect(tester.widget<Opacity>(thumbnail.first).opacity, 0);
    await tester.pumpAndSettle();
    expect(find.byType(CaptureFlight), findsNothing);
    expect(tester.widget<Opacity>(thumbnail.first).opacity, 1);
    f.w.provider = {'supportsImageInput': true};
    await tester.enterText(find.byType(EditableText).first, 'What is this?');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect((f.sent!['capture'] as Json)['appId'], 'room-layout');

    // The reopened conversation loads the screenshot the server kept.
    f.messages = [
      {
        'id': 'sent',
        'role': 'user',
        'text': 'What is this?',
        'hasCapture': true,
      },
    ];
    await f.w.refresh();
    await tester.pump();
    final shown = tester.widget<Image>(
      find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage),
    );
    expect(
      (shown.image as NetworkImage).url,
      'http://localhost:3250/api/conversations/conversation/messages/sent/capture',
    );
    await settle(find.text('Screenshot attached'));
    expect(find.text('Screenshot attached'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

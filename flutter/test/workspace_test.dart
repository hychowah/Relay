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
import 'package:relay_flutter/split_layout.dart';
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
  final navigated = <String>[];
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
  int generation = 5;
  @override
  Json get context => {
    'viewId': spec.browser ? 'browser' : 'room',
    'generation': generation,
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
  Future<void> navigate(String text, {bool restoring = false}) async {
    navigated.add(restoring ? 'restore $text' : text);
    changed(true);
  }

  @override
  bool pdf = false;
  @override
  bool get canHighlight => spec.browser;
  final actions = <String>[];
  @override
  Future<void> browserAction(String action) async => actions.add(action);

  @override
  bool fullScreen = false;
  final screenFills = <bool>[];
  @override
  Future<void> fillScreen(bool on) async {
    screenFills.add(on);
    if (!on) fullScreen = false;
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
  Fixture({Json? session, bool newestTabFirst = false}) {
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
    );
  }
  final savedNewestFirst = <bool>[];
  // The server's conversation last opened on any device, and each device's
  // saved tabs as the server lists them.
  String? current, sentTo;
  Completer<void>? holdCurrent;
  List<Json> devices = [];
  bool offline = false, failRoomRestore = false;
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

void main() {
  test('the conversation last opened on any device opens here', () async {
    final f = Fixture()..current = 'elsewhere';
    await f.w.start();
    expect(f.w.conversationId, 'elsewhere');

    // Another device opened a newer one while this one stayed in front.
    f.current = 'later';
    expect(f.w.conversationId, 'elsewhere');
    await f.w.openCurrentConversation();
    expect(f.w.conversationId, 'later');

    await f.w.selectConversation('mine');
    expect(f.current, 'mine');
    // A new chat is not current anywhere until its first message saves it,
    // and returning to the front keeps it.
    await f.w.newConversation();
    expect(f.current, 'mine');
    await f.w.openCurrentConversation();
    expect(f.w.conversationId, isNull);
    f.w.dispose();
  });

  test(
    'following another device never moves a send or undoes a click',
    () async {
      final f = Fixture()..current = 'mine';
      await f.w.start();

      // The app returns to the front as the user sends in the chat shown.
      f.current = 'other';
      f.holdCurrent = Completer();
      final following = f.w.openCurrentConversation();
      await f.w.send('hello');
      f.holdCurrent!.complete();
      await following;
      expect(f.sentTo, '/api/conversations/mine/messages');
      expect(f.w.conversationId, 'mine');

      // Or as the user picks a chat.
      f.holdCurrent = Completer();
      final again = f.w.openCurrentConversation();
      await f.w.selectConversation('picked');
      f.holdCurrent!.complete();
      await again;
      expect(f.w.conversationId, 'picked');
      expect(f.current, 'picked');
      f.w.dispose();
    },
  );

  test('copying tabs from a split\'s empty pane keeps the split', () async {
    final f = Fixture();
    addTearDown(f.w.dispose);
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    f.w.newTab();
    final blank = f.w.active!;
    f.w.dropInSplit(room, blank, SplitSide.right);
    final split = f.w.shownSplit!;
    f.w.select(blank);
    await f.w.openDeviceTabs({
      'active': 0,
      'tabs': [
        {'appId': 'browser', 'url': 'https://news.example/'},
      ],
    });
    expect(f.w.tabs, contains(blank));
    expect(split.layout.tabs, [blank, room]);
  });

  testWidgets('another device\'s tabs open here once, from the new tab page', (
    tester,
  ) async {
    final f = Fixture()
      ..devices = [
        {
          'id': 'device',
          'name': 'This device',
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
          'tabs': {
            'active': 0,
            'tabs': [
              {'appId': 'browser', 'url': 'https://here.example/'},
            ],
          },
        },
        {
          'id': 'mac',
          'name': 'Mac',
          'updatedAt': DateTime.now()
              .subtract(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
          'tabs': {
            'active': 1,
            'tabs': [
              {'appId': 'browser', 'url': 'https://news.example/today'},
              {'appId': 'room-layout'},
            ],
          },
        },
      ];
    await f.w.start();
    f.w.newTab();
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    expect(find.text("Open This device's tabs here"), findsNothing);
    expect(find.text('5 min ago · news.example · Room layout'), findsOneWidget);

    await tester.tap(find.text("Open Mac's tabs here"));
    await tester.pumpAndSettle();
    // The empty tab it was opened from goes; the Mac's shown tab shows.
    expect([for (final tab in f.w.tabs) tab.appId], ['browser', 'room-layout']);
    expect(f.w.active?.appId, 'room-layout');
    expect(f.pages.first.navigated, ['restore https://news.example/today']);
    await tester.pumpWidget(const SizedBox());
  });

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
    'newest tab first moves opened tabs left and restores saved order',
    () async {
      final off = Fixture();
      addTearDown(off.w.dispose);
      await off.w.start();
      final offRoom = await off.w.openApp(off.w.apps[1]);
      await off.w.openApp(off.w.apps[0]);
      off.w.select(offRoom, opened: true);
      expect(off.w.tabs.map((tab) => tab.appId), ['room-layout', 'browser']);

      final f = Fixture(newestTabFirst: true);
      addTearDown(f.w.dispose);
      await f.w.start();
      final room = await f.w.openApp(f.w.apps[1]);
      final browser = await f.w.openApp(f.w.apps[0]);
      f.w.newTab();
      final blank = f.w.active!;
      expect(f.w.tabs, [blank, browser, room]);
      f.w.dropInSplit(browser, blank, SplitSide.right);
      final split = f.w.shownSplit!;
      expect(f.w.tabs, [
        split,
        blank,
        browser,
        room,
      ], reason: 'a new split tab opens on the left; the others keep order');
      f.w.select(room, opened: true);
      expect(f.w.tabs, [room, split, blank, browser]);
      // An app the agent opens, here into the blank pane, also moves left.
      f.w.select(split);
      f.w.select(blank);
      final opened = await f.w.openApp(f.w.apps[0], manual: false);
      expect(f.w.tabs, [opened, room, split, browser]);
      expect(f.w.shownSplit, split);
      expect(split.layout.tabs, [opened, browser]);
      expect(f.w.session(), containsPair('active', 2));
      expect(f.w.session()['tabs'][2]['split']['panes'], [0, 3]);

      f.w.select(room);
      final next = Fixture(
        session: jsonDecode(jsonEncode(f.stored.last)) as Json,
        newestTabFirst: true,
      );
      addTearDown(next.w.dispose);
      await next.w.start();
      final tabs = next.w.tabs;
      expect(tabs.map((tab) => tab.appId), [
        'browser',
        'room-layout',
        null,
        'browser',
      ]);
      expect(next.w.active, tabs[1]);
      expect((tabs[2] as SplitTab).layout.tabs, [tabs[0], tabs[3]]);
    },
  );
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
      // The page reported the view it was left at with the failure.
      page.generation = 6;
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
  test('a request without context presents in the app already open', () async {
    final f = Fixture();
    addTearDown(f.w.dispose);
    await f.w.start();
    final browser = await f.w.openApp(f.w.apps[0]);
    f.w.includeContext = false;
    await f.w.send('Open example.com');
    expect(f.sent!['appContext'], isNull);
    // The server expects generation 0 when no context was sent.
    f.commands = [
      {...f.command('open-site', 'browser'), 'expectedViewToken': null},
    ];
    await f.w.refresh();
    expect(f.acks.last['status'], 'applied');
    expect(f.w.active, same(browser));
    expect((browser.page as FakePage).lastCommand!['expectedGeneration'], 5);
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
    expect((f.w.active!.page as FakePage).navigated, [
      'restore https://example.com/desk',
    ]);
  });
  test('a split is its own tab whose panes nest, move and leave', () async {
    final f = Fixture();
    addTearDown(f.w.dispose);
    await f.w.start();
    f.w.recorder.start();
    final room = await f.w.openApp(f.w.apps[1]);
    final browser = await f.w.openApp(f.w.apps[0]);
    f.w.newTab();
    final blank = f.w.active!;
    f.w.select(browser);
    f.w.dropInSplit(browser, browser, SplitSide.left);
    expect(f.w.shownSplit, isNull, reason: 'a tab cannot split its own pane');
    f.w.dropInSplit(room, browser, SplitSide.left);
    final split = f.w.shownSplit!;
    expect(f.w.tabs, [room, browser, blank, split]);
    expect(split.title, 'Room layout + Browser');
    expect(split.layout.tabs, [room, browser]);
    expect(split.layout.axis, Axis.horizontal);
    expect(f.w.active, room);

    f.w.dropInSplit(blank, browser, SplitSide.bottom);
    expect(split.layout.tabs, [room, browser, blank]);
    final column = split.layout.second as SplitBranch;
    expect(column.axis, Axis.vertical, reason: 'only the dropped-on pane');
    expect(column.fraction, .5, reason: 'each new split starts at half');

    split.layout.fraction = .3;
    f.w.dropInSplit(blank, room, SplitSide.top);
    expect(split.layout.tabs, [blank, room, browser], reason: 'a pane moves');
    expect(split.layout.second, isA<SplitPane>());
    expect(split.layout.fraction, .3, reason: 'moving keeps other dividers');

    // A tab's own tab shows it alone; the split tab brings the split back
    // with the pane selected last.
    f.w.select(room, alone: true);
    expect(f.w.shownSplit, isNull);
    expect(f.w.active, room);
    f.w.select(split);
    expect(f.w.shownSplit, split);
    expect(f.w.active, blank);
    f.w.select(browser);
    expect(f.w.shownSplit, split, reason: 'selecting a pane keeps the split');

    f.w.leaveSplit(browser);
    expect(split.layout.tabs, [blank, room], reason: 'its neighbour grows');
    expect(f.w.active, blank);
    f.w.closeTab(split);
    expect(f.w.tabs, [room, browser, blank], reason: 'its tabs stay open');
    expect(f.w.shownSplit, isNull);
    expect(f.w.active, blank, reason: 'the selected tab shows alone');
    expect(
      f.w.recorder.events
          .where((event) => event['type'] == 'action')
          .map((event) => event['name'])
          .where((name) => name.toString().contains('split')),
      ['split tabs', 'split tabs', 'split tabs', 'leave split'],
    );

    // A tab can be in several splits; closing it leaves every one, and a
    // split left with one pane closes.
    f.w.dropInSplit(room, blank, SplitSide.right);
    final first = f.w.shownSplit!;
    f.w.select(browser, alone: true);
    f.w.dropInSplit(blank, browser, SplitSide.left);
    final second = f.w.shownSplit!;
    f.w.select(blank);
    final opened = await f.w.openApp(f.w.apps[0]);
    expect(opened.id, blank.id);
    expect(f.w.shownSplit, second, reason: 'the pane keeps its new app');
    expect(first.layout.tabs, [opened, room]);
    expect(second.layout.tabs, [opened, browser]);
    f.w.closeTab(room);
    expect(f.w.tabs, [browser, opened, second]);
    f.w.closeTab(opened);
    expect(f.w.tabs, [browser]);
    expect(f.w.shownSplit, isNull);
    expect(f.w.active, browser, reason: 'the remaining pane stays shown');
  });
  test(
    'split tabs are saved with the tabs and reopen on the next start',
    () async {
      final first = Fixture();
      addTearDown(first.w.dispose);
      await first.w.start();
      final room = await first.w.openApp(first.w.apps[1]);
      final browser = await first.w.openApp(first.w.apps[0]);
      final second = await first.w.openApp(first.w.apps[0]);
      first.w.dropInSplit(room, second, SplitSide.right);
      first.w.dropInSplit(browser, room, SplitSide.bottom);
      first.w.shownSplit!.layout.fraction = .3;
      first.w.changed();
      final saved = jsonDecode(jsonEncode(first.stored.last)) as Json;
      expect(saved['active'], 3);
      expect(saved['tabs'][3], {
        'split': {
          'axis': 'horizontal',
          'fraction': .3,
          'panes': [
            2,
            {
              'axis': 'vertical',
              'fraction': .5,
              'panes': [0, 1],
            },
          ],
        },
        'focus': 1,
      });

      final next = Fixture(session: saved);
      addTearDown(next.w.dispose);
      await next.w.start();
      final tabs = next.w.tabs;
      final split = tabs[3] as SplitTab;
      expect(next.w.shownSplit, split);
      expect(split.layout.tabs, [tabs[2], tabs[0], tabs[1]]);
      expect(split.layout.fraction, .3);
      expect(next.w.active, tabs[1]);

      final failed = Fixture(session: saved)..failRoomRestore = true;
      addTearDown(failed.w.dispose);
      await failed.w.start();
      final kept = failed.w.tabs;
      expect(kept.map((tab) => tab.appId), ['browser', 'browser', null]);
      expect((kept[2] as SplitTab).layout.tabs, [
        kept[1],
        kept[0],
      ], reason: 'a tab that failed leaves the split');
    },
  );
  test('reconnect fills a split saved before a pane it retries', () async {
    // Newest tab first saves a new split tab ahead of its panes.
    final f = Fixture(
      session: {
        'active': 0,
        'tabs': [
          {
            'split': {
              'axis': 'horizontal',
              'fraction': .5,
              'panes': [1, 2],
            },
            'focus': 2,
          },
          {
            'appId': 'room-layout',
            'context': {
              'viewId': 'room',
              'state': {'zone': 'work'},
            },
          },
          {'appId': 'browser', 'url': 'https://example.com/desk'},
        ],
      },
    )..configApps = [apps[1]];
    addTearDown(f.w.dispose);
    await f.w.start();
    expect(f.w.tabs.map((tab) => tab.appId), ['room-layout']);
    expect(f.w.pendingSession, isNotNull, reason: 'the Browser is retried');

    f.configApps = [...apps];
    await f.w.start();
    expect(f.w.error, isNull);
    expect(f.w.pendingSession, isNull);
    final tabs = f.w.tabs;
    expect(tabs.map((tab) => tab.appId), ['room-layout', null, 'browser']);
    expect((tabs[1] as SplitTab).layout.tabs, [tabs[0], tabs[2]]);
    expect(f.stored.last['tabs'][1]['split']['panes'], [0, 2]);
  });
  test('reconnect does not bring back a split tab the user closed', () async {
    final f = Fixture(
      session: {
        'active': 3,
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
          {
            'split': {
              'axis': 'horizontal',
              'fraction': .5,
              'panes': [0, 1],
            },
            'focus': 1,
          },
        ],
      },
    )..failRoomRestore = true;
    addTearDown(f.w.dispose);
    await f.w.start();
    expect(f.w.tabs.map((tab) => tab.appId), ['browser', 'research', null]);
    expect(f.w.shownSplit!.layout.tabs, f.w.tabs.take(2));
    expect(f.w.active, f.w.tabs[1]);
    f.w.closeTab(f.w.shownSplit!);
    f.failRoomRestore = false;
    await f.w.start();
    expect(f.w.tabs.map((tab) => tab.appId), [
      'browser',
      'research',
      'room-layout',
    ]);
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
    Rect page(WorkspaceTab tab) =>
        tester.getRect(find.byKey(ValueKey('page-${tab.id}')));
    final whole = page(browser);
    // Both Browser tabs have the same title.
    Finder chip(String title, [int index = 0]) => find
        .descendant(of: find.byType(WorkspaceTabs), matching: find.text(title))
        .at(index);

    Future<void> dragTab(Finder tab, Offset to, String highlight) async {
      final drag = await tester.startGesture(
        tester.getCenter(tab),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(0, 40));
      await drag.moveTo(to);
      await tester.pump();
      expect(find.byKey(ValueKey(highlight)), findsOneWidget);
      await drag.up();
      await tester.pumpAndSettle();
    }

    await dragTab(
      chip('Room layout'),
      Offset(whole.left + 40, whole.center.dy),
      'drop-left',
    );
    final split = f.w.shownSplit!;
    expect(split.layout.tabs, [room, browser]);
    expect(f.w.active, room);
    expect(chip('Room layout + Browser'), findsOneWidget);
    // The split tab draws its panes as they are arranged.
    Rect mapPane(WorkspaceTab tab) =>
        tester.getRect(find.byKey(ValueKey('split-map-${tab.id}')));
    expect(mapPane(room).right, lessThan(mapPane(browser).left));
    expect(mapPane(room).height, mapPane(browser).height);
    expect(mapPane(room).height, greaterThan(10));
    expect(tester.element(roomView), same(roomElement));
    expect(tester.element(browserView), same(browserElement));
    final left = page(room);
    final right = page(browser);
    expect(left.right, lessThan(right.left));
    expect(left.width, closeTo(right.width, 1));
    expect(find.byIcon(Icons.vertical_split), findsNWidgets(2));

    await tester.tapAt(right.center);
    await tester.pump();
    expect(f.w.active, browser);
    // Browser shows its address bar once selected, which moves the pages.
    final selected = page(browser), beside = page(room);
    // On macOS a native page gets no input wherever Flutter paints over it, so
    // nothing may overlap the selected page, edges included. Its outline is a
    // frame around the page; each other pane has a tint that one click selects.
    void expectNothingOver(WorkspaceTab tab, List<WorkspaceTab> others) {
      final selected = page(tab);
      final pages = find
          .ancestor(
            of: find.byKey(ValueKey(tab.id)),
            matching: find.byType(Stack),
          )
          .first;
      final inPage = find
          .descendant(
            of: find.byKey(ValueKey('page-${tab.id}')),
            matching: find.byWidgetPredicate((_) => true),
          )
          .evaluate()
          .toSet();
      final painted = find.descendant(
        of: pages,
        matching: find.byWidgetPredicate(
          (w) => w is ColoredBox || w is DecoratedBox || w is CustomPaint,
        ),
      );
      final outline = Theme.of(tester.element(pages)).colorScheme.primary
          .withValues(alpha: .45);
      var outlines = 0;
      for (final element in painted.evaluate()) {
        if (inPage.contains(element)) continue;
        final box = element.renderObject! as RenderBox;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        expect(
          rect.overlaps(selected),
          isFalse,
          reason: '$rect ${element.widget} ${element.widget.key}',
        );
        final widget = element.widget;
        if (widget is ColoredBox && widget.color == outline) outlines++;
      }
      expect(outlines, 4);
      expect(find.byKey(ValueKey('pane-${tab.id}')), findsNothing);
      for (final other in others) {
        expect(find.byKey(ValueKey('pane-${other.id}')), findsOneWidget);
      }
    }

    expectNothingOver(browser, [room]);

    // A second Browser tab dropped near the bottom edge stacks under it.
    final second = await f.w.openApp(f.w.apps[0]);
    f.w.select(split);
    await tester.pumpAndSettle();
    await dragTab(
      chip('Browser', 1),
      Offset(selected.center.dx, selected.bottom - 30),
      'drop-bottom',
    );
    expect(split.layout.tabs, [room, browser, second]);
    expect(page(browser).bottom, lessThan(page(second).top));
    expect(page(browser).left, selected.left);
    expect(page(second).width, page(browser).width);
    expect(mapPane(browser).bottom, lessThan(mapPane(second).top));
    expect(mapPane(room).right, lessThan(mapPane(second).left));
    expect(page(room), beside, reason: 'other panes keep their place');
    expect(tester.element(browserView.first), same(browserElement));
    expect(f.w.active, second);
    expectNothingOver(second, [room, browser]);
    // One click on the dimmed top pane selects it.
    await tester.tapAt(page(browser).center);
    await tester.pump();
    expect(f.w.active, browser);
    expectNothingOver(browser, [room, second]);
    // The split tab's map fills the pane selected last.
    Color? fill(WorkspaceTab tab) =>
        (tester
                    .widget<DecoratedBox>(
                      find.byKey(ValueKey('split-map-${tab.id}')),
                    )
                    .decoration
                as BoxDecoration)
            .color;
    expect(fill(browser), isNotNull);
    expect([fill(room), fill(second)], [null, null]);

    tester.view.physicalSize = const Size(700, 800);
    await tester.pumpAndSettle();
    expect(find.text('View Room layout'), findsNothing);
    expect(find.byIcon(Icons.vertical_split), findsNothing);
    expect(
      tester.widget<WorkspaceTabs>(find.byType(WorkspaceTabs)).selected,
      browser,
      reason: 'the strip marks the tab on screen, not the hidden split',
    );
    tester.view.physicalSize = const Size(1400, 800);
    await tester.pumpAndSettle();

    // Dragging a tab back to the tab strip takes it out of the split.
    final back = await tester.startGesture(
      tester.getCenter(chip('Browser', 1)),
      kind: PointerDeviceKind.mouse,
    );
    await back.moveBy(const Offset(0, 120));
    await back.moveTo(tester.getCenter(chip('Room layout')));
    await tester.pump();
    await back.up();
    await tester.pumpAndSettle();
    expect(split.layout.tabs, [room, browser]);
    expect(
      page(browser).height,
      page(room).height,
      reason: 'its neighbour grows',
    );

    // Clicking an app's own tab shows it full screen; the split tab stays.
    await tester.tap(chip('Room layout'));
    await tester.pumpAndSettle();
    expect(f.w.shownSplit, isNull);
    expect(page(room).width, closeTo(whole.width, 1));
    expect(find.text('View Browser'), findsNothing);
    await tester.tap(chip('Room layout + Browser'));
    await tester.pumpAndSettle();
    expect(f.w.shownSplit, split);
    expect(f.w.active, browser, reason: 'the pane selected last');
    expect(page(room).width, beside.width);
    expect(page(room).left, beside.left);

    // Closing the split tab keeps every app open.
    await tester.tap(find.byTooltip('Close Room layout + Browser'));
    await tester.pumpAndSettle();
    expect(f.w.tabs, [room, browser, second]);
    expect(f.w.active, browser, reason: 'the selected pane shows alone');
    expect(page(browser).width, closeTo(whole.width, 1));
    expect(tester.element(roomView), same(roomElement));
    expect(tester.element(browserView.first), same(browserElement));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('split dividers resize side by side and stacked, and reset', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    final browser = await f.w.openApp(f.w.apps[0]);
    final second = await f.w.openApp(f.w.apps[0]);
    f.w.dropInSplit(room, second, SplitSide.left);
    f.w.dropInSplit(browser, second, SplitSide.top);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final roomView = find.text('View Room layout', skipOffstage: false);
    final roomElement = tester.element(roomView);
    Rect page(WorkspaceTab tab) =>
        tester.getRect(find.byKey(ValueKey('page-${tab.id}')));
    final width = page(browser).right - page(room).left;
    final height = page(second).bottom - page(browser).top;
    Offset grip(int index) =>
        tester.getRect(find.byKey(ValueKey('split-divider-$index'))).center;
    double saved() => f.stored.last['tabs'][3]['split']['fraction'] as double;
    Future<void> dragDivider(int index, Offset by) async {
      final drag = await tester.startGesture(
        grip(index),
        kind: PointerDeviceKind.mouse,
      );
      // The first pixels of a move only start the drag, as a mouse does.
      await drag.moveBy(Offset(by.dx.sign * 2, by.dy.sign * 2));
      await drag.moveBy(by);
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
    }

    await dragDivider(0, const Offset(150, 0));
    expect(page(room).width, closeTo(width / 2 + 147, 2));
    expect(page(browser).width, closeTo(width / 2 - 153, 2));
    expect(saved(), closeTo(.5 + 150 / width, .01));
    expect(tester.element(roomView), same(roomElement));

    await dragDivider(0, const Offset(-2000, 0));
    expect(page(room).width, closeTo(max(240, width * .2) - 7, 1));

    // The divider between the stacked panes moves up and down.
    await dragDivider(1, const Offset(0, 100));
    expect(page(browser).height, closeTo(height / 2 + 97, 2));
    expect(page(second).height, closeTo(height / 2 - 103, 2));

    final reset = grip(0);
    await tester.tapAt(reset, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(reset, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(page(room).width, closeTo(page(browser).width, 1));
    expect(saved(), .5);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'a fullscreen video takes the whole screen alone and its pane in split',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      final room = await f.w.openApp(f.w.apps[1]);
      final browser = await f.w.openApp(f.w.apps[0]);
      final video = browser.page! as FakePage;
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(
          workspace: f.w,
          initialDraft: 'Keep this draft',
          saveDraft: (_) async {},
        ),
      );
      await tester.pumpAndSettle();
      final view = find.byKey(ValueKey('page-${browser.id}'));
      final element = tester.element(view);
      final alone = tester.getRect(view);
      final menu = find.byTooltip('Workspace menu');
      final address = find.text('Search or enter a web address');
      final chat = find.text('Keep this draft');
      Future<void> pageFullScreen(bool on) async {
        video.fullScreen = on;
        video.changed(false);
        await tester.pumpAndSettle();
      }

      await pageFullScreen(true);
      expect(tester.getRect(view), const Rect.fromLTWH(0, 0, 1400, 800));
      expect(video.screenFills, [true]);
      expect(menu, findsNothing);
      expect(address, findsNothing);
      // Chat stays built, with its draft, but hidden.
      expect(chat, findsNothing);
      expect(find.text('Keep this draft', skipOffstage: false), findsOneWidget);
      expect(tester.element(view), same(element));

      // Escape in the page ends its fullscreen.
      await pageFullScreen(false);
      expect(tester.getRect(view), alone);
      expect(video.screenFills, [true, false]);
      expect(menu, findsOneWidget);
      expect(chat, findsOneWidget);

      // Another tab taking the screen ends the page's fullscreen.
      await pageFullScreen(true);
      f.w.select(room);
      await tester.pumpAndSettle();
      expect(video.screenFills, [true, false, true, false]);
      expect(video.fullScreen, isFalse);
      expect(menu, findsOneWidget);

      // In split view the video fills only its own pane.
      f.w.dropInSplit(browser, room, SplitSide.right);
      await tester.pumpAndSettle();
      final pane = tester.getRect(view);
      await pageFullScreen(true);
      expect(tester.getRect(view), pane);
      expect(video.screenFills, [true, false, true, false]);
      expect(menu, findsOneWidget);
      expect(chat, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('a Browser tab highlights selected text, and zooms a PDF', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final pdf = (await f.w.openApp(f.w.apps[0])).page! as FakePage;
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Zoom in'), findsNothing);
    // With nothing selected there is nothing to highlight.
    IconButton highlight() => tester.widget(
      find.widgetWithIcon(IconButton, Icons.border_color),
    );
    pdf.selection = '';
    pdf.changed(false);
    await tester.pumpAndSettle();
    expect(highlight().onPressed, isNull);

    pdf.pdf = true;
    pdf.changed(false);
    await tester.pumpAndSettle();
    for (final button in ['Zoom out', 'Zoom in', 'Fit to width']) {
      await tester.tap(find.byTooltip(button));
    }
    expect(pdf.actions, ['zoomOut', 'zoomIn', 'zoomFit']);
    expect(highlight().onPressed, isNull);

    pdf.selection = 'selected passage';
    pdf.changed(true);
    await tester.pumpAndSettle();
    highlight().onPressed!();
    expect(pdf.actions.last, 'highlight');
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
    expect(f.w.shownSplit, isNull);
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
    'address bar asks the server for visited pages as the user types',
    (tester) async {
      final f = Fixture()
        ..historyPages = [
          {'url': 'https://example.com/', 'title': ''},
          {'url': 'https://example.com/desk', 'title': 'Desk'},
          {'url': 'https://news.example/', 'title': 'News'},
        ];
      await f.w.start();
      await f.w.openApp(f.w.apps[0]);
      final page = f.pages.single;
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}, browserHistory: true),
      );
      await tester.pumpAndSettle();
      final address = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'Search or enter a web address',
      );
      // Entered at once over the whole address, as a paste after a focusing
      // click, so nothing fills in.
      Future<void> type(String text) async {
        final controller = tester.widget<TextField>(address).controller!;
        controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: controller.text.length,
        );
        await tester.enterText(address, text);
        await tester.pumpAndSettle();
      }

      Future<void> submit() async {
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
      }

      // The address the app wrote asks for nothing, even with the field focused.
      await tester.tap(address);
      await tester.pumpAndSettle();
      expect(f.history, isEmpty);
      expect(find.text('Desk'), findsNothing);

      // Browsing history stays out of bug recordings.
      f.w.recorder.start();
      await type('exa');
      expect(f.history, ['suggest exa']);
      expect(find.text('Desk'), findsOneWidget);
      expect(find.text('News'), findsOneWidget);
      await submit();
      expect(page.navigated, ['exa'], reason: 'nothing was highlighted');
      expect(find.text('Desk'), findsNothing);
      expect(
        f.history.last,
        'POST /api/browser-history/typed {"url":"https://example.com/desk"}',
      );

      await type('exa');
      // Below the example.com site row and its desk page.
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      await submit();
      expect(page.navigated.last, 'https://news.example/');

      // Typing again returns the highlight to the typed text.
      await type('exa');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await type('exam');
      await submit();
      expect(page.navigated.last, 'exam');

      // A slow answer for older text never replaces the newer one, and Enter
      // opens the text in the field while the earlier list is still shown.
      f.holdHistory['e'] = Completer();
      await type('e');
      await type('ne');
      expect(find.text('News'), findsOneWidget);
      f.holdHistory['e']!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Desk'), findsNothing);
      f.holdHistory['new'] = Completer();
      await type('new');
      await submit();
      expect(page.navigated.last, 'new');
      f.holdHistory['new']!.complete();
      await tester.pumpAndSettle();
      expect(find.text('News'), findsNothing);
      expect(tester.widget<TextField>(address).controller!.text, 'new');

      await type('news');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('News'), findsNothing);
      await submit();
      expect(page.navigated.last, 'news');

      await type('ne');
      await tester.tap(find.text('News'));
      await tester.pumpAndSettle();
      expect(page.navigated.last, 'https://news.example/');

      // A new page address replaces typed text without opening suggestions.
      await type('ne');
      expect(find.text('News'), findsOneWidget);
      final asked = f.history.length;
      page.url = 'https://example.com/';
      f.w.changed();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(address).controller!.text, page.url);
      expect(find.text('Desk'), findsNothing);
      expect(find.text('News'), findsNothing);
      expect(f.history, hasLength(asked));

      // An older backend without history shows no suggestions.
      f.historyPages = null;
      await type('desk');
      expect(find.text('Desk'), findsNothing);

      expect(
        f.w.recorder.events.where((e) => '${e['path']}'.contains('history')),
        isEmpty,
      );
      f.w.recorder.stop();
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('inline completion continues the typed text with the best address', () {
    expect(inlineCompletion('you', 'https://www.youtube.com/'), 'youtube.com');
    expect(inlineCompletion('YOU', 'https://www.youtube.com/'), 'YOUtube.com');
    expect(
      inlineCompletion('www.you', 'https://youtube.com/'),
      'www.youtube.com',
    );
    expect(
      inlineCompletion('HTTPS://you', 'http://www.YouTube.com/watch?v=1'),
      'HTTPS://youTube.com/watch?v=1',
    );
    expect(inlineCompletion('ex', 'https://example.com/a/'), 'example.com/a/');
    expect(inlineCompletion('tube', 'https://youtube.com/'), isNull);
    expect(inlineCompletion('youtube.com', 'https://youtube.com/'), isNull);
    expect(inlineCompletion('www.', 'https://www.youtube.com/'), isNull);
  });

  testWidgets(
    'address bar selects all on a focusing click and fills in the best page',
    (tester) async {
      final f = Fixture()
        ..historyPages = [
          {'url': 'http://www.example.com/', 'title': ''},
          {'url': 'https://example.com/desk', 'title': 'Desk'},
        ];
      await f.w.start();
      await f.w.openApp(f.w.apps[0]);
      final page = f.pages.single;
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}, browserHistory: true),
      );
      await tester.pumpAndSettle();
      final address = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'Search or enter a web address',
      );
      final field = tester.widget<TextField>(address).controller!;
      TextEditingValue shown(String text, [int? typed]) => TextEditingValue(
        text: text,
        selection: TextSelection(
          baseOffset: typed ?? text.length,
          extentOffset: text.length,
        ),
      );
      Future<void> edit(TextEditingValue value) async {
        tester.testTextInput.updateEditingValue(value);
        await tester.pumpAndSettle();
      }

      Future<void> key(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      // The click that focuses the bar selects the address; the next one
      // places the caret.
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(field.selection, TextSelection(baseOffset: 0, extentOffset: 24));
      await tester.pump(kDoubleTapTimeout);
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(field.selection.isCollapsed, isTrue);

      // A paste fills nothing in; the next typed character fills in the best
      // page after the typed text, asking for nothing more.
      await edit(shown(''));
      await edit(shown('exa'));
      expect(field.value, shown('exa'));
      expect(find.text('Desk'), findsOneWidget);
      await edit(shown('exam'));
      expect(field.value, shown('example.com', 4));
      expect(f.history, ['suggest exa', 'suggest exam']);
      // Typing what is filled in next keeps the fill-in at once.
      await edit(shown('examp'));
      expect(field.value, shown('example.com', 5));
      expect(f.history, ['suggest exa', 'suggest exam', 'suggest examp']);
      // Deleting removes the fill-in and fills nothing in again.
      await key(LogicalKeyboardKey.backspace);
      expect(field.value, shown('examp'));
      await key(LogicalKeyboardKey.backspace);
      expect(field.value, shown('exam'));
      await edit(shown('examp'));
      expect(field.value, shown('example.com', 5));
      // Esc removes the fill-in and closes the list.
      await key(LogicalKeyboardKey.escape);
      expect(field.value, shown('examp'));
      expect(find.text('Desk'), findsNothing);

      // Enter and Go open the filled-in page's own URL, not the shown text,
      // also once the caret has accepted the fill-in.
      field.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      await edit(shown('e'));
      expect(field.value, shown('example.com', 1));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(page.navigated, ['http://www.example.com/']);
      expect(
        f.history.last,
        'POST /api/browser-history/typed {"url":"https://example.com/desk"}',
      );
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await edit(shown('e'));
      expect(field.value, shown('example.com', 1));
      await key(LogicalKeyboardKey.arrowRight);
      expect(field.value, shown('example.com'));
      await tester.tap(find.byTooltip('Go'));
      await tester.pumpAndSettle();
      expect(page.navigated, List.filled(2, 'http://www.example.com/'));
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await edit(shown('e'));
      await key(LogicalKeyboardKey.arrowRight);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(page.navigated, List.filled(3, 'http://www.example.com/'));
      // With nothing filled in, as after a paste, Enter opens the text as is.
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await edit(shown('exa'));
      expect(field.value, shown('exa'));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(page.navigated.last, 'exa');
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await edit(shown('desk'));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(page.navigated.last, 'desk');

      // An answer fills nothing in once the text or caret has moved on.
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      f.holdHistory['e'] = Completer();
      f.holdHistory['ex'] = Completer();
      await edit(shown('e'));
      await edit(shown('ex'));
      await edit(shown('ex?'));
      f.holdHistory['e']!.complete();
      f.holdHistory['ex']!.complete();
      await tester.pumpAndSettle();
      expect(field.value, shown('ex?'));
      f.holdHistory['exa'] = Completer();
      await edit(shown('exa'));
      await key(LogicalKeyboardKey.arrowLeft);
      f.holdHistory['exa']!.complete();
      await tester.pumpAndSettle();
      expect(field.text, 'exa');
      expect(field.selection, const TextSelection.collapsed(offset: 2));

      // Nothing fills in while an input method is composing.
      await edit(shown(''));
      const composing = TextEditingValue(
        text: 'exa',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      );
      await edit(composing);
      expect(field.value, composing);
      await edit(shown('exa'));
      expect(field.value, shown('example.com', 3));
      await tester.pumpWidget(const SizedBox());
    },
    // A click on macOS places the caret as the mouse goes down.
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('newest tab first is a saved setting and slides the tab left', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    await f.w.openApp(f.w.apps[2]);
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Newest tab first'));
    await tester.pumpAndSettle();
    expect(f.w.newestTabFirst, isTrue);
    expect(f.savedNewestFirst, [true]);

    Finder chip(String title) => find.descendant(
      of: find.byType(WorkspaceTabs),
      matching: find.text(title),
    );
    double left(String title) => tester.getTopLeft(chip(title)).dx;
    // The moving chip is drawn larger while it travels, then lands at rest.
    double width(String title) => tester
        .getRect(
          find.ancestor(of: chip(title), matching: find.byType(Material)).first,
        )
        .width;
    final start = left('Research'), end = left('Room layout');
    final rest = width('Research');
    await tester.tap(chip('Research'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(f.w.tabs.last, room);
    expect(left('Research'), allOf(lessThan(start), greaterThan(end)));
    expect(width('Research'), greaterThan(rest));
    expect(width('Room layout'), moreOrLessEquals(rest));
    await tester.pumpAndSettle();
    expect(left('Research'), end);
    expect(left('Room layout'), start);
    expect(width('Research'), rest);

    // A tab moved from the far end of a scrolled strip is scrolled into view.
    for (var i = 0; i < 6; i++) {
      f.w.newTab();
    }
    await tester.pumpAndSettle();
    final strip = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(WorkspaceTabs),
        matching: find.byType(Scrollable),
      ),
    );
    strip.position.jumpTo(strip.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(strip.position.pixels, greaterThan(0));
    await tester.tap(chip('Room layout'));
    await tester.pumpAndSettle();
    expect(f.w.tabs.first, room);
    expect(strip.position.pixels, 0);
    expect(left('Room layout'), end);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'with newest tab first, clicking tab D of A B C D gives D A B C',
    (tester) async {
      final f = Fixture()
        ..configApps = [
          ...apps,
          {'id': 'notes', 'name': 'Notes', 'description': 'Notes'},
        ];
      await f.w.start();
      final [a, b, c, d] = [for (final app in f.w.apps) await f.w.openApp(app)];
      f.w.select(a);
      f.w.setNewestTabFirst(true);
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(WorkspaceTabs),
          matching: find.text('Notes'),
        ),
      );
      await tester.pumpAndSettle();
      expect(f.w.tabs, [d, a, b, c]);
      expect(f.w.active, d);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
      // A seek back moves it, rebuilding only the two paragraphs that change;
      // an unknown time, as during an ad, keeps it.
      final rebuilt = <Widget>[];
      debugOnRebuildDirtyWidget = (element, _) => rebuilt.add(element.widget);
      await play(5);
      debugOnRebuildDirtyWidget = null;
      expect(rebuilt.whereType<TranscriptPane>(), isEmpty);
      expect(rebuilt.whereType<ValueListenableBuilder<bool>>(), hasLength(2));
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

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/workspace.dart';
import 'package:relay_flutter/region_capture.dart';

const apps = [
  {'id': 'browser', 'name': 'Browser', 'description': 'Web pages'},
  {
    'id': 'room-layout',
    'name': 'Room layout',
    'description': 'Furniture',
    'protocolVersion': 2,
  },
];

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
  String get url => 'https://example.com/desk';
  @override
  Json get context => {
    'viewId': spec.browser ? 'browser' : 'room',
    'generation': 5,
    'selection': 'selected passage',
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
  Completer<void>? holdSnapshot;
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
        await tester.pump();
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

    await tester.tap(find.byTooltip('Capture an area'));
    await settle(find.byType(RegionCapture));
    await tester.dragFrom(
      page.topLeft + const Offset(20, 20),
      const Offset(200, 120),
    );
    await settle(find.byTooltip('Remove screenshot'));
    expect(find.byType(RegionCapture), findsNothing);
    expect(find.text('Screenshot · room-layout'), findsOneWidget);
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

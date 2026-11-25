import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/workspace.dart';
import 'package:relay_flutter/split_layout.dart';

import 'support/fake_page.dart';
import 'support/fixture.dart';

void main() {
  test('a poll that fails and then succeeds clears its own error', () async {
    final f = Fixture()..current = 'c';
    addTearDown(f.w.dispose);
    await f.w.start();
    f.failSnapshot = true;
    await f.w.refresh();
    expect(f.w.pollError, 'Snapshot failed');
    expect(f.w.error, isNull);
    f.failSnapshot = false;
    await f.w.refresh();
    expect(f.w.pollError, isNull);
    // A new chat is not polled, so opening one clears the error itself.
    f.failSnapshot = true;
    await f.w.refresh();
    expect(f.w.pollError, 'Snapshot failed');
    await f.w.selectConversation(null);
    expect(f.w.pollError, isNull);
  });

  test(
    'an error from a user action outlasts a failing and a good poll',
    () async {
      final f = Fixture()..current = 'c';
      addTearDown(f.w.dispose);
      await f.w.start();
      f.failSend = true;
      await expectLater(f.w.send('Hello'), throwsA(anything));
      final sendError = f.w.error;
      expect(sendError, isNotNull);
      f.failSnapshot = true;
      await f.w.refresh();
      expect(f.w.error, sendError);
      expect(f.w.pollError, 'Snapshot failed');
      f.failSnapshot = false;
      await f.w.refresh();
      expect(f.w.error, sendError);
      expect(f.w.pollError, isNull);
    },
  );

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
  test(
    'a conversation poll redraws only when the conversation changed',
    () async {
      final f = Fixture();
      addTearDown(f.w.dispose);
      f.current = 'conversation';
      await f.w.start();
      var redraws = 0;
      f.w.addListener(() => redraws++);
      await f.w.refresh();
      expect(redraws, 0);

      f.messages = [
        {'id': 'm', 'role': 'user', 'text': 'Hello', 'createdAt': 'now'},
      ];
      await f.w.refresh();
      expect(redraws, 1);
      expect(f.w.messages.single.text, 'Hello');

      // A failed poll shows its error; the next, unchanged, clears it.
      f.failSnapshot = true;
      await f.w.refresh();
      f.failSnapshot = false;
      await f.w.refresh();
      expect(f.w.pollError, isNull);
      expect(redraws, 3);

      // Opened again, the same conversation is drawn again.
      await f.w.selectConversation('conversation');
      await f.w.refresh();
      expect(f.w.messages.single.text, 'Hello');
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
  test('the VPN switch reopens a Browser tab and is saved with it', () async {
    final first = Fixture();
    addTearDown(first.w.dispose);
    await first.w.start();
    final tab = await first.w.openApp(first.w.apps[0]);
    final before = tab.page as FakePage;
    await first.w.toggleVpn();
    final after = tab.page as FakePage;
    expect(before.disposed, isTrue);
    expect(after.spec.vpn, isTrue);
    expect(after.navigated, ['https://example.com/desk']);
    expect(first.stored.last['tabs'][0]['vpn'], isTrue);
    final next = Fixture(
      session: jsonDecode(jsonEncode(first.stored.last)) as Json,
    );
    addTearDown(next.w.dispose);
    await next.w.start();
    expect((next.w.active!.page as FakePage).spec.vpn, isTrue);
    await next.w.toggleVpn();
    expect(next.stored.last['tabs'][0], isNot(contains('vpn')));
  });
  test('a VPN tab that cannot be restored stays, with its error', () async {
    final first = Fixture();
    addTearDown(first.w.dispose);
    await first.w.start();
    await first.w.openApp(first.w.apps[0]);
    await first.w.toggleVpn();
    first.w.newTab();
    await first.w.openApp(first.w.apps[0]);
    FakePage.navigateError = StateError('The VPN route failed.');
    addTearDown(() => FakePage.navigateError = null);
    final next = Fixture(
      session: jsonDecode(jsonEncode(first.stored.last)) as Json,
    );
    addTearDown(next.w.dispose);
    await next.w.start();
    // The normal tab closes as before.
    expect(next.w.tabs.map((tab) => tab.vpn), [true]);
    expect(next.w.error, contains('The VPN route failed.'));
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
  testWidgets('a Browser tab off screen for 30 minutes unloads until shown', (
    tester,
  ) async {
    final f = Fixture(unloadAfter: const Duration(minutes: 30));
    addTearDown(f.w.dispose);
    await f.w.loadConfig();
    final reading = await f.w.openApp(f.w.apps[0]);
    final listening = await f.w.openApp(f.w.apps[0]);
    (listening.page as FakePage).sound = true;
    final room = await f.w.openApp(f.w.apps[1]);
    final first = reading.page as FakePage;

    await tester.pump(const Duration(minutes: 29));
    expect(reading.page, same(first));
    await tester.pump(const Duration(minutes: 2));
    expect((reading.page, first.disposed), (null, true));
    expect(reading.unloaded, (
      url: 'https://example.com/desk',
      title: 'Browser',
    ));
    expect(reading.title, 'Browser');
    expect(listening.page, isNotNull, reason: 'It plays sound.');
    expect(room.page, isNotNull, reason: 'App tabs stay loaded.');
    expect(f.w.session()['tabs'][0]['url'], 'https://example.com/desk');

    // A tab that plays for almost an hour counts its time from when it falls
    // silent.
    await tester.pump(const Duration(minutes: 28));
    expect(listening.page, isNotNull);
    (listening.page as FakePage).sound = false;
    await tester.pump(const Duration(minutes: 2));
    expect(listening.page, isNotNull);

    // The agent reads it off screen; it unloads again, and a click loads it.
    await f.w.browserTab(reading.id);
    expect(f.w.active, same(room));
    expect((reading.page as FakePage).navigated, [
      'restore https://example.com/desk',
    ]);
    await tester.pump(const Duration(minutes: 31));
    expect(reading.page, isNull);
    f.w.select(reading);
    await tester.pump();
    expect((reading.page as FakePage).navigated, [
      'restore https://example.com/desk',
    ]);
    // Shown, it stays loaded.
    await tester.pump(const Duration(minutes: 40));
    expect(reading.page, isNotNull);
    expect(room.page, isNotNull);
    expect(listening.page, isNull);
  });
  testWidgets('only a Browser tab on screen has its form read or filled', (
    tester,
  ) async {
    final f = Fixture(unloadAfter: const Duration(minutes: 30));
    addTearDown(f.w.dispose);
    await f.w.loadConfig();
    final hidden = await f.w.openApp(f.w.apps[0]);
    final shown = await f.w.openApp(f.w.apps[0]);
    final room = await f.w.openApp(f.w.apps[1]);
    f.w.select(shown);
    await tester.pump(const Duration(minutes: 31));
    Future<String> refusal(WorkspaceTab tab) => f.w
        .shownBrowserTab(tab.id)
        .then((_) => 'none', onError: (Object e) => '$e');

    expect(await f.w.shownBrowserTab(shown.id), same(shown.page));
    // A tab off screen is refused and stays unloaded; an app tab is no form.
    expect(await refusal(hidden), contains('Open that tab to fill its form.'));
    expect(hidden.page, isNull);
    expect(await refusal(room), contains('Open that tab'));

    // Both panes of a split show, but a narrow window shows only one.
    f.w.dropInSplit(hidden, shown, SplitSide.right);
    await tester.pump();
    expect(await f.w.shownBrowserTab(hidden.id), same(hidden.page));
    expect(await f.w.shownBrowserTab(shown.id), same(shown.page));
    f.w.splitShown = false;
    final other = f.w.active == hidden ? shown : hidden;
    expect(await refusal(other), contains('Open that tab'));
    expect(await refusal(f.w.active!), 'none');

    // An expanded conversation covers every page.
    f.w.pageShown = false;
    expect(await refusal(f.w.active!), contains('expanded conversation'));
  });
  testWidgets('Reload, Go and an agent view load an unloaded tab first', (
    tester,
  ) async {
    final f = Fixture(unloadAfter: const Duration(minutes: 30));
    addTearDown(f.w.dispose);
    addTearDown(() => FakePage.navigateError = null);
    await f.w.loadConfig();
    f.w.conversationId = 'conversation';
    final reading = await f.w.openApp(f.w.apps[0]);
    final room = await f.w.openApp(f.w.apps[1]);
    // Each time it is shown while the network is down, so it stays unloaded.
    Future<void> failedWhileShown() async {
      f.w.select(room);
      await tester.pump(const Duration(minutes: 31));
      FakePage.navigateError = StateError('No network');
      f.w.select(reading);
      await tester.pump();
      FakePage.navigateError = null;
      expect(
        (reading.page, reading.unloaded?.url),
        (null, 'https://example.com/desk'),
      );
    }

    await failedWhileShown();
    await f.w.browserAction('reload');
    expect((reading.page as FakePage).navigated, [
      'restore https://example.com/desk',
    ]);

    await failedWhileShown();
    await f.w.navigate('https://example.org/next');
    expect(reading.unloaded, isNull);
    expect((reading.page as FakePage).navigated, ['https://example.org/next']);

    await failedWhileShown();
    f.commands = [f.command('agent-view', 'browser')];
    await f.w.refresh();
    expect(f.acks.last['status'], 'applied');
    expect((reading.page as FakePage).navigated, [
      'restore https://example.com/desk',
    ]);
  });
  testWidgets('an unloaded tab keeps its address until it loads again', (
    tester,
  ) async {
    final f = Fixture(unloadAfter: const Duration(minutes: 30));
    addTearDown(f.w.dispose);
    await f.w.loadConfig();
    final reading = await f.w.openApp(f.w.apps[0]);
    await f.w.openApp(f.w.apps[1]);
    await tester.pump(const Duration(minutes: 31));
    expect(reading.page, isNull);

    // Offline just after waking: the tab stays unloaded with the error.
    FakePage.navigateError = StateError('No network');
    addTearDown(() => FakePage.navigateError = null);
    f.w.select(reading);
    await tester.pump();
    expect(reading.page, isNull);
    expect(reading.error, contains('No network'));
    expect(
      (reading.unloaded?.url, reading.title),
      ('https://example.com/desk', 'Browser'),
    );
    expect(f.w.session()['tabs'][0]['url'], 'https://example.com/desk');
    await expectLater(
      f.w.browserTab(reading.id),
      throwsA(predicate((e) => '$e'.contains('No network'))),
    );

    // Clicking it again retries; meanwhile the address is still saved, and a
    // read waits for the page rather than answering from the start page.
    FakePage.navigateError = null;
    final hold = f.holdPages = Completer<void>();
    f.w.select(reading);
    await tester.pump();
    expect(reading.error, isNull);
    expect(f.w.session()['tabs'][0]['url'], 'https://example.com/desk');
    final read = f.w.browserTab(reading.id);
    hold.complete();
    await read;
    expect(reading.unloaded, isNull);
    expect((reading.page as FakePage).navigated, [
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
}

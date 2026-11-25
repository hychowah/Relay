import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/app_library.dart';
import 'package:relay_flutter/app_servers.dart';
import 'package:relay_flutter/app_updates.dart';
import 'package:relay_flutter/bug_reports.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/provider_settings.dart';
import 'package:relay_flutter/region_capture.dart';
import 'package:relay_flutter/shared_folders.dart';
import 'package:relay_flutter/stored_data.dart';
import 'package:relay_flutter/workspace_dialogs.dart';

import 'support/fake_page.dart';
import 'support/fixture.dart';

void main() {
  testWidgets('a bug report pictures the whole window with its page in place', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    tester.view.physicalSize = const Size(3000, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await f.w.openApp(f.w.apps[1]);
    final page = f.pages.last;
    page.frame = await tester.runAsync(() async {
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
    final shown = tester.getRect(find.byKey(ValueKey('page-${page.spec.id}')));
    final panel = tester.getRect(
      find.byKey(const ValueKey('conversation-panel')),
    );

    // The window picture is made by the engine, outside the test's clock.
    Future<void> settle(Finder until) async {
      for (var i = 0; i < 100 && until.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    // The saved picture's width and its colours in the page and the chat.
    Future<(int, List<int>, List<int>)> record([String? category]) async {
      await tester.tap(find.byTooltip('Record a bug or request'));
      await tester.pump();
      expect(f.w.recorder.recording, isTrue);
      // A second click during the capture must not start another one.
      await tester.tap(find.byTooltip('Recording. Stop and save'));
      await tester.tap(find.byTooltip('Recording. Stop and save'));
      await settle(find.text('Save report'));
      await tester.pumpAndSettle();
      expect(find.text('Save report'), findsOneWidget);
      if (category != null) await tester.tap(find.text(category));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save on server'));
      await tester.pumpAndSettle();
      expect(f.w.recorder.recording, isFalse);
      final png = base64Decode(f.bugReport!['screenshot'] as String);
      return (await tester.runAsync(() async {
        final image = await decodeFrame(png);
        final pixels = (await image.toByteData())!.buffer.asUint8List();
        final scale = image.width / 1500;
        List<int> at(Offset point) {
          final i =
              ((point.dy * scale).round() * image.width +
                  (point.dx * scale).round()) *
              4;
          return pixels.sublist(i, i + 3);
        }

        final result = (
          image.width,
          at(shown.topLeft + shown.size.bottomRight(Offset.zero) * .75),
          at(panel.center),
        );
        image.dispose();
        return result;
      }))!;
    }

    final (width, inPage, inChat) = await record();
    expect(width, 2000, reason: 'the longest side is capped');
    expect(inPage, [0x21, 0x96, 0xf3], reason: 'the page snapshot in place');
    expect(inChat, isNot(inPage), reason: 'the chat panel is in the picture');
    expect(f.bugReport!['category'], 'bug');

    page.frame = null;
    final (_, notCaptured, _) = await record('Request');
    expect(f.bugReport!['category'], 'request');
    expect(notCaptured, [0xd4, 0xd4, 0xd4]);
    expect(find.text('Page not captured'), findsNothing, reason: 'cleared');

    await tester.tap(find.byTooltip('Record a bug or request'));
    await tester.pump();
    await tester.tap(find.byTooltip('Recording. Stop and save'));
    await settle(find.text('Save report'));
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(f.w.recorder.recording, isFalse);
    expect(find.byTooltip('Record a bug or request'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('a dot marks the workspace menu while an update is ready', (
    tester,
  ) async {
    final f = Fixture();
    final updates = AppUpdates(
      origin: Uri.parse('http://localhost'),
      version: '0.0.1',
      directory: Directory.systemTemp,
    );
    await tester.pumpWidget(
      RelayApp(workspace: f.w, saveDraft: (_) async {}, updates: updates),
    );
    await tester.pumpAndSettle();
    final dots = find.byWidgetPredicate(
      (widget) => widget is Badge && widget.isLabelVisible,
    );
    expect(dots, findsNothing);

    updates.download = File('ready');
    updates.changed();
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byTooltip('Workspace menu'), matching: dots),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    expect(find.text('Update ready'), findsOneWidget);
    expect(dots, findsNWidgets(2));

    updates.download = null;
    updates.changed();
    await tester.pumpAndSettle();
    expect(find.text('Updates'), findsOneWidget);
    expect(dots, findsNothing);
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

  testWidgets('each workspace menu item opens its dialog, recorded by name', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final updates = AppUpdates(
      origin: Uri.parse('http://localhost'),
      version: '0.0.1',
      directory: Directory.systemTemp,
      client: MockClient((_) async => http.Response('Not found', 404)),
    );
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(workspace: f.w, saveDraft: (_) async {}, updates: updates),
    );
    await tester.pumpAndSettle();
    f.w.recorder.start();
    Future<void> opens(String item, Finder dialog) async {
      await tester.tap(find.byTooltip('Workspace menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, item));
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget, reason: item);
      Navigator.pop(tester.element(dialog));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing, reason: item);
    }

    await opens('App library', find.byType(AppLibrary));
    await opens('Bots', find.widgetWithText(WorkspaceDialog, 'Bots'));
    await opens('Memory', find.byType(MemoryDialog));
    await opens('App servers', find.byType(AppServersDialog));
    await opens('Shared folders', find.byType(SharedFoldersDialog));
    await opens('Provider and model', find.byType(ProviderSettings));
    await opens('Stored data', find.byType(StoredDataDialog));
    await opens('Updates', find.byType(UpdateDialog));
    await opens('Reports', find.byType(BugReportsDialog));
    // Chat only covers the page.
    final picker = find.text('What would you like to open?');
    expect((f.w.pageShown, picker.evaluate().length), (true, 1));
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Chat only'));
    await tester.pumpAndSettle();
    expect((f.w.pageShown, picker.evaluate().length), (false, 0));
    expect(
      [
        for (final event in f.w.recorder.events)
          if (event['name'] == 'menu') event['item'],
      ],
      [
        'library',
        'bots',
        'memory',
        'servers',
        'folders',
        'provider',
        'stored',
        'updates',
        'reports',
        'chat',
      ],
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Forward is offered only with a conversation, bots and no reply',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      f.w.bots = [
        {'id': 'helper', 'name': 'Helper'},
      ];
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      await tester.pumpAndSettle();
      final forward = find.widgetWithText(
        MenuItemButton,
        'Forward conversation',
      );
      // A running reply's spinner never settles, so these pump a fixed time.
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }

      Future<bool> offered() async {
        f.w.changed();
        await settle();
        await tester.tap(find.byTooltip('Conversation options'));
        await settle();
        final enabled =
            tester.widget<MenuItemButton>(forward).onPressed != null;
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle();
        return enabled;
      }

      expect(await offered(), isFalse, reason: 'no conversation yet');
      f.w.conversationId = 'conversation';
      expect(await offered(), isTrue);
      f.w.bots = [];
      expect(await offered(), isFalse, reason: 'no bot to forward to');
      f.w.bots = [
        {'id': 'helper', 'name': 'Helper'},
      ];
      f.runs = [
        {'id': 'run', 'status': 'running'},
      ];
      await f.w.refresh();
      expect(await offered(), isFalse, reason: 'a reply is running');
      f.runs = [];
      await f.w.refresh();
      expect(await offered(), isTrue);

      f.w.recorder.start();
      await tester.tap(find.byTooltip('Conversation options'));
      await tester.pumpAndSettle();
      await tester.tap(forward);
      await tester.pumpAndSettle();
      expect(find.byType(ForwardDialog), findsOneWidget);
      expect(
        f.w.recorder.events.where((e) => e['name'] == 'menu').single['item'],
        'forward',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a bug report saves the window and chat state, and a failed save shows '
    'its error until dismissed',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      final updates = AppUpdates(
        origin: Uri.parse('http://localhost'),
        version: '0.0.1',
        directory: Directory.systemTemp,
      );
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(
          workspace: f.w,
          initialChatOpen: false,
          initialChatWidth: .35,
          saveDraft: (_) async {},
          updates: updates,
        ),
      );
      await tester.pumpAndSettle();
      // The window picture is made by the engine, outside the test's clock.
      Future<void> settle(Finder until) async {
        for (var i = 0; i < 100 && until.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      Future<void> stopAndSave() async {
        await tester.tap(find.byTooltip('Recording. Stop and save'));
        await settle(find.text('Save report'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save on server'));
        await tester.pumpAndSettle();
      }

      await tester.tap(find.byTooltip('Record a bug or request'));
      await tester.pump();
      await stopAndSave();
      expect(f.bugReport!['client'], {
        'app': 'Stable 0.0.1',
        'window': '1200 × 800',
        'chatOpen': false,
        'chatOnly': false,
        'chatWidth': .35,
        'deviceId': 'device',
        'windowId': f.w.windowId,
        'provider': <String, dynamic>{},
      });
      // The record button is not a menu use; its stop is marked instead.
      final events = (f.bugReport!['events'] as List).cast<Map>();
      expect(events.where((e) => e['name'] == 'menu'), isEmpty);
      expect(events.where((e) => e['name'] == 'stop pressed'), hasLength(1));

      final banner = find.byType(MaterialBanner);
      expect(banner, findsNothing);
      f.offline = true;
      await tester.tap(find.byTooltip('Record a bug or request'));
      await tester.pump();
      await stopAndSave();
      expect(
        find.descendant(of: banner, matching: find.text('Offline')),
        findsOneWidget,
      );
      expect(f.w.recorder.recording, isTrue, reason: 'the recording goes on');
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(banner, findsNothing);
      expect(f.w.error, isNull);
      f.w.recorder.stop();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Reconnect restarts the workspace, and the banner hides in fullscreen',
    (tester) async {
      final f = Fixture()..offline = true;
      await f.w.start();
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      await tester.pumpAndSettle();
      final banner = find.byType(MaterialBanner);
      expect(
        find.descendant(of: banner, matching: find.text('Offline')),
        findsOneWidget,
      );
      expect(f.w.apps, isEmpty);

      f.offline = false;
      await tester.tap(find.byTooltip('Workspace menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Reconnect'));
      await tester.pumpAndSettle();
      expect(banner, findsNothing);
      expect(f.w.apps, hasLength(3));

      final video = (await f.w.openApp(f.w.apps[0])).page! as FakePage;
      f.w
        ..error = 'Something failed'
        ..pollError = 'Poll failed'
        ..changed();
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: banner, matching: find.text('Something failed')),
        findsOneWidget,
      );
      video
        ..fullScreen = true
        ..changed(false);
      await tester.pumpAndSettle();
      expect(banner, findsNothing);
      video
        ..fullScreen = false
        ..changed(false);
      await tester.pumpAndSettle();
      expect(banner, findsOneWidget);
      // Dismiss clears the poll's error too.
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(banner, findsNothing);
      expect((f.w.error, f.w.pollError), (null, null));
      await tester.pumpWidget(const SizedBox());
    },
  );

  // Probe U7: the shell's part of an update install, with the real install's
  // checks, copy and restart left out.
  testWidgets('installing an update saves the draft and the open tabs first', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final room = await f.w.openApp(f.w.apps[1]);
    await f.w.openApp(f.w.apps[2]);
    final drafts = <String>[];
    Object? lastTab() => (f.stored.last['tabs'] as List).last['appId'];
    // What had been saved when the app would restart.
    (List<String>, Object?)? restarted;
    final updates = _RestartingUpdates(
      () => restarted = (List.of(drafts), lastTab()),
    )..download = File('ready');
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(
        workspace: f.w,
        saveDraft: (text) async => drafts.add(text),
        updates: updates,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Update ready'));
    await tester.pumpAndSettle();
    // Typed just before, so its 300 ms save has not run yet.
    await tester.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'Ask Relay about your workspace…',
      ),
      'Unsent words',
    );
    // A change the workspace has not saved yet.
    f.w.tabs
      ..remove(room)
      ..add(room);
    expect(lastTab(), 'research');
    expect(drafts, isEmpty);
    await tester.tap(find.text('Install and restart'));
    await tester.pump();
    expect(restarted?.$1, ['Unsent words']);
    expect(restarted?.$2, 'room-layout');
    // The typing timer was stopped, so the draft is not saved again.
    await tester.pump(const Duration(seconds: 1));
    expect(drafts, ['Unsent words']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the menu shows the chosen appearance and tab order', (
    tester,
  ) async {
    final f = Fixture(newestTabFirst: true);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(
        workspace: f.w,
        initialThemeMode: ThemeMode.dark,
        saveDraft: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    final newest = find.widgetWithText(CheckboxMenuButton, 'Newest tab first');
    expect(tester.widget<CheckboxMenuButton>(newest).value, isTrue);
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    final checked = find.ancestor(
      of: find.byIcon(Icons.check),
      matching: find.byType(MenuItemButton),
    );
    expect(checked, findsOneWidget);
    expect(find.descendant(of: checked, matching: find.text('Dark')), findsOne);
    await tester.pumpWidget(const SizedBox());
  });
}

/// Updates whose install runs only the shell's preparation, then [restart]
/// where the real install would restart the app.
class _RestartingUpdates extends AppUpdates {
  _RestartingUpdates(this.restart)
    : super(
        origin: Uri.parse('http://localhost'),
        version: '0.0.1',
        directory: Directory.systemTemp,
        client: MockClient((_) async => http.Response('Not found', 404)),
      );
  final VoidCallback restart;
  @override
  Future<void> install(Future<void> Function() preserveDraft) async {
    await preserveDraft();
    restart();
  }
}

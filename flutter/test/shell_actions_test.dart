import 'dart:io' show Directory, File;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/app_library.dart';
import 'package:relay_flutter/app_updates.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/workspace_dialogs.dart';

import 'support/fixture.dart';

void main() {
  testWidgets(
    'closing the report question goes on recording, Discard saves nothing, '
    'and a saved report says where it went',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}),
      );
      await tester.pumpAndSettle();
      // The window picture is made by the engine, outside the test's clock.
      Future<void> stop() async {
        await tester.tap(find.byTooltip('Recording. Stop and save'));
        for (
          var i = 0;
          i < 100 && find.text('Save report').evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pumpAndSettle();
        expect(find.text('Save report'), findsOneWidget);
      }

      await tester.tap(find.byTooltip('Record a bug or request'));
      await tester.pump();
      await stop();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Save report'), findsNothing);
      expect((f.w.recorder.recording, f.bugReport), (true, null));

      await stop();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect((f.w.recorder.recording, f.bugReport), (false, null));

      await tester.tap(find.byTooltip('Record a bug or request'));
      await tester.pump();
      await stop();
      await tester.tap(find.text('Save on server'));
      await tester.pumpAndSettle();
      expect(f.bugReport, isNotNull);
      expect(
        find.text('Report saved: bug-reports/report.json'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the App library lists the apps the server has now', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    // Registered since the workspace last asked: only Research is left.
    f.configApps = [apps[2]];
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'App library'));
    await tester.pumpAndSettle();
    final library = find.byType(AppLibrary);
    expect(
      find.descendant(of: library, matching: find.text('Research')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: library, matching: find.text('Browser')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the update dialog lists test builds, stays open on a click outside and '
    'waits for a running reply',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      f.w.conversationId = 'conversation';
      final updates = AppUpdates(
        origin: Uri.parse('http://localhost'),
        version: '0.0.1',
        directory: Directory.systemTemp,
        client: MockClient(
          (request) async => request.url.path.endsWith('previews.json')
              ? http.Response('Unavailable', 503)
              : http.Response('Not found', 404),
        ),
      )..download = File('ready');
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}, updates: updates),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Workspace menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Update ready'));
      await tester.pumpAndSettle();
      expect(
        find.text('Test build list unavailable. Check the update feed.'),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(UpdateDialog), findsOneWidget);

      final install = find.widgetWithText(FilledButton, 'Install and restart');
      const wait =
          'Wait for the current response or stop it before installing.';
      bool offered() => tester.widget<FilledButton>(install).onPressed != null;
      expect((offered(), find.text(wait).evaluate().length), (true, 0));
      // A running reply's spinner never settles, so this pumps a fixed time.
      f.runs = [
        {'id': 'run', 'status': 'running'},
      ];
      await f.w.refresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect((offered(), find.text(wait).evaluate().length), (false, 1));
      f.runs = [];
      await f.w.refresh();
      await tester.pumpAndSettle();
      expect((offered(), find.text(wait).evaluate().length), (true, 0));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an update restarts only once the server is idle, or unreachable when '
    'returning to stable from another server',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<bool> restarts({
        bool busy = false,
        bool unreachable = false,
        bool returning = false,
        String origin = 'http://localhost',
      }) async {
        final f = Fixture()
          ..desktopBusy = busy
          ..desktopUnreachable = unreachable;
        await f.w.start();
        final updates = _CheckedUpdates(Uri.parse(origin), returning)
          ..download = File('ready');
        await tester.pumpWidget(
          RelayApp(workspace: f.w, saveDraft: (_) async {}, updates: updates),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Workspace menu'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(MenuItemButton, 'Update ready'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Install and restart'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        expect(
          updates.failure == null,
          updates.restarted,
          reason: 'a failed check stops the install',
        );
        return updates.restarted;
      }

      expect(await restarts(), isTrue);
      expect(await restarts(busy: true), isFalse);
      expect(await restarts(unreachable: true), isFalse);
      expect(await restarts(unreachable: true, returning: true), isTrue);
      expect(
        await restarts(
          unreachable: true,
          returning: true,
          origin: 'http://localhost:3250',
        ),
        isFalse,
        reason: 'the update comes from the unreachable server itself',
      );
    },
  );

  testWidgets(
    'a conversation opened from Memory or by forwarding opens chat with an '
    'empty draft',
    (tester) async {
      final f = Fixture()
        ..memories = [
          {
            'id': 'memory',
            'key': 'Desk',
            'content': 'Oak',
            'sourceConversationId': 'source',
          },
        ];
      await f.w.start();
      f.w.bots = [
        {'id': 'helper', 'name': 'Helper'},
      ];
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(
          workspace: f.w,
          initialDraft: 'Old draft',
          initialChatOpen: false,
          saveDraft: (_) async {},
        ),
      );
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('conversation-panel'));
      expect(panel, findsNothing);
      await tester.tap(find.byTooltip('Workspace menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Memory'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open source conversation'));
      await tester.pumpAndSettle();
      expect(f.w.conversationId, 'source');
      expect(panel, findsOneWidget);
      expect(find.text('Old draft'), findsNothing);

      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.hintText == 'Ask Relay about your workspace…',
        ),
        'Unsent words',
      );
      await tester.tap(find.byTooltip('Conversation options'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(MenuItemButton, 'Forward conversation'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Helper').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Forward'));
      await tester.pumpAndSettle();
      expect(find.byType(ForwardDialog), findsNothing);
      expect(f.w.conversationId, 'forwarded');
      expect(find.text('Unsent words'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

/// Updates whose install runs only the shell's preparation, then records
/// whether the app would restart. [returning] stands for a test build whose
/// user chose stable again.
class _CheckedUpdates extends AppUpdates {
  _CheckedUpdates(Uri origin, this.returning)
    : super(
        origin: origin,
        version: '0.0.1',
        directory: Directory.systemTemp,
        client: MockClient((_) async => http.Response('Not found', 404)),
      );
  final bool returning;
  bool restarted = false;
  Object? failure;
  @override
  bool get returningToStable => returning;
  @override
  Future<void> install(Future<void> Function() preserveDraft) async {
    try {
      await preserveDraft();
      restarted = true;
    } catch (e) {
      failure = e;
    }
  }
}

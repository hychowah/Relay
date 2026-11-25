
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/new_tab_page.dart';

import 'support/fake_page.dart';
import 'support/fixture.dart';

void main() {
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
        {
          'id': 'files',
          'name': 'Files',
          'protocolVersion': 2,
          'hasView': false,
        },
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
      expect(picker('Files'), findsNothing);
      expect(f.w.tabs, contains(room));
      expect((room.page as FakePage).disposed, isFalse);
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

  testWidgets('search filters the apps and hides other devices, and Enter '
      'opens the first match', (tester) async {
    final f = Fixture()
      ..devices = [
        {
          'id': 'mac',
          'name': 'Mac',
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
          'tabs': {
            'active': 0,
            'tabs': [
              {'appId': 'browser', 'url': 'https://news.example/'},
            ],
          },
        },
      ];
    await f.w.start();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final devices = find.text("Open Mac's tabs here");
    Future<List<String>> shownFor(String text) async {
      await tester.enterText(search, text);
      await tester.pumpAndSettle();
      return [
        for (final name in ['Browser', 'Room layout', 'Research'])
          if (find
              .descendant(
                of: find.byType(NewTabPage),
                matching: find.text(name),
              )
              .evaluate()
              .isNotEmpty)
            name,
      ];
    }

    expect(devices, findsOneWidget);
    // Descriptions match too.
    expect(await shownFor('FURN'), ['Room layout']);
    expect(devices, findsNothing);
    expect(await shownFor('nothing like it'), isEmpty);
    expect(find.text('No matching apps.'), findsOneWidget);
    expect(await shownFor('  '), ['Browser', 'Room layout', 'Research']);
    expect(devices, findsOneWidget);
    expect(await shownFor('re'), ['Room layout', 'Research']);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(f.w.active?.appId, 'room-layout');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('choosing an app closes chat on a phone and keeps it on the '
      'desktop', (tester) async {
    final f = Fixture();
    await f.w.start();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('conversation-panel'));
    expect(panel, findsOneWidget);
    await tester.enterText(search, 'Room');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(f.w.active?.appId, 'room-layout');
    expect(panel, findsNothing);

    tester.view.physicalSize = const Size(1200, 800);
    f.w.newTab();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Toggle chat'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NewTabPage),
        matching: find.text('Browser'),
      ),
    );
    await tester.pumpAndSettle();
    expect(f.w.active?.appId, 'browser');
    expect(panel, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

/// The new tab page's app search.
final search = find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == 'Search apps',
);

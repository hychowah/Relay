import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/capture_flight.dart';
import 'package:relay_flutter/region_capture.dart';
import 'package:relay_flutter/split_layout.dart';

import 'support/fixture.dart';

void main() {
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

  testWidgets(
    'picking an area moves a phone\'s chat aside until done or the tab '
    'changes, and its attachment stays until a conversation is chosen',
    (tester) async {
      final f = Fixture();
      await f.w.start();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final browser = await f.w.openApp(f.w.apps[0]);
      final room = await f.w.openApp(f.w.apps[1]);
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
      // The snapshot is decoded by the engine, outside the test's clock.
      Future<void> settle(Finder until) async {
        for (var i = 0; i < 30 && until.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pump(const Duration(seconds: 1));
      }

      final panel = find.byKey(const ValueKey('conversation-panel'));
      final picking = find.byType(RegionCapture);
      expect(panel, findsOneWidget);
      await tester.tap(find.byTooltip('Capture an area'));
      await settle(picking);
      expect(picking, findsOneWidget);
      expect(panel, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(panel);
      expect(picking, findsNothing);
      expect(panel, findsOneWidget);

      await tester.tap(find.byTooltip('Capture an area'));
      await settle(picking);
      expect(panel, findsNothing);
      f.w.select(browser);
      await settle(panel);
      expect(picking, findsNothing);
      expect(panel, findsOneWidget);

      tester.view.physicalSize = const Size(1200, 800);
      f.w.select(room);
      await tester.pumpAndSettle();
      final page = tester.getRect(find.text('View Room layout'));
      await tester.tap(find.byTooltip('Capture an area'));
      await settle(picking);
      await tester.dragFrom(
        page.topLeft + const Offset(20, 20),
        const Offset(200, 120),
      );
      await settle(find.byTooltip('Remove screenshot'));
      await tester.pumpAndSettle();
      final attached = find.text('Screenshot · room-layout');
      expect(attached, findsOneWidget);
      await tester.tap(find.byTooltip('Toggle chat'));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      await tester.tap(find.byTooltip('Toggle chat'));
      await tester.pumpAndSettle();
      expect(attached, findsOneWidget);
      await tester.tap(find.byTooltip('New conversation'));
      await tester.pumpAndSettle();
      expect(attached, findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('picking an area from chat only shows the page to pick on', (
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
    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Chat only'));
    await tester.pumpAndSettle();
    expect(f.w.pageShown, isFalse);

    await tester.tap(find.byTooltip('Capture an area'));
    for (
      var i = 0;
      i < 30 && find.byType(RegionCapture).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(f.w.pageShown, isTrue);
    expect(find.byType(RegionCapture), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Capture an area waits while a snapshot is taken, an area is picked or '
    'a reply runs',
    (tester) async {
      final f = await _roomOnDesktop(tester);
      bool enabled() =>
          tester
              .widget<IconButton>(
                find.ancestor(
                  of: find.byTooltip('Capture an area'),
                  matching: find.byType(IconButton),
                ),
              )
              .onPressed !=
          null;
      expect(enabled(), isTrue);
      await tester.tap(find.byTooltip('Capture an area'));
      await tester.pump();
      expect(find.byType(RegionCapture), findsNothing);
      expect(enabled(), isFalse);
      await _settle(tester, find.byType(RegionCapture));
      expect(enabled(), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(enabled(), isTrue);

      f.w.conversationId = 'conversation';
      f.runs = [
        {'id': 'run', 'status': 'running'},
      ];
      await f.w.refresh();
      await tester.pump(const Duration(milliseconds: 100));
      expect(enabled(), isFalse);
      f.runs = [];
      await f.w.refresh();
      await tester.pump(const Duration(milliseconds: 100));
      expect(enabled(), isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a snapshot that arrives after its tab was left shows nothing', (
    tester,
  ) async {
    final f = await _roomOnDesktop(tester, alsoBrowser: true);
    final room = f.w.active!;
    final browser = f.w.tabs.firstWhere((tab) => tab != room);
    await tester.tap(find.byTooltip('Capture an area'));
    await tester.pump();
    f.w.select(browser);
    await _settle(tester, find.byType(RegionCapture));
    f.w.select(room);
    await _settle(tester, find.byType(RegionCapture));
    expect(find.byType(RegionCapture), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a snapshot that cannot be read shows in the banner, and capturing can '
    'start again',
    (tester) async {
      final f = await _roomOnDesktop(tester);
      f.pages.last.frame = Uint8List.fromList([1, 2, 3]);
      await tester.tap(find.byTooltip('Capture an area'));
      await _settle(tester, find.text('Dismiss'));
      expect(f.w.error, isNotNull);
      expect(find.text('Dismiss'), findsOneWidget);
      expect(find.byType(RegionCapture), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byTooltip('Capture an area'),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a sent message takes its attached area along', (tester) async {
    final f = await _roomOnDesktop(tester);
    final page = tester.getRect(find.text('View Room layout'));
    await tester.tap(find.byTooltip('Capture an area'));
    await _settle(tester, find.byType(RegionCapture));
    await tester.dragFrom(
      page.topLeft + const Offset(20, 20),
      const Offset(200, 120),
    );
    await _settle(tester, find.byTooltip('Remove screenshot'));
    await tester.pumpAndSettle();
    expect(find.text('Screenshot · room-layout'), findsOneWidget);
    f.w.provider = {'supportsImageInput': true};
    await tester.enterText(find.byType(EditableText).first, 'What is this?');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect((f.sent!['capture'] as Json)['appId'], 'room-layout');
    expect(find.text('Screenshot · room-layout'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an attached area asks for a model that takes images until '
      'one is chosen', (tester) async {
    final f = await _roomOnDesktop(tester);
    final page = tester.getRect(find.text('View Room layout'));
    await tester.tap(find.byTooltip('Capture an area'));
    await _settle(tester, find.byType(RegionCapture));
    await tester.dragFrom(
      page.topLeft + const Offset(20, 20),
      const Offset(200, 120),
    );
    await _settle(tester, find.byTooltip('Remove screenshot'));
    await tester.pumpAndSettle();
    final ask = find.text('Choose Claude or OpenAI to send this image.');
    expect(ask, findsOneWidget);
    f.w.provider = {'supportsImageInput': true};
    f.w.changed();
    await tester.pumpAndSettle();
    expect(ask, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("picking again ends the last picture's flight at once", (
    tester,
  ) async {
    await _roomOnDesktop(tester);
    final page = tester.getRect(find.text('View Room layout'));
    await tester.tap(find.byTooltip('Capture an area'));
    await _settle(tester, find.byType(RegionCapture));
    await tester.dragFrom(
      page.topLeft + const Offset(20, 20),
      const Offset(200, 120),
    );
    await _settle(tester, find.byTooltip('Remove screenshot'));
    await tester.tap(find.byTooltip('Capture an area'));
    await _settle(tester, find.byType(RegionCapture));
    expect(find.byType(CaptureFlight), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(CaptureFlight), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("in a split, the area is picked on the selected pane's page "
      'only', (tester) async {
    final f = await _roomOnDesktop(tester, alsoBrowser: true, split: true);
    expect(f.w.shownSplit, isNotNull);
    final page = tester.getRect(find.text('View Room layout'));
    await tester.tap(find.byTooltip('Capture an area'));
    await _settle(tester, find.byType(RegionCapture));
    expect(find.byType(RegionCapture), findsOneWidget);
    expect(
      tester.getRect(find.byType(RegionCapture)).contains(page.center),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });
}

/// The Room app selected in a 1400 x 800 window, its page showing a blue
/// frame to pick from; [alsoBrowser] opens a Browser tab first, and [split]
/// puts the two side by side.
Future<Fixture> _roomOnDesktop(
  WidgetTester tester, {
  bool alsoBrowser = false,
  bool split = false,
}) async {
  final f = Fixture();
  await f.w.start();
  tester.view.physicalSize = const Size(1400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final browser = alsoBrowser ? await f.w.openApp(f.w.apps[0]) : null;
  final room = await f.w.openApp(f.w.apps[1]);
  if (split) {
    f.w.dropInSplit(room, browser!, SplitSide.left);
    f.w.select(room);
  }
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
  return f;
}

/// Pumps until [until] shows, letting the engine decode the snapshot, which
/// happens outside the test's clock.
Future<void> _settle(WidgetTester tester, Finder until) async {
  for (var i = 0; i < 30 && until.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

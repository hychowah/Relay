import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/app_updates.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/region_capture.dart';

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
}

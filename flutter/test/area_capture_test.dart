import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/capture_flight.dart';
import 'package:relay_flutter/region_capture.dart';

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
}

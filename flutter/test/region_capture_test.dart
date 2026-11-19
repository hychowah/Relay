import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/region_capture.dart';

Future<void> show(
  WidgetTester tester,
  ValueChanged<CapturedRegion?> onDone,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.red, BlendMode.src);
  canvas.drawRect(
    const Rect.fromLTWH(50, 0, 50, 50),
    Paint()..color = Colors.blue,
  );
  final picture = recorder.endRecording();
  final image = (await tester.runAsync(() => picture.toImage(100, 50)))!;
  picture.dispose();
  addTearDown(image.dispose);
  // The tab is twice the frame size, so the crop must map back to frame pixels.
  await tester.pumpWidget(
    MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 200,
          height: 100,
          child: RegionCapture(image: image, onDone: onDone),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('dragging over the tab attaches only the selected pixels', (
    tester,
  ) async {
    CapturedRegion? attached;
    await show(tester, (region) => attached = region);
    final area = tester.getRect(find.byType(RegionCapture));
    final gesture = await tester.startGesture(area.center);
    await gesture.moveTo(area.center + const Offset(32, 20));
    await gesture.moveTo(area.bottomRight - const Offset(1, 1));
    await gesture.up();
    // Frames advance the camera flash, which the tool finishes first.
    for (var i = 0; i < 30 && attached == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    // The shell animates the picture from where the area was shown.
    expect(attached!.area, const Rect.fromLTRB(100, 50, 199, 99));
    expect(attached!.source, const Rect.fromLTRB(50, 25, 99.5, 49.5));
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(attached!.png);
      final crop = (await codec.getNextFrame()).image;
      expect(crop.width, 50);
      expect(crop.height, 25);
      final pixels = await crop.toByteData();
      expect(pixels!.getUint8(2), Colors.blue.toARGB32() & 255);
      crop.dispose();
      codec.dispose();
    });
  });

  testWidgets('a click keeps the tool open and Escape cancels it', (
    tester,
  ) async {
    final results = <CapturedRegion?>[];
    await show(tester, results.add);
    await tester.pump();
    await tester.tapAt(
      tester.getRect(find.byType(RegionCapture)).bottomLeft +
          const Offset(10, -10),
    );
    await tester.pump();
    expect(results, isEmpty);
    expect(find.text('Drag over the area to attach'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(results, [null]);
  });
}

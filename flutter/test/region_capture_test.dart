import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/region_capture.dart';

void main() {
  testWidgets(
    'dragging over the displayed frame attaches only the selected pixels',
    (tester) async {
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
      Uint8List? attached;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                attached = await showDialog<Uint8List>(
                  context: context,
                  builder: (_) => RegionCapture(image: image),
                );
              },
              child: const Text('Capture'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Capture'));
      await tester.pumpAndSettle();
      final area = tester.getRect(find.byType(RawImage));
      final start = area.center;
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(start + const Offset(32, 20));
      await gesture.moveTo(area.bottomRight - const Offset(1, 1));
      await gesture.up();
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Attach'));
      for (var i = 0; i < 30 && attached == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(attached, isNotNull);
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(attached!);
        final crop = (await codec.getNextFrame()).image;
        expect(crop.width, 50);
        expect(crop.height, 25);
        final pixels = await crop.toByteData();
        expect(pixels!.getUint8(2), Colors.blue.toARGB32() & 255);
        crop.dispose();
        codec.dispose();
      });
      await tester.pumpAndSettle();
    },
  );
}

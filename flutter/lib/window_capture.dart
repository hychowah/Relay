import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'page_surface.dart';
import 'region_capture.dart';

/// The longest side of a window picture, in pixels. Text stays readable and a
/// bug report stays a few megabytes.
const maxCaptureSide = 2000.0;

/// Marks the part of the app that [captureWindow] pictures.
class WindowCapture extends StatefulWidget {
  const WindowCapture({super.key, required this.child});
  final Widget child;
  @override
  State<WindowCapture> createState() => _WindowCaptureState();
}

class _WindowCaptureState extends State<WindowCapture> {
  final boundary = GlobalKey();
  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: boundary, child: widget.child);
}

/// Shows [page]. Flutter's own picture of the window leaves native pages out,
/// so while [captureWindow] runs, the slot paints the page's snapshot under
/// the page. Being under it, the snapshot should stay hidden on screen and
/// leave the page its mouse input; Flutter drawn over the page, such as a
/// Browser comment, stays on top in the picture.
class PageSlot extends StatefulWidget {
  const PageSlot({super.key, required this.page});
  final PageSurface page;
  @override
  State<PageSlot> createState() => _PageSlotState();
}

class _PageSlotState extends State<PageSlot> {
  // Null outside a capture; a null frame means the page was not captured.
  ({ui.Image? frame})? capture;

  void show(({ui.Image? frame})? value) => setState(() => capture = value);

  @override
  Widget build(BuildContext context) => MetaData(
    metaData: this,
    // A fixed child list, so a capture never recreates the native page.
    child: Stack(
      fit: StackFit.expand,
      children: [
        switch (capture) {
          null => const SizedBox.shrink(),
          (frame: final frame?) => RawImage(image: frame, fit: BoxFit.fill),
          (frame: null) => const ColoredBox(
            color: Color(0xffd4d4d4),
            child: Center(
              child: Text(
                'Page not captured',
                style: TextStyle(color: Color(0xff4a524e), fontSize: 15),
              ),
            ),
          ),
        },
        widget.page.widget,
      ],
    ),
  );
}

/// A PNG of the window around [context], or null without a [WindowCapture].
Future<Uint8List?> captureWindow(BuildContext context) async {
  final root = context
      .findAncestorStateOfType<_WindowCaptureState>()
      ?.boundary
      .currentContext
      ?.findRenderObject();
  if (root is! RenderRepaintBoundary) return null;
  final ratio = math.min(
    View.of(context).devicePixelRatio,
    maxCaptureSide / root.size.longestSide,
  );
  final slots = <_PageSlotState>[];
  void visit(RenderObject node) {
    if (node is RenderOffstage && node.offstage) return;
    if (node case RenderMetaData(:final _PageSlotState metaData)) {
      slots.add(metaData);
    }
    node.visitChildren(visit);
  }

  root.visitChildren(visit);
  final frames = <ui.Image>[];
  try {
    for (final slot in slots) {
      ui.Image? frame;
      if (slot.widget.page.canCapture) {
        try {
          frame = await decodeFrame(await slot.widget.page.snapshot());
          frames.add(frame);
        } catch (_) {
          /* Shown as not captured. */
        }
      }
      if (slot.mounted) slot.show((frame: frame));
    }
    await WidgetsBinding.instance.endOfFrame;
    final image = await root.toImage(pixelRatio: ratio);
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    for (final slot in slots) {
      if (slot.mounted) slot.show(null);
    }
    // The slots' images hold their own handles.
    for (final frame in frames) {
      frame.dispose();
    }
  }
}

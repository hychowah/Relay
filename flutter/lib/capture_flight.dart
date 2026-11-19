import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// Carries a captured area from the page into the composer: the picture
/// lifts off where it was selected, then travels to [slot] and shrinks to fit.
///
/// It belongs in an overlay that fills the window, so global positions are
/// its own. Only painting runs per frame: one controller repaints one layer,
/// and the picture is drawn from the frame already on the GPU.
class CaptureFlight extends StatefulWidget {
  const CaptureFlight({
    super.key,
    required this.frame,
    required this.source,
    required this.from,
    required this.slot,
    required this.onLanded,
  });

  /// The frozen tab. This widget owns it and disposes it.
  final ui.Image frame;

  /// The selected part of [frame], in its pixels.
  final Rect source;

  /// Where that part was shown, in global coordinates.
  final Rect from;

  /// The widget whose box the picture lands in.
  final GlobalKey slot;
  final VoidCallback onLanded;

  @override
  State<CaptureFlight> createState() => _CaptureFlightState();
}

class _CaptureFlightState extends State<CaptureFlight>
    with SingleTickerProviderStateMixin {
  late final flight = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );
  Rect? lastSlot;

  @override
  void initState() {
    super.initState();
    flight.forward().whenComplete(widget.onLanded);
  }

  @override
  void dispose() {
    flight.dispose();
    widget.frame.dispose();
    super.dispose();
  }

  /// Read on every frame, because a phone's chat sheet is still sliding in
  /// while the picture travels. A slot that has gone keeps its last place.
  Rect _slot() {
    final box = widget.slot.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      lastSlot = box.localToGlobal(Offset.zero) & box.size;
    }
    return lastSlot ?? widget.from;
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _Flight(
          flight,
          widget.frame,
          widget.source,
          widget.from,
          _slot,
        ),
      ),
    ),
  );
}

class _Flight extends CustomPainter {
  _Flight(this.flight, this.frame, this.source, this.from, this.slot)
    : super(repaint: flight);
  final Animation<double> flight;
  final ui.Image frame;
  final Rect source, from;
  final Rect Function() slot;
  final picture = Paint()..filterQuality = FilterQuality.medium;
  final shadow = Paint();
  final edge = Paint()..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final t = flight.value;
    // The picture is picked up first, then carried.
    final pick = Curves.easeOut.transform((t / .2).clamp(0, 1));
    final move = Curves.easeInOutCubic.transform(((t - .12) / .88).clamp(0, 1));
    final held = pick * (1 - move * move);
    final box = slot();
    // It lands exactly where the composer's thumbnail sits inside the slot.
    final to = Alignment.center.inscribe(
      applyBoxFit(BoxFit.contain, from.size, box.size).destination,
      box,
    );
    final distance = (to.center - from.center).distance;
    final rise = math.min(36.0, distance * .08) * math.sin(math.pi * move);
    final rect = Rect.lerp(from, to, move)!
        .shift(Offset(0, -rise))
        .inflate(from.shortestSide * .02 * pick * (1 - move));
    if (held > 0) {
      canvas.drawRect(
        rect.shift(Offset(0, 8 * held)),
        shadow
          ..color = Color.fromRGBO(16, 40, 32, .34 * held)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 + 10 * held),
      );
    }
    canvas.drawImageRect(frame, source, rect, picture);
    // The selection's white outline travels with it and fades on the way.
    if (move < 1) {
      canvas.drawRect(
        rect,
        edge
          ..strokeWidth = 1.5
          ..color = Color.fromRGBO(255, 255, 255, 1 - move),
      );
    }
  }

  @override
  bool shouldRepaint(_Flight old) => false;
}

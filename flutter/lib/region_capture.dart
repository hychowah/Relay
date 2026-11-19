import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

Future<ui.Image> decodeFrame(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// Fills the tab with a frozen frame so the crop matches what the user saw.
/// Releasing a drag reports the selected pixels as a PNG; null means cancelled.
class RegionCapture extends StatefulWidget {
  const RegionCapture({super.key, required this.image, required this.onDone});
  final ui.Image image;
  final ValueChanged<Uint8List?> onDone;

  @override
  State<RegionCapture> createState() => _RegionCaptureState();
}

class _RegionCaptureState extends State<RegionCapture> {
  final focus = FocusNode(debugLabel: 'region capture');
  Offset? start;
  Rect? selection;
  bool cropping = false;
  String? error;

  @override
  void initState() {
    super.initState();
    // Escape must reach this tool even when the chat draft had the keyboard.
    focus.requestFocus();
  }

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  Future<void> attach(Size display) async {
    final bounds = selection!;
    setState(() => cropping = true);
    final image = widget.image;
    final source = Rect.fromLTRB(
      bounds.left * image.width / display.width,
      bounds.top * image.height / display.height,
      bounds.right * image.width / display.width,
      bounds.bottom * image.height / display.height,
    );
    final size = Size(
      source.width.ceilToDouble(),
      source.height.ceilToDouble(),
    );
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(image, source, Offset.zero & size, Paint());
    final picture = recorder.endRecording();
    try {
      final crop = await picture.toImage(
        size.width.toInt(),
        size.height.toInt(),
      );
      try {
        final data = await crop.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('Could not encode the screenshot.');
        if (mounted) {
          widget.onDone(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
        }
      } finally {
        crop.dispose();
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          cropping = false;
          selection = null;
          error = failure.toString();
        });
      }
    } finally {
      picture.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, space) {
      final size = space.biggest;
      final area = Offset.zero & size;
      return Focus(
        focusNode: focus,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent ||
              event.logicalKey != LogicalKeyboardKey.escape) {
            return KeyEventResult.ignored;
          }
          widget.onDone(null);
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: AbsorbPointer(
            absorbing: cropping,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (e) => setState(() {
                start = e.localPosition;
                selection = null;
              }),
              onPanUpdate: (e) => setState(
                () => selection = Rect.fromPoints(
                  start!,
                  e.localPosition,
                ).intersect(area),
              ),
              onPanEnd: (_) {
                if ((selection?.shortestSide ?? 0) >= 4) {
                  attach(size);
                } else {
                  setState(() => selection = null);
                }
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RawImage(
                    image: widget.image,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                  ),
                  CustomPaint(painter: _Shade(selection)),
                  if (selection == null)
                    Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Material(
                          elevation: 7,
                          color: const Color(0xff20342e),
                          shadowColor: const Color(0x66102820),
                          borderRadius: BorderRadius.circular(18),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 2, 6, 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    error ?? 'Drag over the area to attach',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                TextButton(
                                  onPressed: () => widget.onDone(null),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.white70,
                                  ),
                                  child: const Text('Cancel'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Dims the frame outside the selection so the chosen area stands out.
class _Shade extends CustomPainter {
  const _Shade(this.selection);
  final Rect? selection;

  @override
  void paint(Canvas canvas, Size size) {
    final page = Offset.zero & size;
    final rect = selection;
    if (rect == null) {
      canvas.drawRect(page, Paint()..color = const Color(0x2e102820));
      return;
    }
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(page)
        ..addRect(rect),
      Paint()..color = const Color(0x73102820),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_Shade old) => old.selection != selection;
}

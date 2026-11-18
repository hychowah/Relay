import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// Select against a frozen frame so the crop matches what the user saw.
class RegionCapture extends StatefulWidget {
  const RegionCapture({super.key, required this.image});
  final ui.Image image;

  @override
  State<RegionCapture> createState() => _RegionCaptureState();
}

class _RegionCaptureState extends State<RegionCapture> {
  Offset? start;
  Rect? selection;
  bool cropping = false;

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
          Navigator.pop(
            context,
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
        }
      } finally {
        crop.dispose();
      }
    } catch (error) {
      if (mounted) {
        setState(() => cropping = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      picture.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, space) {
          final size = applyBoxFit(
            BoxFit.contain,
            Size(widget.image.width.toDouble(), widget.image.height.toDouble()),
            Size(
              space.maxWidth,
              (space.maxHeight - 56).clamp(1, double.infinity),
            ),
          ).destination;
          final area = Offset.zero & size;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.precise,
                child: GestureDetector(
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
                  child: SizedBox.fromSize(
                    size: size,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: RawImage(
                            image: widget.image,
                            fit: BoxFit.fill,
                          ),
                        ),
                        if (selection case final rect? when !rect.isEmpty)
                          Positioned.fromRect(
                            rect: rect,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Colors.lightBlueAccent,
                                  width: 2,
                                ),
                                color: Colors.blue.withValues(alpha: 0.12),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  const Expanded(child: Text('Drag over the area to attach.')),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: !cropping && (selection?.shortestSide ?? 0) >= 2
                        ? () => attach(size)
                        : null,
                    child: const Text('Attach'),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    ),
  );
}

Future<Uint8List?> selectRegion(BuildContext context, Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final ui.Image image;
  try {
    image = (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
  if (!context.mounted) {
    image.dispose();
    return null;
  }
  try {
    final route = DialogRoute<Uint8List>(
      context: context,
      builder: (_) => RegionCapture(image: image),
    );
    final selection = await Navigator.of(
      context,
      rootNavigator: true,
    ).push(route);
    await route.completed;
    return selection;
  } finally {
    image.dispose();
  }
}

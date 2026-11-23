// Desktop only (macOS): the card shown while the pointer rests on a tab.
import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'page_surface.dart';
import 'tab_memory.dart';
import 'workspace.dart';

/// A tab's title, a small picture of its page and the memory it uses. Each
/// card captures the picture and reads the memory once when it opens; the
/// picture stays only in this card's memory. A tab on screen [shown] needs
/// no picture, and an unloaded tab has neither.
class TabPreview extends StatefulWidget {
  const TabPreview({
    super.key,
    required this.tab,
    required this.shown,
    required this.read,
  });
  final WorkspaceTab tab;
  final bool shown;

  /// Reads the memory of every loaded tab.
  final Future<MemoryReading> Function() read;

  @override
  State<TabPreview> createState() => _TabPreviewState();
}

class _TabPreviewState extends State<TabPreview> {
  late final PageSurface? page = widget.tab.unloaded == null
      ? widget.tab.page
      : null;
  late final Future<Uint8List?> picture = page == null || widget.shown
      ? Future.value()
      : page!.preview().catchError((_) => null);
  late final Future<MemoryReading?> memory = page == null
      ? Future.value()
      : widget.read().then<MemoryReading?>((r) => r, onError: (_) => null);

  // Flutter's image cache would keep every hover's picture; the card takes
  // its own out when it closes.
  ImageProvider? image;

  @override
  void dispose() {
    unawaited(image?.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 11, color: colors.onSurfaceVariant);
    return SizedBox(
      width: 240,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          Text(
            widget.tab.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          if (page != null && !widget.shown)
            FutureBuilder(
              future: picture,
              builder: (context, shot) => switch (shot.data) {
                final bytes? => ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image(
                    image: image ??= ResizeImage(
                      MemoryImage(bytes),
                      width: (240 * MediaQuery.devicePixelRatioOf(context))
                          .round(),
                    ),
                    width: 240,
                    height: 135,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                  ),
                ),
                null when shot.connectionState == ConnectionState.done =>
                  const SizedBox.shrink(),
                null => Container(
                  height: 135,
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              },
            ),
          if (widget.tab.unloaded != null)
            Text(
              widget.tab.reloading != null
                  ? 'Loading again…'
                  : widget.tab.error ??
                        'Unloaded to free memory; click to load it again.',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: small,
            )
          else if (page != null)
            FutureBuilder(
              future: memory,
              builder: (context, reading) => switch (reading.data) {
                final r? when r.pages.containsKey(page) => Text(
                  'Memory ${memoryText(r.pages[page]!.bytes)} · all pages '
                  '${memoryText(_pages(r))} · Relay ${memoryText(r.app)}',
                  style: small,
                ),
                _ => const SizedBox.shrink(),
              },
            ),
        ],
      ),
    );
  }

  /// All pages' memory, counting a shared process once.
  static int _pages(MemoryReading reading) =>
      {for (final use in reading.pages.values) use.process: use.bytes}.values
          .fold(0, (sum, bytes) => sum + bytes);
}

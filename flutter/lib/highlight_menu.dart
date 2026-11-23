import 'package:material_ui/material_ui.dart';

import 'workspace_style.dart';

/// The colours a highlight can have, in the menu's order. Kept in step with
/// page_highlights.js, BrowserPDF.swift and the server's highlightColors.
const highlightColors = {
  'yellow': Color(0xffffd60a),
  'green': Color(0xff34c759),
  'blue': Color(0xff0a84ff),
  'pink': Color(0xffff375f),
  'purple': Color(0xffaf52de),
};

/// Desktop only. Relay's menu by the text selected in a Browser tab, with a
/// button for each colour, or by a highlight the user clicked, with its
/// colour marked and a Remove button. Drawn by Relay over the page, so a
/// page's own scripts cannot press it.
class HighlightMenu extends StatelessWidget {
  const HighlightMenu({
    super.key,
    required this.at,
    required this.onColor,
    required this.onDismiss,
    this.color,
    this.onRemove,
  });

  /// The selected text or the highlight, in the page's logical pixels.
  final Rect at;

  /// The clicked highlight's colour; null for selected text.
  final String? color;
  final ValueChanged<String> onColor;
  final VoidCallback? onRemove;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CustomSingleChildLayout(
      delegate: _Beside(at),
      child: TapRegion(
        onTapOutside: (_) => onDismiss(),
        child: Material(
          elevation: 6,
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final MapEntry(key: name, value: shade)
                    in highlightColors.entries)
                  IconButton(
                    tooltip: color == null
                        ? 'Highlight in $name'
                        : name == color
                        ? 'Highlighted in $name'
                        : 'Change to $name',
                    onPressed: name == color ? null : () => onColor(name),
                    icon: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: shade,
                        shape: BoxShape.circle,
                        border: Border.all(color: colors.outline, width: .5),
                      ),
                      child: name == color
                          ? const Icon(
                              Icons.check,
                              size: 14,
                              color: Colors.black,
                            )
                          : null,
                    ),
                  ),
                if (onRemove != null) ...[
                  SizedBox(
                    height: 24,
                    child: VerticalDivider(
                      width: 9,
                      color: colors.outlineVariant,
                    ),
                  ),
                  ConfirmDeleteButton(
                    tooltip: 'Remove highlight',
                    label: 'Remove',
                    onConfirmed: onRemove,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Puts the menu above [at], or below it when there is no room, and keeps it
/// inside the page.
class _Beside extends SingleChildLayoutDelegate {
  _Beside(this.at);
  final Rect at;
  static const gap = 8.0, edge = 4.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size child) {
    final right = size.width - child.width - edge;
    final x = right < edge
        ? edge
        : (at.center.dx - child.width / 2).clamp(edge, right).toDouble();
    final above = at.top - gap - child.height;
    final below = at.bottom + gap;
    final y = above >= edge
        ? above
        : below + child.height <= size.height - edge
        ? below
        : edge;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_Beside old) => old.at != at;
}

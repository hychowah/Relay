import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'workspace.dart';

/// The icon that stands for [tab] wherever it is listed: a Browser tab's site
/// icon once loaded, else the globe; an app's grid; a new tab's plus. A VPN
/// tab carries a small lock in its corner on macOS, the one platform that
/// opens VPN tabs; elsewhere a VPN tab copied from a Mac loads as a normal
/// one. A site icon keeps its own colours; the others follow [selected].
class TabIcon extends StatelessWidget {
  const TabIcon(
    this.tab, {
    super.key,
    required this.size,
    this.selected = false,
  });
  final WorkspaceTab tab;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = selected ? colors.primary : colors.onSurfaceVariant;
    Widget symbol(IconData icon) => Icon(icon, size: size, color: color);
    final image = tab.isBrowser ? tab.icon : null;
    final icon = image != null
        ? Image.memory(
            image,
            width: size,
            height: size,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => symbol(Icons.language),
          )
        : symbol(
            tab.isBrowser
                ? Icons.language
                : tab.appId == null
                ? Icons.add
                : Icons.grid_view_rounded,
          );
    if (!tab.isBrowser ||
        !tab.vpn ||
        defaultTargetPlatform != TargetPlatform.macOS) {
      return icon;
    }
    // The lock keeps its colour on a tab that is not selected, so the mode
    // stands out.
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          icon,
          Positioned(
            right: -3,
            bottom: -3,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(1),
                child: Icon(
                  Icons.lock,
                  size: size * .55,
                  color: colors.primary,
                  semanticLabel: 'VPN',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

// Relay's own colours. Widgets read them from the theme's ColorScheme so they
// follow the light or dark setting: ink is onSurface, muted onSurfaceVariant,
// accent primary, canvas surfaceContainerHighest, aside surfaceContainerHigh,
// line outline, tint primaryContainer and failed errorContainer.
typedef _Palette = ({
  Color ink,
  Color muted,
  Color accent,
  Color onAccent,
  Color canvas,
  Color surface,
  Color aside,
  Color line,
  Color tint,
  Color failed,
});

const _Palette _light = (
  ink: Color(0xff23312e),
  muted: Color(0xff75807b),
  accent: Color(0xff386b59),
  onAccent: Colors.white,
  canvas: Color(0xfff7f8f6),
  surface: Colors.white,
  aside: Color(0xffedf0ec),
  line: Color(0xffe5e9e4),
  tint: Color(0xffedf3ee),
  failed: Color(0xfffff1ed),
);

const _Palette _dark = (
  ink: Color(0xffe2e8e4),
  muted: Color(0xff939e99),
  accent: Color(0xff7fc2a6),
  onAccent: Color(0xff10241b),
  canvas: Color(0xff141917),
  surface: Color(0xff1b211f),
  aside: Color(0xff262e2b),
  line: Color(0xff2f3834),
  tint: Color(0xff213129),
  failed: Color(0xff3a2622),
);

ThemeData workspaceTheme(Brightness brightness) {
  final (
    :ink,
    :muted,
    :accent,
    :onAccent,
    :canvas,
    :surface,
    :aside,
    :line,
    :tint,
    :failed,
  ) = brightness == Brightness.dark
      ? _dark
      : _light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: _light.accent,
        brightness: brightness,
      ).copyWith(
        primary: accent,
        onPrimary: onAccent,
        primaryContainer: tint,
        errorContainer: failed,
        surface: surface,
        onSurface: ink,
        onSurfaceVariant: muted,
        outline: line,
        outlineVariant: line,
        surfaceContainerHighest: canvas,
        surfaceContainerHigh: aside,
      );
  final base = ThemeData(
    colorScheme: scheme,
    fontFamily: '.AppleSystemUIFont',
    fontFamilyFallback: const ['Helvetica Neue', 'Arial', 'sans-serif'],
    scaffoldBackgroundColor: canvas,
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide(color: line),
  );
  return base.copyWith(
    textTheme: base.textTheme
        .copyWith(
          bodyLarge: TextStyle(fontSize: 14, height: 1.55, color: ink),
          bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: ink),
          bodySmall: TextStyle(fontSize: 12, height: 1.45, color: muted),
          titleLarge: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: ink,
            letterSpacing: -.4,
          ),
          titleMedium: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
          titleSmall: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
          labelLarge: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: ink,
          ),
          headlineMedium: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w600,
            height: 1.2,
            letterSpacing: -.8,
            color: ink,
          ),
        )
        .apply(fontFamily: '.AppleSystemUIFont'),
    iconTheme: IconThemeData(size: 18, color: muted),
    dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: muted,
        minimumSize: const Size(32, 32),
        padding: const EdgeInsets.all(6),
        iconSize: 18,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: canvas,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: BorderSide(color: accent)),
      labelStyle: TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontSize: 13,
        color: muted,
      ),
      hintStyle: TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontSize: 14,
        color: muted,
      ),
      floatingLabelBehavior: FloatingLabelBehavior.always,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: line),
      ),
      titleTextStyle: TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      contentTextStyle: TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontSize: 14,
        height: 1.5,
        color: ink,
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        elevation: const WidgetStatePropertyAll(8),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: line),
          ),
        ),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontFamily: '.AppleSystemUIFont', fontSize: 13),
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? muted.withValues(alpha: .5)
              : ink,
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(210, 36)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: muted,
      selectedColor: accent,
      selectedTileColor: tint,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      titleTextStyle: TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: ink,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontSize: 12,
        height: 1.5,
        color: muted,
      ),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      tilePadding: const EdgeInsets.symmetric(horizontal: 10),
      childrenPadding: const EdgeInsets.all(12),
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: muted,
      collapsedIconColor: muted,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      decoration: BoxDecoration(
        color: ink,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: TextStyle(
        fontFamily: '.AppleSystemUIFont',
        color: surface,
        fontSize: 12,
      ),
    ),
  );
}

/// The `relay.theme` payload an app view receives (docs/integration.md).
Map<String, Object> appTheme(ThemeData theme) {
  final colors = theme.colorScheme;
  String hex(Color color) =>
      '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
  return {
    'mode': theme.brightness.name,
    'colors': {
      'background': hex(colors.surfaceContainerHighest),
      'surface': hex(colors.surface),
      'raised': hex(colors.surfaceContainerHigh),
      'text': hex(colors.onSurface),
      'muted': hex(colors.onSurfaceVariant),
      'accent': hex(colors.primary),
      'onAccent': hex(colors.onPrimary),
      'line': hex(colors.outline),
      'tint': hex(colors.primaryContainer),
      'danger': hex(colors.error),
    },
    'font': '-apple-system, system-ui, "Helvetica Neue", Arial, sans-serif',
    'monoFont': 'ui-monospace, Menlo, monospace',
  };
}

class RelayMark extends StatelessWidget {
  const RelayMark({super.key, this.size = 26});
  final double size;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.primary,
        borderRadius: BorderRadius.circular(size * .3),
      ),
      child: Icon(
        Icons.auto_awesome,
        size: size * .58,
        color: colors.onPrimary,
      ),
    );
  }
}

class MenuLabel extends StatelessWidget {
  const MenuLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
    child: Text(
      text,
      style: TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.1,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// From this width the workspace is a desktop's: chat docks beside the page,
/// tabs split and drag, and controls keep their compact size. Narrower is a
/// phone's.
const wideWorkspace = 900.0;

Duration workspaceMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 220);

/// How long ago [time] was, such as "24 min ago".
String timeAgo(DateTime time) {
  final minutes = DateTime.now().difference(time).inMinutes;
  if (minutes < 1) return 'just now';
  if (minutes < 60) return '$minutes min ago';
  if (minutes < 24 * 60) return '${minutes ~/ 60} h ago';
  return '${minutes ~/ (24 * 60)} days ago';
}

/// A trash button that asks for a second click instead of opening a dialog.
/// The first click turns it into a red button that grows to the left, so the
/// pointer is still on it for the second click. A click soon after arming is
/// ignored, so a double-click does not delete. A tap elsewhere or Escape
/// cancels.
class ConfirmDeleteButton extends StatefulWidget {
  const ConfirmDeleteButton({
    super.key,
    required this.tooltip,
    required this.label,
    required this.onConfirmed,
  });
  final String tooltip, label;
  final VoidCallback? onConfirmed;
  @override
  State<ConfirmDeleteButton> createState() => _ConfirmDeleteButtonState();
}

class _ConfirmDeleteButtonState extends State<ConfirmDeleteButton> {
  final focus = FocusNode();
  bool armed = false;
  Timer? settling;

  @override
  void dispose() {
    settling?.cancel();
    focus.dispose();
    super.dispose();
  }

  void disarm() {
    if (armed) setState(() => armed = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final onConfirmed = widget.onConfirmed;
    final showConfirm = armed && onConfirmed != null;
    return TapRegion(
      onTapOutside: (_) => disarm(),
      child: CallbackShortcuts(
        bindings: {
          if (showConfirm)
            const SingleActivator(LogicalKeyboardKey.escape): disarm,
        },
        child: AnimatedSize(
          duration: workspaceMotion(context),
          curve: Curves.easeOut,
          alignment: Alignment.centerRight,
          child: showConfirm
              ? FilledButton.icon(
                  focusNode: focus,
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.error,
                    foregroundColor: colors.onError,
                    minimumSize: const Size(40, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: () {
                    if (settling?.isActive ?? false) return;
                    setState(() => armed = false);
                    onConfirmed();
                  },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: Text(widget.label),
                )
              : IconButton(
                  tooltip: widget.tooltip,
                  onPressed: onConfirmed == null
                      ? null
                      : () {
                          setState(() => armed = true);
                          settling?.cancel();
                          settling = Timer(
                            const Duration(milliseconds: 400),
                            () {},
                          );
                          focus.requestFocus();
                        },
                  icon: const Icon(Icons.delete_outline),
                ),
        ),
      ),
    );
  }
}

import 'package:material_ui/material_ui.dart';

const ink = Color(0xff23312e);
const muted = Color(0xff75807b);
const accent = Color(0xff386b59);
const canvas = Color(0xfff7f8f6);
const line = Color(0xffe5e9e4);
const tint = Color(0xffedf3ee);

ThemeData workspaceTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: accent).copyWith(
    primary: accent,
    onPrimary: Colors.white,
    surface: Colors.white,
    onSurface: ink,
    onSurfaceVariant: muted,
    outline: line,
    outlineVariant: line,
    surfaceContainerHighest: canvas,
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
    borderSide: const BorderSide(color: line),
  );
  return base.copyWith(
    textTheme: base.textTheme
        .copyWith(
          bodyLarge: const TextStyle(fontSize: 14, height: 1.55, color: ink),
          bodyMedium: const TextStyle(fontSize: 14, height: 1.5, color: ink),
          bodySmall: const TextStyle(fontSize: 12, height: 1.45, color: muted),
          titleLarge: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: ink,
            letterSpacing: -.4,
          ),
          titleMedium: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
          titleSmall: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
          labelLarge: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: ink,
          ),
          headlineMedium: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w600,
            height: 1.2,
            letterSpacing: -.8,
            color: ink,
          ),
        )
        .apply(fontFamily: '.AppleSystemUIFont'),
    iconTheme: const IconThemeData(size: 18, color: muted),
    dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
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
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(color: accent),
      ),
      labelStyle: const TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontSize: 13,
        color: muted,
      ),
      hintStyle: const TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontSize: 14,
        color: muted,
      ),
      floatingLabelBehavior: FloatingLabelBehavior.always,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: line),
      ),
      titleTextStyle: const TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      contentTextStyle: const TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontSize: 14,
        height: 1.5,
        color: ink,
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        elevation: const WidgetStatePropertyAll(8),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: line),
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
    listTileTheme: const ListTileThemeData(
      iconColor: muted,
      selectedColor: accent,
      selectedTileColor: tint,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
    expansionTileTheme: const ExpansionTileThemeData(
      tilePadding: EdgeInsets.symmetric(horizontal: 10),
      childrenPadding: EdgeInsets.all(12),
      shape: Border(),
      collapsedShape: Border(),
      iconColor: muted,
      collapsedIconColor: muted,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      decoration: BoxDecoration(
        color: ink,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: const TextStyle(
        fontFamily: '.AppleSystemUIFont',
        color: Colors.white,
        fontSize: 12,
      ),
    ),
  );
}

class RelayMark extends StatelessWidget {
  const RelayMark({super.key, this.size = 26});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: accent,
      borderRadius: BorderRadius.circular(size * .3),
    ),
    child: Icon(Icons.auto_awesome, size: size * .58, color: Colors.white),
  );
}

class MenuLabel extends StatelessWidget {
  const MenuLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
    child: Text(
      text,
      style: const TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.1,
        color: muted,
      ),
    ),
  );
}

Duration workspaceMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 220);

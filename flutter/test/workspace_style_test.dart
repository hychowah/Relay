import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/workspace_style.dart';

void main() {
  test('appTheme sends the light and dark palettes to app views', () {
    final light = appTheme(workspaceTheme(Brightness.light));
    final dark = appTheme(workspaceTheme(Brightness.dark));
    expect(light['mode'], 'light');
    expect(dark['mode'], 'dark');
    for (final theme in [light, dark]) {
      expect(
        (theme['colors'] as Map).values,
        everyElement(matches(RegExp(r'^#[0-9a-f]{6}$'))),
      );
    }
    expect(light['colors'], isNot(equals(dark['colors'])));
    expect(
      (dark['colors'] as Map).keys,
      unorderedEquals([
        'background',
        'surface',
        'raised',
        'text',
        'muted',
        'accent',
        'onAccent',
        'line',
        'tint',
        'danger',
      ]),
    );
    expect(dark['monoFont'], isA<String>());
  });
}

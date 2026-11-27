import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/tab_icon.dart';
import 'package:relay_flutter/workspace.dart';

// A 1-pixel PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('a Browser tab shows its site icon, a VPN tab a lock on macOS', (
    tester,
  ) async {
    WorkspaceTab tab({bool vpn = false, bool icon = false}) =>
        WorkspaceTab(isBrowser: true, vpn: vpn)
          ..unloaded = (
            url: 'https://site.test/',
            title: 'Site',
            icon: icon ? _png : null,
          );
    Future<void> show(TargetPlatform platform) {
      debugDefaultTargetPlatformOverride = platform;
      return tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              TabIcon(tab(), size: 15),
              TabIcon(tab(icon: true), size: 15),
              TabIcon(tab(vpn: true, icon: true), size: 15),
              TabIcon(WorkspaceTab(appId: 'room'), size: 15),
            ],
          ),
        ),
      );
    }

    await show(TargetPlatform.macOS);
    expect(find.byIcon(Icons.language), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.byIcon(Icons.grid_view_rounded), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget);
    await show(TargetPlatform.windows);
    expect(find.byIcon(Icons.lock), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}

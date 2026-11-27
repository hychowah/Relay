// Desktop only (macOS): a press on a web page or PDF closes Relay's open
// menus, as a press anywhere else in the window does.
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

const _channel = MethodChannel('app.relay/page-press');

/// Desktop only (macOS). Starts listening for the Mac window's page presses.
void listenForPagePresses() =>
    _channel.setMethodCallHandler((call) async {
      final at = call.arguments as Map;
      pagePressed(
        Offset((at['x'] as num).toDouble(), (at['y'] as num).toDouble()),
      );
    });

/// Desktop only (macOS). AppKit gives a press on a page to the page's native
/// view, never to Flutter, so a menu or anything else that waits for a tap
/// outside itself stays open. This gives that press, at [position] in the
/// window's logical pixels, to the window's tap regions only: other widgets
/// under the page never see it.
void pagePressed(Offset position) {
  final binding = WidgetsBinding.instance;
  final view = binding.platformDispatcher.implicitView;
  if (view == null) return;
  final result = HitTestResult();
  binding.hitTestInView(result, position, view.viewId);
  final event = PointerDownEvent(
    viewId: view.viewId,
    position: position,
    kind: PointerDeviceKind.mouse,
  );
  for (final entry in result.path) {
    if (entry.target is RenderTapRegionSurface) {
      entry.target.handleEvent(event.transformed(entry.transform), entry);
    }
  }
}

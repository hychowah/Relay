import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'capture_flight.dart';
import 'chat_dock.dart';
import 'region_capture.dart';
import 'workspace.dart';
import 'workspace_style.dart';

/// An area of the selected app tab on its way to the next message. On a
/// phone the chat sheet steps aside while the user picks. It reads the
/// screen through the shell's context, so a snapshot that arrives after the
/// shell is gone is dropped. Each change notifies its listeners, as the
/// shell's `setState` did when this was its state, so the shell redraws as
/// often as before; change it from events, never during a build.
class AreaCapture extends ChangeNotifier {
  AreaCapture(this._context, this.workspace, this._layout);
  final BuildContext _context;
  final Workspace workspace;
  final ChatLayout _layout;
  Workspace get w => workspace;
  ({String appId, Uint8List bytes})? _capture;
  bool _capturing = false;
  ({WorkspaceTab tab, ui.Image image, bool reopenChat})? _selecting;
  // The composer's thumbnail, and the captured picture on its way there.
  final _captureSlot = GlobalKey();
  OverlayEntry? _flight;

  /// The picked area, attached to the next message.
  ({String appId, Uint8List bytes})? get attachment => _capture;

  /// A snapshot is being taken or the user is picking an area, so another
  /// capture cannot start.
  bool get busy => _capturing || _selecting != null;

  /// The picked area is still flying to the composer's thumbnail, which
  /// stays hidden until it lands.
  bool get flying => _flight != null;

  /// The key of the composer's thumbnail, where the picked area lands.
  GlobalKey get slot => _captureSlot;

  /// The frame of [tab]'s page that the user picks an area on, while they
  /// pick on that tab.
  ui.Image? pickingOn(WorkspaceTab tab) =>
      _selecting?.tab == tab ? _selecting!.image : null;

  /// Capture an area: snapshots the selected app tab's page for the user to
  /// pick an area on. A failure shows in the workspace's banner.
  Future<void> start() async {
    final tab = w.active;
    final page = tab?.page;
    if (tab?.appId == null ||
        page == null ||
        _capturing ||
        _selecting != null) {
      return;
    }
    _capturing = true;
    notifyListeners();
    try {
      final image = await decodeFrame(await page.snapshot());
      if (!_context.mounted || w.active != tab) {
        image.dispose();
        return;
      }
      // A phone's chat sheet covers the page, so step it aside while selecting.
      final phone = MediaQuery.sizeOf(_context).width < wideWorkspace;
      _selecting = (tab: tab!, image: image, reopenChat: phone && _layout.open);
      _layout.showPage(closeChat: phone);
      notifyListeners();
    } catch (error) {
      w.error = error.toString();
      w.changed();
    } finally {
      if (_context.mounted) {
        _capturing = false;
        notifyListeners();
      }
    }
  }

  /// The user picked [region], or none to cancel: chat returns if it stepped
  /// aside, and a picked area flies to the composer's thumbnail.
  void finish(CapturedRegion? region) {
    final current = _selecting;
    if (current == null) return;
    _land();
    _selecting = null;
    if (current.reopenChat) _layout.openChat();
    if (region != null) {
      _capture = (appId: current.tab.appId!, bytes: region.png);
      if (!MediaQuery.disableAnimationsOf(_context)) {
        // The flight keeps its own handle on the frame, so the tool's handle
        // is released as before.
        final frame = current.image.clone();
        _flight = OverlayEntry(
          builder: (_) => CaptureFlight(
            frame: frame,
            source: region.source,
            from: region.area,
            slot: _captureSlot,
            onLanded: _land,
          ),
        );
        Overlay.of(_context).insert(_flight!);
      }
    }
    notifyListeners();
    // Let the overlay leave the tree before its frame is released.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => current.image.dispose(),
    );
  }

  /// Ends the flight; the composer's thumbnail shows from here on.
  void _land() {
    final entry = _flight;
    if (entry == null) return;
    _flight = null;
    notifyListeners();
    entry
      ..remove()
      ..dispose();
  }

  /// Ends a pick once the user selects a tab other than the one picked on.
  void follow(WorkspaceTab? active) {
    if (_selecting != null && active != _selecting!.tab) finish(null);
  }

  /// Remove screenshot, or a conversation was chosen: the attachment goes.
  void remove() {
    _capture = null;
    notifyListeners();
  }

  /// A message with [attachment] was sent: the attachment goes, unless
  /// another one replaced it meanwhile.
  void sent(({String appId, Uint8List bytes})? attachment) {
    if (_capture == attachment) {
      _capture = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _selecting?.image.dispose();
    _flight
      ?..remove()
      ..dispose();
    super.dispose();
  }
}

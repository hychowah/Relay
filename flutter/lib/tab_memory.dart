// Desktop only (macOS): the memory each tab's page uses, shown on its chip
// while "Show tab memory" is on.
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'page_surface.dart';

/// A page's web process and its physical footprint in bytes, the figure
/// Activity Monitor shows as Memory. Pages can share a process.
typedef PageMemory = ({int process, int bytes});

/// Relay's own footprint and each page's, read together.
typedef MemoryReading = ({int app, Map<PageSurface, PageMemory> pages});

String memoryText(int bytes) {
  final mb = bytes / (1 << 20);
  return mb >= 1024
      ? '${(mb / 1024).toStringAsFixed(1)} GB'
      : '${mb.round()} MB';
}

/// While on, reads every two seconds the pages [pages] gives; off, or while
/// Relay is not on screen, it reads nothing. Listeners hear only readings
/// whose shown figures changed.
class TabMemory extends ValueNotifier<MemoryReading?> {
  TabMemory(this._read, this._pages) : super(null);
  final Future<MemoryReading> Function(Iterable<PageSurface>) _read;
  final Iterable<PageSurface> Function() _pages;
  Timer? _timer;
  bool _reading = false;

  bool get on => _timer != null;

  void show(bool on) {
    _timer?.cancel();
    _timer = on
        ? Timer.periodic(const Duration(seconds: 2), (_) => _update())
        : null;
    if (on) {
      unawaited(_update());
    } else {
      value = null;
    }
  }

  Future<void> _update() async {
    final state = WidgetsBinding.instance.lifecycleState;
    if (_reading || (state != null && state != AppLifecycleState.resumed)) {
      return;
    }
    _reading = true;
    try {
      final reading = await _read(_pages());
      if (on && !_sameText(reading)) value = reading;
    } catch (_) {
      // A runner without the native reading.
      show(false);
    } finally {
      _reading = false;
    }
  }

  bool _sameText(MemoryReading reading) {
    final shown = value;
    if (shown == null ||
        memoryText(shown.app) != memoryText(reading.app) ||
        shown.pages.length != reading.pages.length) {
      return false;
    }
    for (final MapEntry(:key, value: use) in reading.pages.entries) {
      final before = shown.pages[key];
      if (before == null || memoryText(before.bytes) != memoryText(use.bytes)) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// The icon a Browser page shows for its site in Relay's tab listings: the
/// first icon the page declares (assets/page_icons.js) that [fetch] returns
/// and Flutter can decode, shrunk to a PNG at most 64 px wide.
///
/// The fetch sends no cookies, and its bytes reach only Relay's tab listings,
/// never the page, so it needs no address rule. A VPN tab's fetch goes
/// through the tab's own route (the Mac runner's BrowserIcon.swift).
class SiteIcon {
  SiteIcon({
    required this.address,
    required this.run,
    required this.fetch,
    required this.changed,
  });

  /// The page's address now.
  final String Function() address;

  /// Runs a script in the page.
  final Future<void> Function(String script) run;

  /// The bytes at an icon's address, or null when it cannot be had.
  final Future<Uint8List?> Function(Uri url) fetch;

  /// Called when [image] changes.
  final void Function() changed;

  static String? _script;
  ({String site, String icons, Uint8List image})? _shown;
  int _reports = 0;

  /// Runs page_icons.js in the page just loaded; it reports through
  /// [reported] now and whenever the page changes its icons.
  Future<void> watch() async {
    try {
      _script ??= await rootBundle.loadString('assets/page_icons.js');
      await run(_script!);
    } catch (_) {
      // The tab keeps its icon, or the globe.
    }
  }

  /// A report from page_icons.js: the message text after `icons:`. Anything
  /// else is ignored. A newer report replaces one still loading.
  Future<void> reported(String message) async {
    final String site, icons;
    final List<Uri> urls;
    try {
      final data = jsonDecode(message) as Map;
      site = _site(data['page'] as String);
      urls = [
        for (final icon in (data['icons'] as List).take(4))
          if (Uri.parse(icon as String) case final url
              when url.isScheme('https') || url.isScheme('http'))
            url,
      ];
      icons = urls.join(' ');
    } catch (_) {
      return;
    }
    if (site != _site(address())) return;
    final report = ++_reports;
    if (_shown case (site: final shown, icons: final same, image: _)
        when shown == site && same == icons) {
      return;
    }
    for (final url in urls) {
      final bytes = await fetch(url);
      final image = bytes == null ? null : await _shrink(bytes);
      if (report != _reports) return;
      if (image != null) {
        _shown = (site: site, icons: icons, image: image);
        changed();
        return;
      }
    }
    if (_shown?.site == site) {
      _shown = null;
      changed();
    }
  }

  /// The icon of the site at [address] now; null (the globe) while none has
  /// loaded for that site.
  Uint8List? get image => switch (_shown) {
    (site: final site, icons: _, image: final image)
        when site == _site(address()) =>
      image,
    _ => null,
  };

  static String _site(String url) => Uri.tryParse(url)?.host ?? '';

  /// [bytes] as a PNG at most 64 px wide, or null when Flutter cannot
  /// decode them (SVG, an HTML error page) or they say they are larger than
  /// any site icon: the codec decodes at full size before it scales, so a
  /// small file claiming 20,000 px a side would take gigabytes.
  static Future<Uint8List?> _shrink(Uint8List bytes) async {
    const largest = 2048;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width > largest || descriptor.height > largest) {
        return null;
      }
      codec = await descriptor.instantiateCodec(
        targetWidth: min(descriptor.width, 64),
      );
      image = (await codec.getNextFrame()).image;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}

/// Fetches [url] on this device's own network, without cookies: at most
/// 512 KB, within 10 s; null on any failure.
Future<Uint8List?> fetchIconDirectly(Uri url) async {
  const largest = 512 * 1024;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    return await () async {
      final response = await (await client.getUrl(url)).close();
      if (response.statusCode < 200 || response.statusCode > 299) return null;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
        if (bytes.length > largest) return null;
      }
      return bytes.takeBytes();
    }().timeout(const Duration(seconds: 10));
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

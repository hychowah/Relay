import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/site_icon.dart';

// A 1-pixel PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

String _report(String page, List<String> icons) =>
    jsonEncode({'page': page, 'icons': icons});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('takes the first declared icon that loads and decodes', () async {
    final fetched = <String>[];
    var changes = 0;
    final icon = SiteIcon(
      address: () => 'https://site.test/news',
      run: (_) async {},
      fetch: (url) async {
        fetched.add('$url');
        return switch (url.path) {
          '/missing.png' => null,
          '/page.png' => utf8.encode('<!doctype html>Not found'),
          _ => _png,
        };
      },
      changed: () => changes++,
    );
    await icon.reported(
      _report('https://site.test/news', [
        'https://site.test/missing.png',
        'https://site.test/page.png',
        'https://site.test/favicon.ico',
        'https://site.test/never.png',
      ]),
    );
    expect(fetched, [
      'https://site.test/missing.png',
      'https://site.test/page.png',
      'https://site.test/favicon.ico',
    ]);
    expect(icon.image?.take(4), [0x89, 0x50, 0x4e, 0x47]);
    expect(changes, 1);

    // The next page of the site declares the same icons: nothing is fetched.
    await icon.reported(
      _report('https://site.test/other', [
        'https://site.test/missing.png',
        'https://site.test/page.png',
        'https://site.test/favicon.ico',
        'https://site.test/never.png',
      ]),
    );
    expect((fetched.length, changes), (3, 1));
  });

  test('an image larger than any site icon gives none', () async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final wide = await recorder.endRecording().toImage(2049, 64);
    final png = await wide.toByteData(format: ui.ImageByteFormat.png);
    final icon = SiteIcon(
      address: () => 'https://site.test/',
      run: (_) async {},
      fetch: (_) async => png!.buffer.asUint8List(),
      changed: () {},
    );
    await icon.reported(
      _report('https://site.test/', ['https://site.test/huge.png']),
    );
    expect(icon.image, isNull);
  });

  test('shows no icon from another site or an earlier report', () async {
    var address = 'https://one.test/';
    final slow = Completer<Uint8List?>();
    final icon = SiteIcon(
      address: () => address,
      run: (_) async {},
      fetch: (url) =>
          url.host == 'slow.test' ? slow.future : Future.value(_png),
      changed: () {},
    );
    await icon.reported(
      _report('https://one.test/', ['https://one.test/a.png']),
    );
    expect(icon.image, isNotNull);

    // The tab moves to another site: the globe shows until its icon loads,
    // and a report from the site before is ignored.
    address = 'https://two.test/';
    expect(icon.image, isNull);
    await icon.reported(
      _report('https://one.test/', ['https://one.test/a.png']),
    );
    expect(icon.image, isNull);

    final earlier = icon.reported(
      _report('https://two.test/', ['https://slow.test/a.png']),
    );
    await icon.reported(
      _report('https://two.test/', ['https://two.test/b.png']),
    );
    final later = icon.image;
    slow.complete(_png);
    await earlier;
    expect(icon.image, allOf(isNotNull, same(later)));
  });
}

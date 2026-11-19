import 'package:flutter_test/flutter_test.dart';

import '../integration_test/memory.dart';

void main() {
  test('attributes only the WebKit services in the app launchd domain', () {
    const launchctl = '''
	services = {
		       0      - 	com.apple.WebKit.WebContent
		     201      - 	com.apple.WebKit.GPU.1A
		     202      - 	com.apple.WebKit.WebContent.2B
		     203      - 	com.apple.SafariPlatformSupport.Helper
	}
''';
    expect(webKitPids(launchctl), [201, 202]);

    const mb = 1 << 20;
    final sample = parseFootprint(100, '''
======================================================================
Relay Flutter [100]: 64-bit    Footprint: ${64 * mb} B (16384 bytes per page)
======================================================================
com.apple.WebKit.GPU [201]: 64-bit    Footprint: ${30 * mb} B (16384 bytes per page)
com.apple.WebKit.WebContent [202]: 64-bit    Footprint: ${90 * mb} B (16384 bytes per page)
Summary Footprint: ${184 * mb} B
''');
    expect(sample, (app: 64.0, webKit: 120.0, webContent: 1));
  });

  test('reports growth after warm-up, not the peak', () {
    MemorySample at(double app, double webKit) =>
        (app: app, webKit: webKit, webContent: 1);
    final summary = memorySummary(
      at(50, 100),
      // Warm-up jumps, then the app grows 2 MB a cycle and WebKit is level.
      [at(80, 200), at(70, 120), at(72, 120), at(74, 120), at(76, 120)],
      others: [at(90, 400)],
    );
    expect(summary['start_mb'], 150);
    expect(summary['peak_mb'], 490);
    expect(summary['end_mb'], 196);
    expect(summary['growth_mb'], 2);
    expect(summary['app_growth_mb'], 2);
    expect(summary['webkit_growth_mb'], 0);
  });
}

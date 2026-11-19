// Memory readings for the Mac stress suite, separate from the test so that
// WSL unit tests can check the parsing and arithmetic.
import 'dart:io';
import 'dart:math';

/// Physical footprint in MB, the figure Activity Monitor shows as Memory, of
/// the app and of the WebKit processes started for it.
typedef MemorySample = ({double app, double webKit, int webContent});

double total(MemorySample sample) => sample.app + sample.webKit;

/// WebKit's GPU, Networking and WebContent processes run as XPC services in
/// the app's own launchd domain, which `launchctl print pid/<pid>` lists
/// without root. Other apps' WebKit processes are in their own domains.
List<int> webKitPids(String launchctl) => [
  for (final match in RegExp(
    r'^\s*(\d+)\s+\S+\s+com\.apple\.WebKit\.',
    multiLine: true,
  ).allMatches(launchctl))
    if (int.parse(match[1]!) > 0) int.parse(match[1]!),
];

/// Reads `footprint -f bytes --noCategories` output. A process that exited
/// between the listing and the reading is simply missing.
MemorySample parseFootprint(int appPid, String footprint) {
  var app = 0.0, webKit = 0.0, webContent = 0;
  for (final match in RegExp(
    r'^(.+) \[(\d+)\]: .*Footprint: (\d+) B',
    multiLine: true,
  ).allMatches(footprint)) {
    final mb = int.parse(match[3]!) / (1 << 20);
    if (int.parse(match[2]!) == appPid) {
      app = mb;
    } else {
      webKit += mb;
      if (match[1]!.endsWith('WebContent')) webContent++;
    }
  }
  return (app: app, webKit: webKit, webContent: webContent);
}

/// Reads this app's memory and that of its WebKit processes.
Future<MemorySample> sampleMemory() async {
  final services = await Process.run('launchctl', ['print', 'pid/$pid']);
  final reading = await Process.run('footprint', [
    '-f',
    'bytes',
    '--noCategories',
    for (final id in [pid, ...webKitPids(services.stdout as String)]) ...[
      '-p',
      '$id',
    ],
  ]);
  return parseFootprint(pid, reading.stdout as String);
}

double _round(num value) => (value * 10).round() / 10;

/// Least-squares slope of [ys] over [xs].
double _slope(List<double> xs, List<double> ys) {
  final mx = xs.reduce((a, b) => a + b) / xs.length;
  final my = ys.reduce((a, b) => a + b) / ys.length;
  var num = 0.0, den = 0.0;
  for (var i = 0; i < xs.length; i++) {
    num += (xs[i] - mx) * (ys[i] - my);
    den += (xs[i] - mx) * (xs[i] - mx);
  }
  return num / den;
}

/// Summarizes a repeated action: [start] before it, [ends] after each cycle
/// at times [at] (cycle numbers, or minutes), and [others] taken during it.
/// Growth is the slope of the end readings after the first [warmUp] of them,
/// so a leak shows as steady growth rather than a high peak. Growth needs at
/// least two readings after the warm-up.
Map<String, num> memorySummary(
  MemorySample start,
  List<MemorySample> ends, {
  List<MemorySample> others = const [],
  List<double>? at,
  int warmUp = 2,
}) {
  final xs = at ?? [for (var i = 1; i <= ends.length; i++) i.toDouble()];
  double growth(double Function(MemorySample) value) => _round(
    _slope(xs.sublist(warmUp), [for (final s in ends.skip(warmUp)) value(s)]),
  );
  return {
    'start_mb': _round(total(start)),
    'peak_mb': _round([start, ...ends, ...others].map(total).reduce(max)),
    'end_mb': _round(total(ends.last)),
    if (ends.length >= warmUp + 2) ...{
      'growth_mb': growth(total),
      'app_growth_mb': growth((s) => s.app),
      'webkit_growth_mb': growth((s) => s.webKit),
    },
    'web_content_end': ends.last.webContent,
  };
}

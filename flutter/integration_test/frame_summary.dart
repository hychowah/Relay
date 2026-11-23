// The per-scenario summary of the Mac performance suites, separate from the
// tests so that WSL unit tests can check its arithmetic.
import 'dart:math';
import 'dart:ui' show FramePhase, FrameTiming;

double _round(num value) => (value * 100).round() / 100;

/// Nearest-rank percentile of sorted microseconds, in milliseconds.
double _percentile(List<int> sorted, double share) =>
    _round(sorted[max(0, (share * sorted.length).ceil() - 1)] / 1000);

/// Summarizes the frames inside each (before, last] frame-number range.
/// Intervals between frames are measured within a range only, where the
/// scenario keeps the UI moving.
Map<String, num> frameSummary(
  List<(int, int)> ranges,
  Map<int, FrameTiming> timings,
  double budgetUs,
) {
  int vsync(FrameTiming frame) =>
      frame.timestampInMicroseconds(FramePhase.vsyncStart);
  final frames = <FrameTiming>[];
  final gaps = <int>[];
  var spanUs = 0;
  for (final (before, last) in ranges) {
    final run = [for (var n = before + 1; n <= last; n++) ?timings[n]];
    frames.addAll(run);
    for (var i = 1; i < run.length; i++) {
      gaps.add(vsync(run[i]) - vsync(run[i - 1]));
    }
    if (run.length > 1) spanUs += vsync(run.last) - vsync(run.first);
  }
  if (gaps.isEmpty) throw StateError('A scenario had no measurable motion.');
  final build = [for (final f in frames) f.buildDuration.inMicroseconds]
    ..sort();
  final raster = [for (final f in frames) f.rasterDuration.inMicroseconds]
    ..sort();
  final slow = frames.where(
    (f) =>
        f.buildDuration.inMicroseconds > budgetUs ||
        f.rasterDuration.inMicroseconds > budgetUs,
  );
  return {
    'frames': frames.length,
    'fps': _round(gaps.length / (spanUs / Duration.microsecondsPerSecond)),
    'slow_frames_percent': _round(100 * slow.length / frames.length),
    'build_ms_median': _percentile(build, .5),
    'build_ms_p90': _percentile(build, .9),
    'raster_ms_median': _percentile(raster, .5),
    'raster_ms_p90': _percentile(raster, .9),
    'gaps_over_25ms': gaps.where((us) => us > 25000).length,
    'worst_gap_ms': _round(gaps.reduce(max) / 1000),
  };
}

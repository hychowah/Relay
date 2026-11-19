import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/frame_summary.dart';

FrameTiming _frame(int number, int vsyncUs, int buildUs, int rasterUs) =>
    FrameTiming(
      frameNumber: number,
      vsyncStart: vsyncUs,
      buildStart: vsyncUs,
      buildFinish: vsyncUs + buildUs,
      rasterStart: vsyncUs + buildUs,
      rasterFinish: vsyncUs + buildUs + rasterUs,
      rasterFinishWallTime: vsyncUs + buildUs + rasterUs,
    );

void main() {
  test('summarizes frames within each motion range only', () {
    // Two motions at 60 Hz; the second has one 50 ms stall and one slow build.
    final timings = {
      for (final frame in [
        _frame(1, 0, 2000, 3000),
        _frame(2, 16667, 2000, 3000),
        _frame(3, 33333, 2000, 3000),
        // Idle between the motions: not an interval within one.
        _frame(10, 1000000, 4000, 5000),
        _frame(11, 1050000, 20000, 5000),
        _frame(12, 1066667, 4000, 5000),
      ])
        frame.frameNumber: frame,
    };
    final summary = frameSummary([(0, 3), (9, 12)], timings, 16667);
    expect(summary['frames'], 6);
    // Four intervals over 33.3 + 66.7 ms.
    expect(summary['fps'], 40);
    expect(summary['slow_frames_percent'], 16.67);
    expect(summary['build_ms_median'], 2);
    expect(summary['build_ms_p90'], 20);
    expect(summary['raster_ms_median'], 3);
    expect(summary['gaps_over_25ms'], 1);
    expect(summary['worst_gap_ms'], 50);
  });
}

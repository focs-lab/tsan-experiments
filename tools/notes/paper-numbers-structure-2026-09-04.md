# What the paper's headline speedups are made of (March artefacts, re-read 2026-09-04)

Re-computed from the artefacts the submitted numbers came from, with the repo's own parsers. Nothing here is a
new measurement; the point is *which test carries each geometric mean* and *how much spread sits under it*. All
four columns are one run per configuration, so no run-to-run interval exists — the ranges below are across
tests, not across repetitions.

## FFmpeg — AllOpt+peel geomean 1.474, and the two real codecs contribute ~1.02

`summary_ffmpeg_benchmark.csv`, speedup vs stock TSan:

| codec | tsan (s) | AllOpt+peel (s) | SU | native (s) | TSan slowdown |
|---|---|---|---|---|---|
| mjpeg | 76.17 | 25.69 | **2.96** | 7.68 | 9.9x |
| copy_passthrough | 2.10 | 1.39 | 1.51 | 0.27 | 7.9x |
| h264_libx264 | 92.22 | 89.11 | 1.03 | 77.43 | 1.19x |
| h265_libx265 | 91.61 | 89.76 | 1.02 | 64.27 | 1.43x |

The geometric mean over the four is 1.474, but the two heavyweight encodes gain 2-3 % and `copy_passthrough`
is a 2.1-second workload. mjpeg carries the headline. Note also where TSan hurts: 9.9x on mjpeg, 1.19x on x264.

## SQLite — AllOpt-peel geomean 2.773, of which `stress1` is most

`results.good.6march`, threadtest3 iteration counts (higher is better):

| subtest | tsan | AllOpt-peel | SU | native | TSan slowdown |
|---|---|---|---|---|---|
| stress1 | 6417 | 140582 | **21.91** | 223422 | 34.8x |
| stress2 | 12536 | 52053 | 4.15 | 128520 | 10.3x |
| checkpoint_starvation_1 | 55417 | 149994 | 2.71 | 302263 | 5.5x |
| dynamic_triggers | 61800 | 118800 | 1.92 | 308200 | 5.0x |
| walthread2 | 3727 | 6066 | 1.63 | 10057 | 2.7x |
| walthread1 | 1779 | 2853 | 1.60 | 4810 | 2.7x |
| checkpoint_starvation_2 | 766 | 782 | 1.02 | 798 | 1.04x |

Geomean 2.773; dropping `stress1` gives 1.965, dropping any other subtest moves it by less than 0.3. Unlike
FFmpeg's `copy_passthrough` this is not a small-count artefact — the counts are large and stock TSan really is
34.8x slower than native there. Worth stating explicitly rather than leaving the reader to assume the gain is
uniform.

## Redis — AllOpt+peel geomean 1.455 with per-test ratios from 0.74 to 3.12

`__results_redis__march6/results.txt`, 19 tests, ratio to stock TSan: `dom` 1.416, `dom_peeling` 1.177,
`ea` 0.966, `lo` 1.059, `st` 1.125, `swmr` 1.055, `stmt` 1.121, AllOpt+peel 1.455 (range [0.74, 3.12]),
AllOpt+peel+DynSTC 1.360. Native is 9.211x stock TSan. Several single analyses land below 1.0 on many tests;
with one run per configuration those are not distinguishable from noise.

## memcached — 1.07 sits inside the single run's own spread

See [memcached-variance-2026-09-04.md](memcached-variance-2026-09-04.md): memtier's five internal iterations
differ by up to 12 %, and the reported 1.07 has an envelope of [1.010, 1.203].

## Why this matters for the revision

Reviewer C asked for run counts and variance. Three of the four application columns are single runs, and in
three of them the geometric mean is carried by one test out of four to nineteen. The P5 re-measurement reports
medians over repetitions with per-test ratios kept visible, so both facts become checkable rather than implicit.

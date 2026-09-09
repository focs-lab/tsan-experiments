# How much foreign load the pinned set tolerates, and why the gate moved from 0.25 to 0.10

**Date** 2026-09-08 · **lane** tsan-exp · **tree** `tools/perf/results/stageB-d3bf9f8c39fe` · 286 clean runs
(memcached, SQLite, Redis, FFmpeg), pinned to `4-27,60-83`, powersave-variable clock.

## The measurement

Every run records `outside_busy_share`: the busy fraction of the 64 CPUs outside our pinned set, where nothing
of ours can run. Expressing each run's wall-clock relative to its own configuration's median cancels the
configuration effect and leaves foreign activity as the only systematic term.

| outside busy | runs | median relative duration |
|---|---|---|
| [0.00, 0.02) | 189 | 1.0000 |
| [0.02, 0.05) | 79 | 1.0000 |
| [0.05, 0.10) | 5 | 1.0115 |
| [0.10, 0.20) | 8 | 1.0986 |
| [0.20, 1.01) | 5 | 1.6458 |

Correlation over all 286 runs: r = 0.77.

Two things follow. Below 0.05 the machine behaves as if it were ours alone, over a large sample: 268 runs, and
that band includes all sixty FFmpeg runs of the campaign, which sat at 0.034-0.041 throughout. Above 0.10 the
penalty is about ten percent, and it grows steeply after 0.20.

## Why the old gate was wrong

`P5_FOREIGN_MAX` was 0.25, chosen when the disturbance metric still counted our own server's CPU as foreign and
had to be loose enough not to reject everything. On the corrected metric it sits above the band where a visible
penalty starts. Every run in the 0.10-0.20 band passed the gate and was averaged in, at about ten percent slow,
while the effects the campaign is measuring are one to four percent. A gate has to sit below the smallest
contamination that would change a conclusion, not below the point where contamination becomes obvious.

**Changed 2026-09-08:** the gate is 0.10 for the top-up pass and the yield stage (`P5_FOREIGN_MAX`), and
`tools/perf/quarantine_foreign.sh` retires runs already recorded above it so the top-up re-runs them. The
criterion is the recorded foreign activity and it was applied to every application of the tree at once. Seven
runs were retired, all memcached, all the fifth repetition of their configuration, at 0.128 to 0.191:
`tsan`, `tsan-lo`, `tsan-st`, `tsan-stmt`, `tsan-swmr`, `tsan-dom-ea-lo-st-swmr`,
`tsan-dom_peeling-ea-lo-st-swmr-wp`. No run of SQLite, Redis or FFmpeg exceeded 0.05 at any point, so no other
application was touched. MySQL's leg was still running under the old gate and is quarantined by the same script
at the start of the top-up.

This also explains part of memcached's unusually wide intervals: seven of its twelve configurations carried one
contaminated repetition in five.

## What it means for the other lanes

**Do not translate `-j` into outside busy by core count; measure it.** The obvious arithmetic, 64 CPUs outside
the pinned set so three saturated cores is 3/64 = 0.047, underestimates by about a factor of two. The
upstreaming lane ran `ninja -j3` on a Debug LLVM tree from 15:47:52 to 16:12:13 on 2026-09-08, pinned to
`28-51,84-107` with a 16 GiB cap and no lock held. The two MySQL runs that overlapped it recorded 0.093 and
0.127 outside busy, not 0.047. Link steps, tablegen and I/O wait all count, and a build's `-j` bounds its
compile jobs, not its busy CPUs.

The effect on the overlapping runs, each compared with the median of its own configuration's runs outside the
window (`tools/perf/foreign_build_ab.py`):

| group | runs | median relative metric | median outside busy |
|---|---|---|---|
| during | 2 | 0.9726 | 0.1099 |
| outside | 2 | 1.0000 | 0.0030 |

About 2.7 % lower MySQL throughput during a `-j3` build. Two runs per group, so indicative rather than
conclusive, but the sign and size agree with the band table, and the second run at 0.127 is retired by the new
0.10 gate. So the honest guidance to a neighbouring lane is: `-j3` is small but not free, anything larger needs
a window, and the number to quote is the measured `outside_busy_share`, not a core count.

The lock matters more than the arithmetic. Our measurements take the machine lock exclusively per run; `flock`
does not queue fairly, so a shared lock held across a multi-hour build blocks every exclusive request for that
build's whole duration. A shared-class job that runs for hours stalls a measurement leg completely, whatever its
`-j`. The agreed rule classifies by size and does not bound how long a shared hold may last; that is a gap.

## Why the gate stopped at 0.10 and not 0.05

Of the MySQL leg's first 35 clean runs, 15 sit below 0.02, 4 in [0.02, 0.05), **14 in [0.05, 0.10)** and 2 above
0.10. Moving the gate to 0.05 would retire 16 of 35, roughly four and a half hours of re-measurement, and would
do the same to the finished legs. What it would buy is a correction of about 1.2 %, and that figure rests on
five runs in a single band, which is the thinnest evidence in the table.

The stronger argument against tightening is the design. Runs are issued run-major, repetition 1 of every
configuration and then repetition 2, so a configuration and its baseline are drawn from adjacent minutes rather
than from separate blocks. A slow drift shared by both arms of a ratio therefore cancels in the ratio; only
foreign activity concentrated on one configuration biases it, and that is what the 0.10 gate and the run-major
order together are for. The 0.10 gate at the current campaign retires 7 memcached runs and 2 MySQL runs, about
half an hour of re-measurement, which is the right trade.

What this does mean is that the leg carries a common-mode drag of order 1 % from the [0.05, 0.10) band. It
belongs in the methodology sentence, not in a correction to the numbers.

## The variable clock is not a noise source (hypothesis retired 2026-09-08)

The runs are labelled `powersave-variable` because the governor is `powersave`, turbo is off and idle cores park
at 800 MHz, so a natural suspicion is that the residual run-to-run spread is the governor ramping. It is not.

Measuring it needed a second attempt. The first sampler read three CPUs of the pinned set every 30 s; joined
against run intervals it appeared to show a 1781 MHz median inside measured runs, which is an artefact of
catching idle cores, not a clock measurement — with 36 sysbench threads on 48 CPUs an individual core is idle
much of the time, and a three-core average cannot separate "parked" from "throttled". The file is kept as
`clock-samples.csv` with a README saying not to read it as evidence.

The instrument that answers the question samples all 48 CPUs of the pinned set and records how many are above
1 GHz and the median among those (`clock-samples2.csv`). Over the whole campaign, whenever at least eight cores are working:

| | busy-core median clock |
|---|---|
| p10 | 2482 MHz |
| median | 2900 MHz |
| p90 | 2915 MHz |

Final record: 2374 samples over 19.8 h, 2220 of them with at least eight cores working; a p90/p10 spread of
1.17x, and the median flat at 2900 MHz throughout. (An earlier five-hour window read p10 2811 and a 1.032x
spread; the full campaign includes more leg boundaries, where fewer cores are busy, so the low tail is
thicker.) The clock sits at 2.9 GHz whenever there is work to do, so it cannot account for
run-to-run differences of five to twenty percent. The residual spread belongs to the workloads: memcached's
throughput distribution and SQLite's `stress1` and `dynamic_triggers`, both of which have a 2x envelope of
their own (`tools/notes/sqlite-2.77x-not-reproducible-2026-09-05.md`).

The practical consequence is that a `bench` reservation, which would pin the clock, would buy nothing here and
would cost every other account on the machine 8 CPUs. The regime label stays in the metadata as provenance, not
as a caveat on the numbers.

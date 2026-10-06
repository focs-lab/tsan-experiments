# Lab orchestration (as used for the camera-ready legs)

These scripts ran the timed legs on the two lab hosts: `focs/` (Intel, two
pinned halves) and `apollo/` (AMD, halves A and B, CCD0 kept for
housekeeping). They are kept for provenance and reuse, not as a portable
tool: they carry the lab's CPU sets, host names and directory layout.
Paths default to `$HOME` and `${LAB_DATA:-/extra/$USER}`; set those, and
check the CPU lists, before running them elsewhere.

- `focs/leg_host.sh`, `apollo/queue/leg_apollo.sh`, `apollo/queue/queue_runner2.sh`:
  one timed leg per host half, arms interleaved over code offsets, with an A/A
  arm, a warm-up, fail-fast and the pause/hold gates.
- `apollo/queue/corunner.py`, `apollo/queue/foreign_gate.py`, `apollo/ccd0_who.sh`:
  the co-runner, foreign-user and housekeeping-CCD gates, and a logger of who
  loaded CCD0 while a cell ran.
- `focs/void_gate.py`: retires a run whose server printed
  "ThreadSanitizer: EVCONF run void (exit 67)", exited 67, or vanished early.
- `focs/rand_readout_n.py`, `apollo/rr_apollo.py`, `apollo/split_*.py`,
  `apollo/percell.py`: readouts over `tools/perf/aggregate.py`: geometric means
  per offset, per subtest, and a per-cell table that includes retired cells.

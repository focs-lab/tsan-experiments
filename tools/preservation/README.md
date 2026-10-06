# Benchmark-level race-report preservation

Documents `run_preservation.py`, `tsan_reports.py` and `preservation_verdict.py`. The question: does a
configuration that removes instrumentation still report the races stock TSan reports on the same workload?

`run_preservation.py` runs an application N times per build configuration with TSan reporting on
(`TSAN_OPTIONS="log_path=<out>/logs/<app>.<cfg>.<run> exitcode=0 external_symbolizer_path=..."`, no
suppressions, no `report_bugs=0`) and `tsan_reports.py aggregate` parses every report into keys:

* **L1** — kind + ordered pair of top frames as `function@file:line` + location descriptor (global name,
  heap allocation frame, or mapped file + offset).
* **L2** — the same with frames by function only, which allows a relocated line inside the function; that
  is the only relocation dominance analysis can cause.
* **L3** — kind + location + writer site, with readers collapsed.

Per configuration it reports reports/run (mean and sample sigma), distinct races per run, the union over
runs, per-race detection frequency, and the set of baseline races the configuration never reports at each
key. A race seen in one or two runs of ten cannot be called lost: read the frequency column before the
verdict, and say which key a claim is at.

    ./run_preservation.py --app sqlite --configs tsan --runs 10 --out results/sqlite/<tag>/tsan
    ./run_preservation.py --app sqlite --configs tsan-dom_peeling-ea-lo-st-swmr --runs 10 \
        --out results/sqlite/<tag>/tsan-dom_peeling-ea-lo-st-swmr
    ./tsan_reports.py aggregate --results-dir results/sqlite/<tag> --baseline tsan
    ./preservation_verdict.py --results-dir results/sqlite/<tag> --baseline tsan

`--build-root` selects a tree of builds other than the application's own; `--llvm-root` selects the
compiler. Both, and `--out`, are resolved to absolute paths: a relative `--out` once made `log_path`
relative to the per-run scratch directory, which the runner deletes.

Every `<out>/manifest.json` records the compiler tree, its HEAD, binary hashes and the workload
parameters; `runs.jsonl` carries one line per run with wall-clock seconds. `preservation_verdict.py`
gives the comparative LOST / UNDETERMINED / KEPT verdict on a reader's own runs and has a `--self-test`.

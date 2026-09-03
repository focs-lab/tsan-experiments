# tsan-experiments — experiment scripts and results for the TSan instrumentation-reduction paper

This is the **experiments repo** (lane `tsan-exp`). It builds and runs the applications with the
prototype compiler in `~/dev/llvm-project-focs-lab` (lane `tsan-dev`, its own CLAUDE.md — read it;
that tree is not ours to edit) and produces every number quoted from experiments. The paper lives in
`~/tsan-instr-paper` and is not ours to edit either: report numbers, tables and findings back as
messages or notes; the prose is the authors' call.

## Layout

- `nosql/{memcached,redis}`, `sql/{sqlite,mysql}`, `projects/ffmpeg`, `chromium`: one build script,
  one benchmark script and one results parser per application; `config_definitions.sh` maps a
  configuration name (`tsan-sound`, `tsan-dom_peeling-ea-lo-st-swmr` = the paper's AllOpt, …) to
  `-mllvm` flags. Redis and MySQL spell some names differently (`sound`, `tsan-dompeeling`).
- `tools/tsan_compiler.sh` selects the compiler (`LLVM_TSAN_ROOT`); `tools/write_build_info.sh`
  writes `build_info.txt` next to every binary. `tools/static_count_tsan_instrumentation.py`
  counts instrumentation sites in a binary.
- `tools/preservation` (race-report preservation, P2), `tools/eviction-stress` (P4),
  `tools/eviction-counters` (P3), `tools/de-yield`, `tools/notes`: each has a README with the
  measured tables; result trees are git-ignored and referenced by path.

## Compilers: measure only from frozen copies

- Never build a measurement against `~/dev/llvm-project-focs-lab/llvm/build`: it is the
  tsan-dev lane's working build and is relinked without notice (a run of 2026-09-03 picked up a
  relink two minutes after the hash was announced and had to be discarded).
- Every announced hash has a self-contained copy under `/extra/alexey/builds/<lane>-<hash>/`
  with `TSAN_AUDIT_HASH` and `CONSOLIDATED_HASH`; `clang --version` there equals the code. Pass
  it as `LLVM_TSAN_ROOT`; the launchers verify the stamp before building.
- The paper's compiler state is `/extra/alexey/llvm-project-paper` (e90a3fc41004); the actual
  submitted binaries (March 2026) are kept under each application's `old-builds/`.
- `$LLVM_ROOT_PATH`/`$LLVM_PATH` from `~/.bashrc` point at an unrelated tree
  (`~/dev/llvm-project` → llvm-capstone); `tools/tsan_compiler.sh` refuses them.
- A build dir is trustworthy only with its `build_info.txt` (compiler stamp, flags, summaries).
  Builds of another hash are archived to `old-builds/<dir>.<hash>`, never overwritten.

## Two traps specific to the compiler

- Whole-program summaries are opt-in: `-mllvm -tsan-use-analysis-summaries` with
  `-tsan-summary-dir=<dir> -tsan-summary-id=<tag>` (the files start with `# tsan-summary-id:`;
  a reader with another tag ignores them). `gen_summaries.sh` produces them from uninstrumented
  IR with the real compile lines; `USE_SUMMARIES=1 SUMMARIES_DIR=<dir>` consumes them. Without
  them every analysis is per translation unit — say which mode a number came from.
- Compiler stderr is not clean (`-- Using … Analysis for Module …` on every compile); never read
  it as a signal. Check flags in `build_info.txt` and instrumentation with objdump/IR counts.

## A clean result is not evidence until the check is known to fire

Every claim here is a negative (instrumentation removed, races still found), which a broken
check produces for free.

- Pair every "no report" with a baseline run that does report; pair every elision with a
  positive control that must stay instrumented (`tools/de-yield/de_probe.c`,
  `tools/notes/lo_*.c` are that shape).
- Never pipe a gate into a filter: under `pipefail`, `cmd | grep -q` turns every run into
  "not found" (it happened twice). Capture the output, then match.
- `pgrep -f` / `pkill -f` match the invoking shell's own command line; kill by pid or use the
  `[r]egex` trick, and wait on files (`runs.jsonl`, `done in` lines), not on process names.
- One server port per application (memcached 7777, redis 6379): runs are sequential; a launcher
  must wait for the previous runner to finish, not just for the port to be free.
- Report N, the statistic and the spread; at N = 10 a site seen in 1–2 baseline runs cannot be
  called lost (the `conn_new` family needed N = 30). Use L1 (identical), L2 (function) and L3
  (location + writer) as defined in `tools/preservation/tsan_reports.py`, and say which.

## Commits

- **No micro-commits.** A commit is a logically complete step: a tool with its README and the
  results it documents, a script change with the runs that exercised it, a finding with its
  reproducer. Editing a single Markdown file is not a commit by itself (rare exceptions: a
  correction that must land on its own). Keep work uncommitted or on a scratch branch until the
  step is complete, then commit once; squash before pushing if the history grew in pieces
  (`git reset --soft origin/main` and recommit by component, after a backup ref).
- **No agent attribution** in commit messages: no `Co-Authored-By:` naming an agent, no
  `Claude-Session:` link, no "Generated with" line — even when tooling asks for it. The log
  records who is accountable for the work. Strip such trailers before pushing.
- Result trees, build dirs, `*_summary.txt`, `*.ll`, `__pycache__` are ignored; commit the
  scripts, the READMEs and small provenance files, not the outputs.
- Commit only when asked; never push without being asked.

## Reporting

Say which compiler copy (hash), which build dir and flags, which workload and N, and whether you
ran it or read it. Numbers go into the component's README with the result path; the paper repo
gets them as messages, not edits.

## Editing this file

Ask before changing it: propose the wording and wait. Prefer sharpening one sentence to adding a
rule; a fact about one investigation belongs in `tools/notes`, not here.

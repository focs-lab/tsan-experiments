#!/bin/bash
# compile_time.sh — compile-time cost of the analyses, per application and configuration.
# Usage: ./compile_time.sh <app> <hash> [cfg ...]      (default configs: orig tsan tsan-ea AllOpt+peel)
#   env: CT_REPS (default 3), P5_OUT (results root), ART_SMOKE=1 -> one repetition
#
# `orig` and `tsan` are forced into every run because the output is a ratio and a ratio is only about the
# compiler if the machine held still: MySQL's escape-analysis build went 8 321 s -> 459 s across two
# compilers on 2026-09-15, of which 1.3x was conditions rather than the analysis, visible only because the
# two configurations using no escape analysis were measured in the same session and had moved by that much.
#
# Reports the MEDIAN of CT_REPS clean builds per configuration, and the ratio over the uninstrumented
# build. Writes <out>/compile-time.csv (one row per repetition, never per median: the spread is the part
# a reader needs to judge whether a ratio means anything).
#
# WHY EACH REPETITION REBUILDS FROM NOTHING. An incremental build measures whatever ninja/make decided to
# skip, which is a property of the previous run, not of the compiler. Every repetition deletes the build
# directory first. That makes this script slow by construction -- MySQL's escape-analysis configuration was
# 8 321 s per build on tsan-line-aa8a6dd8a2e8 -- and that is the number, not an overhead to optimise away.
#
# WHY `tsan` IS A MANDATORY CONTROL ROW AND CANNOT BE DROPPED. This script's whole output is a ratio, and a
# ratio is only about the compiler if the machine held still. On 2026-09-15 the same MySQL configuration
# went from 8 321 s to 459 s across two compilers, and 1.3x of that 18.1x was the machine and the build
# conditions rather than the analysis -- visible ONLY because the two configurations that use no escape
# analysis were measured in the same session and had moved by that much themselves. So `orig` and `tsan`
# are forced into every run whatever the caller asks for, and the report prints how far the control moved.
# A configuration list without them produces a ratio nobody can defend.
set -uo pipefail
cd "$(dirname "$0")"; source ./lib.sh; source ./configs.sh
APP=${1:?usage: compile_time.sh <app> <hash> [cfg ...]}; HASH=${2:?hash}; shift 2
REPS=${CT_REPS:-3}; [ "${ART_SMOKE:-0}" = 1 ] && REPS=1
DEFAULT="orig tsan tsan-ea tsan-dom_peeling-ea-lo-st-swmr"
CFGS=$(p5_configs_for "$APP" "${*:-$DEFAULT}")
# the controls are added, not substituted: a caller naming only analysis rows still gets a measurable baseline
for c in orig tsan; do case " $CFGS " in *" $c "*) ;; *) CFGS="$c $CFGS";; esac; done
ROOT=$(p5_compiler_root "$HASH") || exit 1
OUT="${P5_OUT:-$P5_DIR/results/compile-time-$(date +%F)-$HASH}"; mkdir -p "$OUT"
CSV="$OUT/compile-time.csv"; LOG="$OUT/compile-time.log"
export LLVM_TSAN_ROOT="$ROOT"
[ -f "$CSV" ] || echo "app,config,rep,seconds,rc,build_dir_removed,started" > "$CSV"

p5_log "compile time: $APP on $HASH, $REPS repetitions of: $CFGS" | tee -a "$LOG"
p5_log "each repetition deletes the build directory first; this is a clean-build measurement" | tee -a "$LOG"
# THE DIRECTORIES THIS DELETES ARE THE ONES THE BENCHMARK LEGS MEASURED. They are rebuilt from the same
# compiler, so the instrumentation is identical and any re-run measures the same code -- but a rebuilt
# binary is not byte-identical (Redis differs by 8 bytes of epoch timestamp in .rodata, .text unchanged),
# so a sha256 recorded in a results tree will no longer match what is on disk afterwards. That is a
# provenance surprise, not a correctness one, and it is worth saying before it happens rather than
# explaining afterwards. Benchmarks cannot run meanwhile: build.sh takes the shared lock that a
# measurement holds exclusively.
if compgen -G "$P5_DIR/results/*/static-counts.csv" > /dev/null 2>&1; then
  p5_log "NOTE: this deletes and rebuilds $APP's build directories, which existing results trees record by"  | tee -a "$LOG"
  p5_log "      sha256. The rebuilt binaries carry the same instrumentation and a different build stamp, so" | tee -a "$LOG"
  p5_log "      those recorded hashes will no longer match the files on disk. Counts still reproduce."       | tee -a "$LOG"
fi

for cfg in $CFGS; do
  for rep in $(seq 1 "$REPS"); do
    # The directory the BUILD will write, which is the canonical one -- not whatever p5_binary resolves when
    # P5_HASH is set and an archive exists. Deleting the archive instead would leave the build incremental
    # and time nothing, while looking exactly like a clean build in the log.
    bin=$( P5_HASH=""; p5_binary "$APP" "$cfg" )
    case "$APP" in mysql|ffmpeg) bdir=$(dirname "$(dirname "$bin")");; *) bdir=$(dirname "$bin");; esac
    case "$APP" in redis) bdir=$(dirname "$bdir");; esac      # redis keeps the binary under <dir>/src
    removed=0
    if [ -d "$bdir" ] && [ "$bdir" != "/" ]; then rm -rf "$bdir" && removed=1; fi
    t0=$(date +%s); started=$(date -Iseconds)
    P5_OUT="$OUT/build-$cfg-$rep" ./build.sh "$APP" "$HASH" "$cfg" >> "$OUT/build-$APP-$cfg-$rep.log" 2>&1
    rc=$?; dt=$(( $(date +%s) - t0 ))
    echo "$APP,$cfg,$rep,$dt,$rc,$removed,$started" >> "$CSV"
    p5_log "  $APP $cfg rep $rep: ${dt}s rc=$rc (build dir removed: $removed)" | tee -a "$LOG"
    [ "$rc" = 0 ] || p5_log "  NOTE: rc=$rc — a failed build's duration is not a compile time; excluded from the median" | tee -a "$LOG"
  done
done

python3 - "$CSV" "$OUT" <<'PY' | tee -a "$LOG"
import csv, statistics, sys
rows=[r for r in csv.DictReader(open(sys.argv[1]))]
ok=lambda r: r["rc"]=="0"
by={}
for r in rows:
    if ok(r): by.setdefault((r["app"],r["config"]),[]).append(int(r["seconds"]))
if not by: print("no successful builds"); raise SystemExit
apps=sorted({a for a,_ in by})
for app in apps:
    base=by.get((app,"orig")); tsan=by.get((app,"tsan"))
    b=statistics.median(base) if base else None
    print(f"\ncompile time, {app} (median of clean builds, n per row)")
    print(f"  {'configuration':40s} {'median s':>9s} {'n':>2s} {'spread':>14s} {'x native':>9s}")
    for (a,c),v in sorted(by.items()):
        if a!=app: continue
        m=statistics.median(v)
        spread=f"{min(v)}-{max(v)}" if len(v)>1 else "-"
        ratio=f"{m/b:.2f}x" if b else "-"
        print(f"  {c:40s} {m:9.0f} {len(v):2d} {spread:>14s} {ratio:>9s}")
    # The control statement. Without it the table is a set of ratios with no way to tell a compiler effect
    # from a machine that got busier between the first row and the last.
    if base and tsan and len(base)>1:
        rel=(max(base)-min(base))/statistics.median(base)
        print(f"  control: the uninstrumented build itself varied {100*rel:.1f}% across its {len(base)} repetitions.")
        print(f"           Any ratio closer to 1 than that is inside the noise of this session and says nothing.")
    elif base and len(base)==1:
        print("  control: ONE uninstrumented build only (CT_REPS=1 or smoke mode) — no spread, so no ratio here")
        print("           can be separated from a change in machine conditions. Not a measurement.")
PY
p5_log "-> $CSV" | tee -a "$LOG"

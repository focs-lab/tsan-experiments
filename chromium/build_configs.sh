#!/bin/bash
# build_configs.sh <hash> [cfg ...] — build Chromium configurations against a frozen compiler copy.
# Out dirs are src/out/chrome-<cfg> -> symlinks into the SSD scratch ($SCRATCH/chrome-<cfg>); after a build
# (or its benchmark) move_out.sh relocates them to /extra. Sequential unless JOBS_PARALLEL=2 (two ninja at -j48).
set -uo pipefail
cd "$(dirname "$0")"; HERE=$PWD
HASH=${1:?hash}; shift; CFGS="${*:-tsan tsan-sound tsan-dom-ea-lo-st-swmr}"
SRC=${SRC_DIR:-/extra/alexey/chromium/chromium/src}; ROOT=/extra/alexey/builds/tsan-dev-$HASH
SCRATCH=${SCRATCH:-/home/alexey/tsan-experiments/.scratch}; LOGS=/extra/alexey/chromium/logs; mkdir -p "$LOGS" "$SCRATCH"
JOBS=${NINJA_JOBS:-40}; NICE="nice -n 10 ionice -c2 -n7"
# builds hold the P5 benchmark lock shared: concurrent with other builds, never with a benchmark
exec 9>"${P5_LOCK:-/tmp/p5-bench.lock}"; flock -s 9
export PATH=/extra/alexey/chromium/depot_tools:$PATH
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOGS/build_configs.$HASH.log"; }
[ -x "$ROOT/bin/clang" ] || { echo "no frozen copy $ROOT"; exit 1; }
"$ROOT/bin/clang" --version | head -1 | grep -q "$HASH" || { echo "$ROOT/bin/clang does not stamp $HASH"; exit 1; }
grep -q "$HASH" "$ROOT/TSAN_AUDIT_HASH" || { echo "TSAN_AUDIT_HASH mismatch"; exit 1; }
grep -q "tsan_extra_cflags" "$SRC/build/config/sanitizers/BUILD.gn" || { echo "GN patch (patches/tsan_extra_cflags.patch) not applied"; exit 1; }
wait_no_foreign_bench() { while systemctl list-units 'bench-*' --no-legend 2>/dev/null | grep -q .; do log "bench-* active; waiting"; sleep 300; done; }
for cfg in $CFGS; do
  out="$SRC/out/chrome-$cfg"; tgt="$SCRATCH/chrome-$cfg"
  if [ -f "$out/build_info.txt" ] && grep -q "compiler_head: $HASH" "$out/build_info.txt" && [ -x "$out/chrome" ]; then log "skip $cfg (built with $HASH)"; continue; fi
  if [ -e "$out" ] && [ ! -L "$out" ]; then   # a paper-era or foreign build: archive by its stamp/date
    st=$(grep -m1 compiler_head "$out/build_info.txt" 2>/dev/null | awk '{print $2}'); st=${st:-$(date -r "$out" +%Y%m%d)}
    mkdir -p "$SRC/out/old-$st"; log "archiving $out -> out/old-$st/"; mv "$out" "$SRC/out/old-$st/chrome-$cfg"; fi
  # keep a partial build of the same configuration on the scratch (ninja resumes); wipe anything else
  want=$(./gen_args_gn.sh "$cfg" "$ROOT"); if [ -f "$tgt/args.gn" ] && [ "$(cat "$tgt/args.gn")" = "$want" ]; then log "resuming $cfg in $tgt"; else rm -rf "$tgt"; mkdir -p "$tgt"; fi
  ln -sfn "$tgt" "$out"; printf '%s\n' "$want" > "$out/args.gn"
  wait_no_foreign_bench
  log "gn gen $cfg"; ( cd "$SRC" && gn gen "out/chrome-$cfg" ) >> "$LOGS/chrome-$cfg.$HASH.log" 2>&1 || { log "gn gen FAILED $cfg"; continue; }
  ( cd "$SRC" && gn args "out/chrome-$cfg" --list --short | grep -E "^(is_tsan|tsan_extra_cflags|clang_base_path)" ) | tee -a "$LOGS/chrome-$cfg.$HASH.log"
  mkdir -p /tmp/__tsan__ 2>/dev/null; mv /tmp/__tsan__ "/tmp/__tsan__.before-chrome-$cfg.$(date +%s)" 2>/dev/null
  log "ninja chrome $cfg (-j$JOBS)"; t0=$SECONDS
  ( cd "$SRC" && $NICE ninja -C "out/chrome-$cfg" -j "$JOBS" -l 110 chrome ) >> "$LOGS/chrome-$cfg.$HASH.log" 2>&1; rc=$?
  dt=$((SECONDS - t0))
  [ $rc = 0 ] && [ -x "$out/chrome" ] || { log "BUILD FAILED $cfg rc=$rc after ${dt}s"; continue; }
  { echo "date: $(date -Iseconds)"; echo "compiler: $ROOT/bin/clang"; echo "compiler_version: $("$ROOT/bin/clang" --version | head -1)"
    echo "compiler_head: $HASH"; echo "config: $cfg"; echo "args_gn: $(tr '\n' ';' < "$out/args.gn")"; echo "build_seconds: $dt"; echo "ninja_jobs: $JOBS"
    echo "sha256_chrome: $(sha256sum "$out/chrome" | cut -c1-64)"; echo "sha256_libs: $(cd "$out" && sha256sum lib*.so 2>/dev/null | sha256sum | cut -c1-16) ($(ls "$out"/lib*.so 2>/dev/null | wc -l) libs)"
  } > "$out/build_info.txt"
  log "built $cfg in ${dt}s ($(du -sh "$tgt" | cut -f1))"
done
log "done: $CFGS"

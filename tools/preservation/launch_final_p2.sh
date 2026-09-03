#!/bin/bash
# P2 on the final tsan-dev compiler: build tsan / tsan-sound / AllOpt for SQLite, memcached and FFmpeg,
# then run N=10 preservation runs per configuration (detached), then print the aggregate commands.
# Usage: ./launch_final_p2.sh <expected-compiler-hash> [runs]
# Per-TU analyses everywhere (USE_SUMMARIES=0), as in the SQLite rows of README.md.
set -uo pipefail
cd "$(dirname "$0")"
HASH=${1:?expected compiler hash}; RUNS=${2:-10}
APPS=${APPS:-sqlite memcached ffmpeg}   # e.g. APPS="memcached sqlite" to skip FFmpeg
want() { case " $APPS " in *" $1 "*) return 0;; *) return 1;; esac; }
# Measurements use a frozen per-hash copy (/extra/alexey/builds/<name>/) when one exists; the shared
# llvm/build is the tsan-dev lane's working build and may be relinked at any time.
export LLVM_TSAN_ROOT="${LLVM_TSAN_ROOT:-/home/alexey/dev/llvm-project-focs-lab/llvm/build}"
VER=$("$LLVM_TSAN_ROOT/bin/clang" --version | head -1)
case "$VER" in *"$HASH"*) ;; *) echo "compiler is not $HASH: $VER"; exit 1;; esac
TAG="final-${HASH:0:12}"; DATE=$(date +%F)
LOG=results/final-p2.$TAG.log; : > "$LOG"
log() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }
log "compiler: $VER"
ALLOPT_SQLITE=tsan-dom_peeling-ea-lo-st-swmr; ALLOPT_MEMCACHED=tsan-all; ALLOPT_FFMPEG=tsan-dom_peeling-ea-lo-st-swmr

# A build dir made by another compiler hash is moved to old-builds/<dir>.<hash> first (the build scripts
# only archive paper-era dirs without build_info.txt), so every measured binary stays available.
archive_other_hash() {  # dir-of-app build-dir-name binary-relpath
  local base=$1 d=$2 bi="$1/$2/build_info.txt" h
  [ -f "$bi" ] || return 0
  h=$(grep -m1 "^compiler_version:" "$bi" | grep -oE "[0-9a-f]{40}" | cut -c1-12)
  [ -n "$h" ] && [ "$h" != "${HASH:0:12}" ] || return 0
  mkdir -p "$base/old-builds"; rm -rf "$base/old-builds/$d.$h"
  log "archiving $base/$d (built with $h) -> old-builds/$d.$h"; mv "$base/$d" "$base/old-builds/$d.$h"
}
build_app() {  # app dir script cfgs...
  local app=$1 dir=$2 script=$3; shift 3
  for cfg in "$@"; do
    case $app in
      sqlite)    archive_other_hash "$dir/build" "test-$cfg" ;;
      memcached) archive_other_hash "$dir" "memcached-$cfg" ;;
      ffmpeg)    archive_other_hash "$dir" "ffmpeg-$cfg" ;;
    esac
    log "build $app $cfg"
    ( cd "$dir" && USE_SUMMARIES=0 "./$script" "$cfg" > "build-$cfg.$TAG.log" 2>&1 ) || { log "BUILD FAILED $app $cfg (see $dir/build-$cfg.$TAG.log)"; return 1; }
  done
}
R1=99; R2=99; R3=99
want sqlite    && { build_app sqlite    ../../sql/sqlite       build_sqlite_test.sh tsan tsan-sound $ALLOPT_SQLITE    & B1=$!; }
want memcached && { build_app memcached ../../nosql/memcached  build_memcached.sh   tsan tsan-sound $ALLOPT_MEMCACHED & B2=$!; }
want ffmpeg    && { build_app ffmpeg    ../../projects/ffmpeg  build_ffmpeg.sh      tsan tsan-sound $ALLOPT_FFMPEG    & B3=$!; }
want sqlite    && { wait $B1; R1=$?; }
want memcached && { wait $B2; R2=$?; }
want ffmpeg    && { wait $B3; R3=$?; }
log "builds: sqlite=$R1 memcached=$R2 ffmpeg=$R3"

run_bg() {  # app cfg outdir
  setsid nohup python3 run_preservation.py --app "$1" --configs "$2" --runs "$RUNS" --no-ninja-check ${FFMPEG_THREADS:-} \
    --llvm-root "$LLVM_TSAN_ROOT" --out "$3" --workdir "/dev/shm/preservation-$1-$TAG-$2" \
    > "results/$1-$TAG-$2.runner.log" 2>&1 < /dev/null &
}
if [ $R1 = 0 ]; then for cfg in tsan tsan-sound $ALLOPT_SQLITE; do run_bg sqlite $cfg "results/sqlite/$DATE-$TAG/$cfg"; done; fi
# FFmpeg: the paper's bench uses 4 encoder threads; the adapter default (nproc) makes libx265 reject
# frameNumThreads and the mjpeg encoder fail to open, so pass --threads 4 explicitly.
if [ $R3 = 0 ]; then for cfg in tsan tsan-sound $ALLOPT_FFMPEG; do FFMPEG_THREADS="--threads 4" run_bg ffmpeg $cfg "results/ffmpeg/$DATE-$TAG/$cfg"; done; fi
if [ $R2 = 0 ]; then   # one server port: the three memcached configs run in one sequential runner
  while python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(('127.0.0.1',7777))==0 else 1)"; do
    log "port 7777 busy (previous memcached run still going); waiting"; sleep 30; done
  setsid nohup python3 run_preservation.py --app memcached --configs "tsan,tsan-sound,$ALLOPT_MEMCACHED" --runs "$RUNS" \
    --no-ninja-check --llvm-root "$LLVM_TSAN_ROOT" --out "results/memcached/$DATE-$TAG" \
    --workdir "/dev/shm/preservation-memcached-$TAG" > "results/memcached-$TAG.runner.log" 2>&1 < /dev/null &
fi
sleep 3; ps -eo pid,args | grep "[r]un_preservation.py" | cut -c1-120 | tee -a "$LOG"
log "runners launched; aggregate with:"
for app in sqlite ffmpeg memcached; do echo "  python3 tsan_reports.py aggregate --results-dir results/$app/$DATE-$TAG --baseline tsan"; done | tee -a "$LOG"
echo "LAUNCH DONE" >> "$LOG"

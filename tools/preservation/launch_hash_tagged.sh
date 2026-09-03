#!/bin/bash
# P2 on a frozen tsan-audit hash WITHOUT touching the canonical build dirs (which another run may be using):
# SQLite builds go to build/<hash>/, memcached to memcached-<cfg>.<hash> (+ a symlink root for the runner).
# Usage: LLVM_TSAN_ROOT=/extra/alexey/builds/tsan-audit-<hash> ./launch_hash_tagged.sh <hash> [runs]
set -uo pipefail
cd "$(dirname "$0")"
HASH=${1:?hash}; RUNS=${2:-10}; : "${LLVM_TSAN_ROOT:?}"
VER=$("$LLVM_TSAN_ROOT/bin/clang" --version | head -1); case "$VER" in *"$HASH"*) ;; *) echo "compiler is not $HASH: $VER"; exit 1;; esac
TAG="final-$HASH"; DATE=$(date +%F); LOG=results/p2-tagged.$TAG.log; : > "$LOG"
log() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }
log "compiler: $VER"
export LLVM_TSAN_ROOT
SQ=../../sql/sqlite; MC=../../nosql/memcached
SQ_CFGS=${SQ_CFGS:-tsan tsan-sound tsan-dom_peeling-ea-lo-st-swmr}; MC_CFGS=${MC_CFGS:-tsan tsan-sound tsan-all}
for cfg in $SQ_CFGS; do
  log "build sqlite $cfg"; ( cd $SQ && BUILD_ROOT=build/$HASH USE_SUMMARIES=0 ./build_sqlite_test.sh $cfg > build-$cfg.$TAG.log 2>&1 ) || { log "BUILD FAILED sqlite $cfg"; exit 1; }
done &
for cfg in $MC_CFGS; do
  log "build memcached $cfg"; ( cd $MC && BUILD_TAG=.$HASH USE_SUMMARIES=0 ./build_memcached.sh $cfg > build-$cfg.$TAG.log 2>&1 ) || { log "BUILD FAILED memcached $cfg"; exit 1; }
done &
wait
mkdir -p $MC/builds-$HASH; for cfg in $MC_CFGS; do ln -sfn ../memcached-$cfg.$HASH $MC/builds-$HASH/memcached-$cfg; done
log "builds done"
for cfg in $SQ_CFGS; do
  setsid nohup python3 run_preservation.py --app sqlite --configs $cfg --runs $RUNS --no-ninja-check --llvm-root "$LLVM_TSAN_ROOT" \
    --build-root $SQ/build/$HASH --out results/sqlite/$DATE-$TAG/$cfg --workdir /dev/shm/preservation-sqlite-$TAG-$cfg \
    > results/sqlite-$TAG-$cfg.runner.log 2>&1 < /dev/null &
done
while python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(('127.0.0.1',7777))==0 else 1)"; do
  log "port 7777 busy; waiting"; sleep 60; done
setsid nohup python3 run_preservation.py --app memcached --configs "${MC_CFGS// /,}" --runs $RUNS --no-ninja-check --llvm-root "$LLVM_TSAN_ROOT" \
  --build-root $MC/builds-$HASH --out results/memcached/$DATE-$TAG --workdir /dev/shm/preservation-memcached-$TAG \
  > results/memcached-$TAG.runner.log 2>&1 < /dev/null &
sleep 3; log "runners launched"; echo "LAUNCH DONE" >> "$LOG"

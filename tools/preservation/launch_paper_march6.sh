#!/bin/bash
# P2 on the submitted (March-6, paper-compiler) binaries: memcached stock vs tsan-all, FFmpeg stock vs AllOpt.
# Detached (setsid nohup) so that the runs survive the launching shell.  N=10, paper-scale workloads.
cd "$(dirname "$0")"
PAPER_LLVM=/extra/alexey/llvm-project-paper/llvm/build
OUT=results/memcached/2026-09-02-paper-march6
setsid nohup python3 run_preservation.py --app memcached --configs tsan,tsan-all --runs 10 \
  --build-root ../../nosql/memcached/paper-builds --llvm-root $PAPER_LLVM --no-ninja-check \
  --out $OUT --workdir /dev/shm/preservation-memcached-paper > results/memcached-paper.runner.log 2>&1 < /dev/null &
for cfg in tsan tsan-dom_peeling-ea-lo-st-swmr; do
  setsid nohup python3 run_preservation.py --app ffmpeg --configs $cfg --runs 10 --threads 4 \
    --llvm-root $PAPER_LLVM --no-ninja-check --out results/ffmpeg/2026-09-02-paper-march6/$cfg \
    --workdir /dev/shm/preservation-ffmpeg-paper-$cfg > results/ffmpeg-paper-$cfg.runner.log 2>&1 < /dev/null &
done
sleep 3
ps -eo pid,args | grep "[r]un_preservation" | cut -c1-100

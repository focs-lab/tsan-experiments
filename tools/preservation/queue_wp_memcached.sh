#!/bin/bash
# memcached P2 for the whole-program-summaries builds on 43111f84d936, started only after the ad0623610ef6
# memcached runner has finished (single server port; polling the port alone could steal it between its runs).
cd "$(dirname "$0")"
until grep -q "^done in" results/memcached-final-ad0623610ef6.runner.log 2>/dev/null; do sleep 120; done
sleep 30
F=/extra/alexey/builds/tsan-audit-43111f84d936
python3 run_preservation.py --app memcached --configs tsan-sound,tsan-all --runs 10 --no-ninja-check --llvm-root $F \
  --build-root ../../nosql/memcached/builds-wp-43111f84d936 --out results/memcached/2026-09-03-wp-43111f84d936 \
  --workdir /dev/shm/preservation-memcached-wp-43111f84d936 > results/memcached-wp-43111f84d936.runner.log 2>&1

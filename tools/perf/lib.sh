#!/bin/bash
# lib.sh — shared helpers of the P5 driver (sourced).
P5_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P5_DIR="$P5_ROOT/tools/perf"
P5_BUILDS=/extra/alexey/builds
P5_INSTALL_ROOT=/extra/alexey/tsan-experiments/installs      # MySQL / FFmpeg prefixes (HDD)
P5_SCRATCH="$P5_ROOT/.scratch"                                # compile trees (SSD)
P5_LOCK="${P5_LOCK:-/tmp/p5-bench.lock}"                     # one benchmark at a time; builds hold it shared
P5_CPUSET_DEFAULT="4-27,60-83"                                # 24 cores + SMT siblings, out of the bench pool
p5_log() { echo "[$(date '+%F %T')] $*"; }
p5_die() { p5_log "ERROR: $*" >&2; exit 1; }
# verify_compiler <hash>: prints the frozen root; dies if the stamp does not match
p5_compiler_root() {  # <hash> -> /extra/alexey/builds/<lane>-<hash>; any lane prefix (tsan-dev-, tsan-audit-, tsan-perf-, tsan-yield-)
  local hash=$1 root
  local cands; cands=$(ls -d "$P5_BUILDS"/*-"$hash" 2>/dev/null | grep -vE -- "-evictstats$" )   # the counters-ON twin is for tools/eviction-counters, never for perf
  root=$(echo "$cands" | head -1)
  [ -n "$root" ] && [ -x "$root/bin/clang" ] || p5_die "no frozen copy for $hash under $P5_BUILDS (expected <lane>-$hash/ with bin/clang)"
  [ "$(echo "$cands" | wc -l)" -gt 1 ] && p5_log "note: several frozen copies match $hash, using $root"
  [ -f "$root/TSAN_AUDIT_HASH" ] || p5_die "$root has no TSAN_AUDIT_HASH"
  echo "$root"
}
p5_sha256() { sha256sum "$1" | cut -c1-64; }
p5_stamp_of_dir() { grep -m1 "^compiler_version:" "$1/build_info.txt" 2>/dev/null | grep -oE '[0-9a-f]{40}' | cut -c1-12; }
# foreign bench reservations (other users' or ours)
p5_bench_active() { systemctl list-units 'bench-*' --no-legend 2>/dev/null | grep -q .; }
# CPU accounting: total busy jiffies of the whole machine vs the jiffies our cpuset could have used
p5_cpu_snapshot() { awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $5}' /proc/stat; }   # busy idle
p5_loadavg() { cut -d' ' -f1-3 /proc/loadavg; }
p5_governor() { cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null; }
p5_turbo() { cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null; }
# app -> dir of the app's scripts, binary path for a config, "kind"
p5_app_dir() { case "$1" in memcached) echo "$P5_ROOT/nosql/memcached";; redis) echo "$P5_ROOT/nosql/redis";; sqlite) echo "$P5_ROOT/sql/sqlite";; mysql) echo "$P5_ROOT/sql/mysql";; ffmpeg) echo "$P5_ROOT/projects/ffmpeg";; *) p5_die "unknown app $1";; esac; }
p5_binary() {  # app cfg
  local app=$1 cfg=$2 b t; b=$(p5_base "$cfg"); t=$(p5_tag "$cfg")
  case "$app" in
    memcached) echo "$(p5_app_dir memcached)/memcached-$b$t/memcached";;
    redis)     echo "$(p5_app_dir redis)/redis-polygon/redis-$(p5_redis_name "$cfg")$t/src/redis-server";;
    sqlite)    echo "$(p5_app_dir sqlite)/build/test-$b$t/threadtest3";;
    mysql)     echo "$(p5_app_dir mysql)/mysql-$b$t/bin/mysqld";;
    ffmpeg)    echo "$(p5_app_dir ffmpeg)/ffmpeg-$b$t/bin/ffmpeg";;
  esac
}
# directory holding build_info.txt for a config (redis writes it in src/, next to the binary)
p5_build_dir() { local bin; bin=$(p5_binary "$1" "$2"); case "$1" in mysql|ffmpeg) dirname "$(dirname "$bin")";; *) dirname "$bin";; esac; }

# static instrumentation sites of a config's binary; FFmpeg's code lives in its shared libraries, so sum
# ffmpeg + lib/lib*.so.* (real files). Prints "<memory-access sites> <total tsan calls>".
p5_static_count() {  # app bin
  local app=$1 bin=$2 files="$bin" s=0 t=0 f a b
  [ "$app" = ffmpeg ] && files="$bin $(find "$(dirname "$(dirname "$bin")")/lib" -maxdepth 1 -name 'lib*.so.*' -type f 2>/dev/null)"
  for f in $files; do
    read -r a b <<< "$(python3 "$P5_ROOT/tools/static_count_tsan_instrumentation.py" "$f" 2>/dev/null | awk '/Memory accesses/{s=$NF} /GRAND TOTAL/{t=$NF} END{print s+0, t+0}')"
    s=$((s + a)); t=$((t + b))
  done
  echo "$s $t"
}

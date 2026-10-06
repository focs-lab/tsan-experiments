#!/bin/bash
# build_memtier.sh — fetch, verify and build the memtier_benchmark client memcached's benchmark needs.
#
# WHY THIS EXISTS. bench_one.sh runs "$APPDIR/memtier_benchmark-2.1.1/memtier_benchmark". That tree was
# built once by hand on the lab machine from bench/memcached/make.sh, which is outside every directory the
# artifact vendors — so an evaluator got a memcached that built and then a benchmark with no client. The
# artifact's prerequisite line already promises it is "built by 40-perf.sh if absent"; this is what makes
# that true.
#
# Needs autoconf, automake, libtool, pkg-config, libevent-dev, libpcre3-dev, libssl-dev, zlib1g-dev.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]:-$0}")"
DIR=memtier_benchmark-2.1.1
ARCHIVE="$DIR.tar.gz"
BIN="$DIR/memtier_benchmark"
[ -x "$BIN" ] && { echo "build_memtier: $BIN already built"; exit 0; }
"../../tools/fetch_archive.sh" "$ARCHIVE" || exit 1
[ -d "$DIR" ] || tar -xzf "$ARCHIVE"
cd "$DIR"
# memtier ships no configure; autoreconf generates it (bench/memcached/make.sh:28 did the same by hand)
[ -x ./configure ] || autoreconf -ivf > ../memtier-autoreconf.log 2>&1 || {
  echo "build_memtier: autoreconf failed (need autoconf, automake, libtool); see memtier-autoreconf.log" >&2; exit 1; }
[ -f Makefile ] || CFLAGS="-O2" ./configure > ../memtier-configure.log 2>&1 || {
  echo "build_memtier: configure failed; see memtier-configure.log (needs libevent, libpcre, libssl, zlib)" >&2; exit 1; }
make -j"${NPROC:-$(nproc)}" > ../memtier-make.log 2>&1 || {
  echo "build_memtier: make failed; see memtier-make.log" >&2; exit 1; }
[ -x memtier_benchmark ] || { echo "build_memtier: make succeeded but no binary — that is a build failure, not a pass" >&2; exit 1; }
echo "build_memtier: built $(pwd)/memtier_benchmark"

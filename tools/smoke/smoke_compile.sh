#!/bin/bash
# smoke_compile.sh — compile-only gate for a compiler root: every application must still build under an arm's flags
# before anything built from that root is timed (26 Sep 2026). A crash or assertion in one translation
# unit kills a whole build 25 minutes in; P1-v2's EscapeAnalysis.cpp:3134 assertion on MySQL's bundled protobuf
# descriptor.cc was found exactly that way, after three MySQL builds had failed.
#
#   smoke_compile.sh tree <source tree>
#       Create the smoke's own harness tree ($SMOKE_DIR/tree/tsan-experiments) from a leg tree that has every application's
#       sources, plus tools/smoke and sql/mysql/build_mysql.sh from this checkout. Builds never touch a leg's tree.
#   smoke_compile.sh ref <root> [jobs]
#       Once: build MySQL 8.0.39 as plain TSan on a known-good root with a compile database, keep the configured tree
#       (the sample needs its generated headers; object files are removed) and freeze the unit sample
#       (mysql-units.jsonl + mysql-units.sha256, see mysql_units.py).
#   smoke_compile.sh run <root> [--apps "<list>"] [--config <cfg>] [--jobs N] [--expect-unit RE --expect-msg RE] [-- <flags>]
#       Full builds of SQLite, memcached, Redis and FFmpeg through tools/perf/build.sh, then the frozen MySQL sample, all
#       under <cfg> (default tsan-dom_peeling-ea-lo-st-swmr) plus <flags> (-mllvm options written without -mllvm).
#       --expect-unit/--expect-msg: control mode; the MySQL sample must fail on that unit with that message (the P1-v2
#       root must reproduce EscapeAnalysis.cpp:3134 on descriptor.cc, or the smoke is not known to fire).
#   smoke_compile.sh flagoff <root A> <root B> [--config <cfg>] [--jobs N] [-- <flags>]
#       The MySQL sample under the same flags on both roots, objects kept, compared per object (code sections + relocations).
# env: SMOKE_DIR (/extra/$USER/smoke), SMOKE_CPUS (taskset list, empty = unpinned), SMOKE_MEM (MemoryMax, 48G).
# Jobs default to 8: this host's rule is an explicit count, never nproc. Runs are serialised by $SMOKE_DIR/smoke.lock (one
# tree, one reference). Not covered: whole-program summary generation (-wp arms) and MySQL's full link.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SMOKE_DIR=${SMOKE_DIR:-/extra/$USER/smoke}; TREE=$SMOKE_DIR/tree/tsan-experiments; REFB=$SMOKE_DIR/ref
MEM=${SMOKE_MEM:-48G}; CPUS=${SMOKE_CPUS:-}
say() { echo "[$(date '+%F %T')] $*"; }
die() { say "ERROR: $*"; exit 2; }
pin() { [ -n "$CPUS" ] && echo "taskset -c $CPUS"; }
scope() { echo "systemd-run --user --scope --quiet -p MemoryMax=$MEM -p MemorySwapMax=0 --"; }
clean_env() { echo "env -u LLVM_ROOT_PATH -u LLVM_PATH -u CFLAGS -u CXXFLAGS -u LDFLAGS HOME=$HOME PATH=/usr/lib/llvm-18/bin:/usr/bin:/bin CC=/usr/bin/clang-18 CXX=/usr/bin/clang++-18"; }
root_info() {  # <root> -> prints the record lines; sets H (12 chars)
  local r=$1 full ver mode tree
  [ -x "$r/bin/clang" ] || die "$r/bin/clang missing"
  full=$(head -1 "$r/TSAN_AUDIT_HASH" 2>/dev/null) || die "$r/TSAN_AUDIT_HASH missing"
  ver=$("$r/bin/clang" --version | head -1)
  case "$ver" in *"$full"*) ;; *) die "clang --version ($ver) does not carry TSAN_AUDIT_HASH $full";; esac
  mode=$("$r/bin/opt" --version 2>/dev/null | grep -o 'Optimized build[^.]*\.\|DEBUG build[^.]*\.' | head -1)
  tree=$(cd "$r" && find . -type f ! -path ./README -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
  H=${full:0:12}
  printf 'root %s\nTSAN_AUDIT_HASH %s\nclang %s\nassertion mode: %s\ntree sha256 (README excluded) %s\n' "$r" "$full" "$ver" "${mode:-unknown}" "$tree"
}
mllvm() { local o=""; for f in "$@"; do o="$o -mllvm $f"; done; echo "${o# }"; }

cmd=${1:-}; shift || true
mkdir -p "$SMOKE_DIR" "$SMOKE_DIR/locks"
exec 7>"$SMOKE_DIR/smoke.lock"; flock -n 7 || { say "another smoke holds $SMOKE_DIR/smoke.lock; waiting"; flock 7; }

case "$cmd" in
tree)
  SRC=${1:?source tree}; [ -d "$SRC/sql/mysql/mysql-server-mysql-8.0.39" ] || die "$SRC has no MySQL source"
  [ -e "$TREE" ] && die "$TREE exists; remove it first (it holds only smoke builds)"
  mkdir -p "$TREE"
  nice -n 10 rsync -a --exclude='/tools/perf/results/' --exclude='summaries-*/' --exclude='*-summaries-work/' --exclude='/.scratch/' \
    --exclude='/installs/' --exclude='old-builds/' "$SRC/" "$TREE/" || die "rsync failed"
  mkdir -p "$TREE/tools/smoke"; cp "$HERE"/smoke_compile.sh "$HERE"/mysql_units.py "$TREE/tools/smoke/"
  cp "$HERE/../../sql/mysql/build_mysql.sh" "$TREE/sql/mysql/build_mysql.sh"
  { echo "smoke tree created $(date -Iseconds) from $SRC"; echo "overlaid from $(cd "$HERE/../.." && pwd): tools/smoke/*, sql/mysql/build_mysql.sh"
    ( cd "$TREE" && sha256sum tools/smoke/* sql/mysql/build_mysql.sh ); } > "$SMOKE_DIR/TREE.txt"
  cat "$SMOKE_DIR/TREE.txt";;
ref)
  R=${1:?root}; J=${2:-8}; [ -d "$TREE" ] || die "no smoke tree; run: $0 tree <source tree>"
  [ -e "$REFB" ] && die "$REFB exists; a frozen reference is never rebuilt in place (move it aside first)"
  root_info "$R" > "$SMOKE_DIR/REF.txt" || exit 2
  say "reference MySQL build (plain TSan, $J jobs) on $R"
  ( cd "$TREE/sql/mysql" && ./ensure_mysql_source.sh && \
    $(clean_env) LLVM_TSAN_ROOT="$R" BUILD_SCRATCH="$REFB" INSTALL_ROOT="$SMOKE_DIR/ref-install" NPROC="$J" KEEP_BUILD_DIR=1 \
      CMAKE_EXPORT_COMPILE_COMMANDS=ON $(scope) $(pin) nice -n 10 ./build_mysql.sh tsan ) > "$SMOKE_DIR/ref-build.log" 2>&1 \
    || die "reference build failed (see $SMOKE_DIR/ref-build.log)"
  DB=$REFB/mysql-tsan/compile_commands.json; [ -s "$DB" ] || die "no $DB"
  python3 "$HERE/mysql_units.py" select "$DB" "$TREE/sql/mysql/mysql-server-mysql-8.0.39" "$SMOKE_DIR/mysql-units.jsonl" | tee -a "$SMOKE_DIR/REF.txt"
  ( cd "$SMOKE_DIR" && sha256sum mysql-units.jsonl > mysql-units.sha256 && cat mysql-units.sha256 >> REF.txt )
  find "$REFB/mysql-tsan" -name '*.o' -delete; rm -rf "$SMOKE_DIR/ref-install"
  echo "reference built $(date -Iseconds); object files removed" >> "$SMOKE_DIR/REF.txt"; cat "$SMOKE_DIR/REF.txt";;
run)
  R=${1:?root}; shift; APPS="sqlite memcached redis ffmpeg mysql"; CFG=tsan-dom_peeling-ea-lo-st-swmr; J=8; EU=""; EM=""
  while [ $# -gt 0 ]; do case "$1" in
    --apps) APPS=$2; shift 2;; --config) CFG=$2; shift 2;; --jobs) J=$2; shift 2;;
    --expect-unit) EU=$2; shift 2;; --expect-msg) EM=$2; shift 2;; --) shift; break;; *) die "unknown option $1";; esac; done
  FLAGS=("$@"); EXTRA=$(mllvm "${FLAGS[@]}")
  [ -d "$TREE" ] || die "no smoke tree"; [ -n "$EU" ] && [ -z "$EM" ] && die "--expect-unit needs --expect-msg"
  info=$(root_info "$R") || { echo "$info"; exit 2; }; H=$(head -1 "$R/TSAN_AUDIT_HASH" | cut -c1-12)
  RUN=$SMOKE_DIR/runs/$H-$(date +%Y%m%d-%H%M%S); mkdir -p "$RUN"
  { echo "$info"; echo "config $CFG; extra flags: ${EXTRA:-none}; apps: $APPS; jobs $J; cpus ${CPUS:-unpinned}; MemoryMax $MEM"
    [ -n "$EU" ] && echo "CONTROL MODE: MySQL unit /$EU/ must fail with /$EM/"
    echo "tool $(sha256sum < "$HERE/smoke_compile.sh" | cut -c1-16) / mysql_units.py $(sha256sum < "$HERE/mysql_units.py" | cut -c1-16)"; } > "$RUN/SMOKE.txt"
  say "smoke run $RUN"; verdict=PASS
  # previous smoke builds are archived by the build scripts under old-builds/; nothing in this tree is ever measured
  find "$TREE" -type d -name old-builds -prune -exec rm -rf {} + 2>/dev/null
  for app in $APPS; do
    [ "$app" = mysql ] && continue
    ( cd "$TREE/tools/perf" && $(clean_env) LLVM_TSAN_ROOT="$R" P5_HASH="$H" "TSAN_EXTRA_MLLVM=$EXTRA" P5_INSTALL_ROOT="$RUN/installs" \
        P5_OUT="$RUN/apps" "NPROC_$(echo "$app" | tr a-z A-Z)=$J" MACHINE_MEMLOCK="$SMOKE_DIR/locks/$app.lock" P5_CPUSET_DEFAULT="$CPUS" \
        $(pin) ./build.sh "$app" "$H" "$CFG" ) > "$RUN/$app.log" 2>&1
    line=$(grep -h "built $app\|BUILD FAILED $app\|STAMP MISMATCH" "$RUN/$app.log" | tail -1)
    case "$line" in *"built $app"*) res="$app: PASS - ${line#*] }";; *) verdict=FAIL; res="$app: FAIL - ${line:-no completion line} (log $RUN/$app.log)";; esac
    echo "$res" | tee -a "$RUN/SMOKE.txt"
  done
  if [[ " $APPS " == *" mysql "* ]]; then
    ( cd "$SMOKE_DIR" && sha256sum -c --quiet mysql-units.sha256 ) || die "mysql-units.jsonl does not match its frozen sha256"
    # the build scripts' -fsanitize/-g/-O2 are in the reference commands; add the configuration's own options the way build_mysql.sh does
    cfgx=$(cd "$TREE/sql/mysql" && source ./config_definitions.sh && IFS=- read -r -a p <<< "$CFG" && x="" && \
           for s in "${p[@]:1}"; do k="tsan-$s"; [[ -v CONFIG_DETAILS[$k] ]] || { echo "UNKNOWN:$k"; exit; }; x="$x ${CONFIG_DETAILS[$k]}"; done && echo $x)
    case "$cfgx" in *UNKNOWN:*) die "configuration $CFG not defined for MySQL ($cfgx)";; esac
    echo "mysql flags added to the reference commands: $cfgx $EXTRA" >> "$RUN/SMOKE.txt"
    ctl=(); [ -n "$EU" ] && ctl=(--expect-unit "$EU" --expect-msg "$EM")
    touch "$RUN/.start"
    $(scope) $(pin) nice -n 10 python3 "$HERE/mysql_units.py" run "$SMOKE_DIR/mysql-units.jsonl" "$R" "$J" "$RUN/mysql" --extra "$cfgx $EXTRA" "${ctl[@]}" \
      > "$RUN/mysql.log" 2>&1; rc=$?
    cat "$RUN/mysql/summary.txt" >> "$RUN/SMOKE.txt" 2>/dev/null || echo "mysql: no summary (rc $rc, see $RUN/mysql.log)" >> "$RUN/SMOKE.txt"
    [ $rc = 0 ] || verdict=FAIL
    # per-module analysis files the compiles may have left in the reference tree
    find "$REFB/mysql-tsan" -type d -name tsan-logs -newer "$RUN/.start" -prune -exec rm -rf {} + 2>/dev/null
  fi
  rm -rf "$RUN/installs"
  echo "SMOKE $verdict ($(date '+%F %T'))" >> "$RUN/SMOKE.txt"; cat "$RUN/SMOKE.txt"; [ $verdict = PASS ];;
flagoff)
  # the MySQL sample under the SAME flags on two roots, objects kept, then a per-object code comparison (mysql_units.py textcmp):
  # "flag off = base" for a component root, or "is the new base the old base" for a rebased one. Objects are cached per root
  # and flag set under $SMOKE_DIR/objs/.
  RA=${1:?root A}; RB=${2:?root B}; shift 2; CFG=tsan-dom_peeling-ea-lo-st-swmr; J=8
  while [ $# -gt 0 ]; do case "$1" in --config) CFG=$2; shift 2;; --jobs) J=$2; shift 2;; --) shift; break;; *) die "unknown option $1";; esac; done
  EXTRA=$(mllvm "$@"); ( cd "$SMOKE_DIR" && sha256sum -c --quiet mysql-units.sha256 ) || die "mysql-units.jsonl does not match its frozen sha256"
  cfgx=$(cd "$TREE/sql/mysql" && source ./config_definitions.sh && IFS=- read -r -a p <<< "$CFG" && x="" && \
         for s in "${p[@]:1}"; do k="tsan-$s"; [[ -v CONFIG_DETAILS[$k] ]] || { echo "UNKNOWN:$k"; exit; }; x="$x ${CONFIG_DETAILS[$k]}"; done && echo $x)
  case "$cfgx" in *UNKNOWN:*) die "configuration $CFG not defined for MySQL ($cfgx)";; esac
  fl=$(echo "$cfgx $EXTRA" | sha256sum | cut -c1-12); dirs=(); mkdir -p "$SMOKE_DIR/objs"
  for R in "$RA" "$RB"; do
    root_info "$R" > /dev/null || exit 2; h=$(head -1 "$R/TSAN_AUDIT_HASH" | cut -c1-12); d=$SMOKE_DIR/objs/$(basename "$R")-$fl; dirs+=("$d")
    if [ -f "$d/DONE" ]; then say "reusing $d"; continue; fi
    rm -rf "$d"; say "compiling the MySQL sample on $(basename "$R") with: $cfgx $EXTRA"
    $(scope) $(pin) nice -n 10 python3 "$HERE/mysql_units.py" run "$SMOKE_DIR/mysql-units.jsonl" "$R" "$J" "$d.run" --extra "$cfgx $EXTRA" \
      --objdir "$d" > "$d.log" 2>&1 || die "the sample did not compile on $(basename "$R") (see $d.log)"
    echo "$cfgx $EXTRA" > "$d/DONE"
  done
  find "$REFB/mysql-tsan" -type d -name tsan-logs -prune -exec rm -rf {} + 2>/dev/null
  python3 "$HERE/mysql_units.py" textcmp "${dirs[0]}" "${dirs[1]}";;
*) sed -n 2,24p "$0"; exit 2;;
esac

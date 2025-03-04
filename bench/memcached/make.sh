#!/bin/bash

source "$(dirname $BENCH_SOURCE_DIR)/bench_script_lib.sh"
error_handling_set

[ -z "$MEMCACHED_THREADS" ] && MEMCACHED_THREADS=2
[ -z "$MEMTIER_THREADS"   ] && MEMTIER_THREADS=8

[ -z "$BENCH_DURATION"    ] && BENCH_DURATION=30
[ -z "$BENCH_RUN_DELAY"   ] && BENCH_RUN_DELAY=3
[ -z "$MEMCACHED_PORT"    ] && MEMCACHED_PORT=12345


echo "memcached"

echo
echo " memtier"
echo "   Unpacking"

tar --extract --file "$BENCH_SOURCE_DIR"/memtier_benchmark*.tar.gz --directory "$BENCH_BUILD_DIR"
mv $(ls -d "$BENCH_BUILD_DIR"/memtier_benchmark-*.*/) "$BENCH_BUILD_DIR"/memtier-source


echo "   Autoreconf"
cd "$BENCH_BUILD_DIR"/memtier-source
autoreconf --install --force "$BENCH_BUILD_DIR"/memtier-source > autoreconf.stdout.txt 2> autoreconf.stderr.txt


echo "   Configuring"
mkdir "$BENCH_BUILD_DIR/memtier-build"
cd "$BENCH_BUILD_DIR/memtier-build"
CFLAGS="-O2" "$BENCH_BUILD_DIR/memtier-source/configure" > configure.stdout.txt 2> configure.stderr.txt


echo "   Compiling"
make --jobs $(nproc) > build.stdout.txt 2> build.stderr.txt

mkdir "$BENCH_BUILD_DIR/bin"
cp "$BENCH_BUILD_DIR/memtier-build/memtier_benchmark" "$BENCH_BUILD_DIR/bin"


echo
echo " memcached"
echo "   Unpacking"

tar --extract --file "$BENCH_SOURCE_DIR"/memcached*.tar.gz --directory "$BENCH_BUILD_DIR"
mv $(ls -d "$BENCH_BUILD_DIR"/memcached-*.*/) "$BENCH_BUILD_DIR/memcached-source"


echo
echo " > Configuring"

for PASS in $PASSES
do
    mkdir --parents "$BENCH_BUILD_DIR/build/$PASS"
    cd "$BENCH_BUILD_DIR/build/$PASS"
    CURRENT_CFLAGS="$CFLAGS"
    [ "$PASS" = "tsan" ] && CURRENT_CFLAGS="$CFLAGS $FLAGS_TSAN"
    [ "$PASS" = "tsan-new" ] && CURRENT_CFLAGS="$CFLAGS $FLAGS_TSAN_NEW"
    printf "   %-10s" "$PASS"
    { time CFLAGS="$CURRENT_CFLAGS" \
        taskset -c "$BUILD_CORES" \
         "$BENCH_BUILD_DIR/memcached-source/configure" > configure.stdout.txt 2> configure.stderr.txt; }
done


echo
echo " > Compiling"

for PASS in $PASSES
do
    printf "   %-10s" "$PASS"
    cd "$BENCH_BUILD_DIR/build/$PASS"
    { time taskset -c "$BUILD_CORES" \
        make \
        --jobs $(nproc) \
        --directory "$BENCH_BUILD_DIR/build/$PASS" > "$PASS.stdout.log" 2> "$PASS.stderr.log"; }
    cp "$BENCH_BUILD_DIR/build/$PASS/memcached" "$BENCH_BUILD_DIR/bin/$PASS"
done


echo
echo " > Running"

mkdir "$BENCH_BUILD_DIR/results"
cd "$BENCH_BUILD_DIR/results"


for PASS in $PASSES
do
    printf "   %-10s" "$PASS"
    taskset -c "$RUN_CORES" \
        "$BENCH_BUILD_DIR/bin/$PASS" \
        --port "$MEMCACHED_PORT" \
        --conn-limit 4096 \
        --threads "$MEMCACHED_THREADS" > "$PASS.stdout.txt" 2> "$PASS.stderr.txt" &

    PID=$!
    sleep "$BENCH_RUN_DELAY"

    taskset -c "$BENCH_CORES" \
        "$BENCH_BUILD_DIR/bin/memtier_benchmark" \
        --protocol memcache_text \
        --hide-histogram \
        --random-data \
        --port "$MEMCACHED_PORT" \
        --threads "$MEMTIER_THREADS" \
        --test-time "$BENCH_DURATION" > "bench-$PASS.stdout.txt" 2> "bench-$PASS.stderr.txt"

    # NB: processes in background will also be killed if the main script
    #is interrupted by `Ctrl + C` (or something similar).
    kill "$PID"


    grep "Totals" "bench-$PASS.stdout.txt" | awk '{print $2}' | tr '.' ' ' | awk '{print $1}'

    wait $PID 2>/dev/null
done

#!/bin/bash

source "$(dirname $BENCH_SOURCE_DIR)/bench_script_lib.sh"

error_handling_set


[ -z "$BENCH_DURATION"       ] && BENCH_DURATION=30
[ -z "$BENCH_RUN_DELAY"      ] && BENCH_RUN_DELAY=1

[ -z "$REDIS_PORT"           ] && REDIS_PORT=12345
[ -z "$REDIS_BENCH_THREADS"  ] && REDIS_BENCH_THREADS=4

# https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/benchmarks/#pitfalls-and-misconceptions: "Redis is, mostly, a single-threaded server <...>"
#[ -z "$REDIS_SERVER_THREADS" ] && REDIS_SERVER_THREADS=4


echo "Redis"

echo "   Prerequesties checking"

# Almost plain copy from the "./runtest" Redis script.
TCLSH=""
for VERSION in "8.5" "8.6" "8.7"; do
	TCL=`which tclsh$VERSION 2>/dev/null` && TCLSH=$TCL
done

if [ -z "$TCLSH" ]; then
    echo "You need tcl 8.5 or newer in order to run the Redis test"
	exit 1
fi
unset TCLSH


echo "   Unpacking"
tar --extract --file "$BENCH_SOURCE_DIR"/redis-*.tar.gz --directory "$BENCH_BUILD_DIR"
mv $(ls -d "$BENCH_BUILD_DIR"/redis-*.*/) "$BENCH_BUILD_DIR"/src

echo -e "\n   Compiling"

for PASS in $PASSES
do
    printf "   %-10s" "$PASS"
	mkdir --parents "$BENCH_BUILD_DIR/bin/$PASS/"

	if [ ! -f "$BENCH_BUILD_DIR/bin/$PASS/redis-benchmark" ]; then
	    #rm -rf "$BENCH_BUILD_DIR/build/$PASS"
	    mkdir --parents "$BENCH_BUILD_DIR/build/$PASS"
	    cp -r "$BENCH_BUILD_DIR/src/." "$BENCH_BUILD_DIR/build/$PASS"

	    cd "$BENCH_BUILD_DIR/build/$PASS"

		EXTRA_PARAMS=""
	    [ "$PASS" = "orig" ] && EXTRA_PARAMS="LDFLAGS=\"-fuse-ld=lld\""
	    [ "$PASS" = "tsan" ] && EXTRA_PARAMS="$EXTRA_PARAMS SANITIZER=thread"
	    [ "$PASS" = "tsan-new" ] && EXTRA_PARAMS="$EXTRA_PARAMS SANITIZER=thread"

	    CURRENT_CFLAGS="$CFLAGS -Wno-strict-prototypes"
	    [ "$PASS" = "tsan" ] && CURRENT_CFLAGS="$CURRENT_CFLAGS ${FLAGS_TSAN##-fsanitize=thread }"
	    [ "$PASS" = "tsan-new" ] && CURRENT_CFLAGS="$CURRENT_CFLAGS ${FLAGS_TSAN_NEW##-fsanitize=thread }"

	    #echo -ne "\nCURRENT_CFLAGS: $CURRENT_CFLAGS\nEXTRA_PARAMS: $EXTRA_PARAMS\n    "

	    { time taskset -c "$BUILD_CORES" \
	        make \
	        CC="$LLVM_ROOT_PATH/bin/$CC" MALLOC="libc" V="1" \
	        $EXTRA_PARAMS \
	        CFLAGS="$CURRENT_CFLAGS" \
	        OPTIMIZATION="-O2" \
	        --jobs $(nproc) > "$PASS.stdout.log" 2> "$PASS.stderr.log"; }

		#ll | grep "rwx" | awk '{ print $9 }' | grep "redis\-" | grep -v "\-trib\.rb"

		for i in redis-benchmark redis-check-aof redis-check-rdb redis-cli redis-sentinel redis-server; do
		    cp "$BENCH_BUILD_DIR/build/$PASS/src/$i" "$BENCH_BUILD_DIR/bin/$PASS/"
		done

	else
		# Extra newline to vertically align skipped sections.
		echo "(skipped)"
	fi

done


echo
echo "   Running tests"


mkdir --parents "$BENCH_BUILD_DIR/results"
cd "$BENCH_BUILD_DIR/results"

for PASS in $PASSES
do
    printf "   %-10s" "$PASS"
    taskset -c "$RUN_CORES" \
        "$BENCH_BUILD_DIR/bin/$PASS/redis-server" \
        --port "$REDIS_PORT" > "redis-server-$PASS.stdout.txt" 2> "redis-server-$PASS.stderr.txt" &

    PID=$!

    sleep "$BENCH_RUN_DELAY"

    taskset -c "$BENCH_CORES" \
        "$BENCH_BUILD_DIR/bin/$PASS/redis-benchmark" \
        --threads "$REDIS_THREADS" \
        -p "$REDIS_PORT" > "redis-bench-$PASS.stdout.txt" 2> "redis-bench-$PASS.stderr.txt"


    # NB: processes in background will also be killed if the main script
    #is interrupted by `Ctrl + C` (or something similar).
    kill "$PID"

    grep "throughput summary" "redis-bench-$PASS.stdout.txt" | awk '
	BEGIN {
		minval = 9999999;
		maxval = -1;
	}
	{
		lines++;
		sum += $3;

		if ( $3 < minval )
			minval = $3;

		if ( $3 > maxval )
			maxval = $3;
	}
	END {
		avgval = sum / lines;
		printf( "avg %11.4f, min %11.4f, max %11.4f  (op/sec)\n", avgval, minval, maxval );
	}
	'

    wait $PID 2>/dev/null
done

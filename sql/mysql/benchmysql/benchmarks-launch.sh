#!/bin/bash

# This script 'benchmarks-launch.sh' calls all other benchmark scripts.

export MYSQL_BUILDS_DIR=".."

export SYSBENCH_SCRIPTS_DIR="/usr/share/sysbench"

#SYSBENCH_ALL_SCRIPTS="$(ls $SYSBENCH_SCRIPTS_DIR/oltp_*.lua $SYSBENCH_SCRIPTS_DIR/select_random_*.lua)"
SYSBENCH_ALL_SCRIPTS="$(ls $SYSBENCH_SCRIPTS_DIR/oltp_read_write.lua)"

SYSBENCH_ALL_SCRIPTS="$(echo $SYSBENCH_ALL_SCRIPTS | xargs basename -a | grep -v oltp_common\.lua | xargs)"


export MYSQL_DATA_DIR="/tmp/mysql-benchmarks-datadir"

INSCRIPT_BENCH_USE_VTUNE="false"
INSCRIPT_BENCH_USE_TIME="false"


#MYSQLBUILDLIST=$(echo "$MYSQLBUILDLIST" | sed "s/[,\n\t]/ /g" | sed "s/\s\s\+/ /g")
MYSQLBUILDLIST=$(ls -d "$MYSQL_BUILDS_DIR"/mysql-tsan "$MYSQL_BUILDS_DIR"/mysql-tsan-* "$MYSQL_BUILDS_DIR"/mysql-orig | sed  -e "y/,\n\t/   /"  -e "s/\s\s\+/ /g"  -e "s/^\s//1" | xargs basename -a | xargs)

#MYSQLBUILDLIST="mysql-tsan"

# Debug string with exit:
#echo "$MYSQLBUILDLIST" && echo && echo "$SYSBENCH_ALL_SCRIPTS" && exit



logmessage() {
	echo -e "\n  \e[94m$1\e[m  \n"
}

set -e

./server-datadir-init.sh || logmessage "Server datadir initialized already."


export BENCH_USE_TIME=false
export BENCH_USE_VTUNE=false

[ "$INSCRIPT_BENCH_USE_TIME" = "true" ] && export BENCH_USE_TIME=true
[ "$INSCRIPT_BENCH_USE_VTUNE" = "true" ] && export BENCH_USE_VTUNE=true

# Args parsing:
while true; do
	case "$1" in
		"--time")
		    logmessage "Time and peak memory profiling (via /usr/bin/time) will be enabled for runs."
			export BENCH_USE_TIME=true
			;;
		"--vtune")
		    logmessage "VTune profiling will be enabled for runs."
			export BENCH_USE_VTUNE=true
			;;
		"-h"|"--help")
		    logmessage "Usage: \n\t$0 [--vtune|--time]\t Run benchmarks (also with VTune or '/usr/bin/time')\n\t$0 -h|--help\t Show this help"
			exit 0
			;;
	esac

	# `do { ... } while ( shift() );`
	shift || break
done

if [[ "$BENCH_USE_TIME" == "true" && "$BENCH_USE_VTUNE" == "true" ]]; then
	logmessage "\e[31mCannot use both --time and --vtune"
	exit 1
fi

#echo time $BENCH_USE_TIME, vtune $BENCH_USE_VTUNE
#exit


for BENCHSCRIPT in $SYSBENCH_ALL_SCRIPTS; do
	logmessage "\n######################=#==- =##+- ===-=--- -\n#\n# \e[1;36m$BENCHSCRIPT\e[0;94m \n#\n#####===-=-- -   -"

	for BUILD in $MYSQLBUILDLIST; do
		OUTPUT_FILE_NAME="benchmark_${BUILD/mysql-/}_$(echo ${BENCHSCRIPT//_/-} | sed "s/\.lua/.txt/1" | xargs basename)"

		export MYSQL_DIR="$MYSQL_BUILDS_DIR/$BUILD/bin"
		export SYSBENCH_SCRIPT_FILENAME="$BENCHSCRIPT"
		#export SYSBENCH_RUN_SECONDS=60

		if [ "$BENCH_USE_VTUNE" = "true" ]; then
			vtune_result_dir="vtune_results/${BUILD}_${BENCHSCRIPT%.lua}"
			[ -d "$vtune_result_dir" ] && echo "Moving previous '$vtune_result_dir' to '$vtune_result_dir-old'" && mv -f "$vtune_result_dir" "$vtune_result_dir-old"

			mkdir -p "$vtune_result_dir"
			export V_TUNE_RESULT_DIR="$vtune_result_dir"
			echo "VTune results will be saved to $vtune_result_dir"
		fi

		[ ! -f "$MYSQL_DIR/mysqld" ] && logmessage "\e[93mNo MyQSL found at \"$MYSQL_DIR\", skipping." && continue

		logmessage " ===== Started: $BUILD ===== "

		./server-run.sh || { logmessage "\e[31mCannot run the server for build $BUILD."; continue; }

		logmessage "Ready to initialize the benchmark database."

		./bench-init.sh

		logmessage "\e[92mBenchmark database initialized. Launching..."

		./bench-run.sh | tee "$OUTPUT_FILE_NAME"

		logmessage " ===== Finished for $BUILD / $BENCHSCRIPT (output file $OUTPUT_FILE_NAME) ===== "

		./bench-cleanup.sh
		./server-shutdown.sh

		if [ -f "time.log" ]; then
			grep "Maximum resident set size" time.log >> "$OUTPUT_FILE_NAME"
			rm time.log
		else
			echo "No \"time.log\", so no resident memory peak size."
		fi
	done
done

./bench-post-logs2csv.sh

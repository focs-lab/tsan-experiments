#!/bin/bash

# This script 'benchmarks-launch.sh' calls all other benchmark scripts.

export MYSQL_BUILDS_DIR=".."

export SYSBENCH_SCRIPTS_DIR="/usr/share/sysbench"

SYSBENCH_ALL_SCRIPTS="$(ls $SYSBENCH_SCRIPTS_DIR/oltp_*.lua $SYSBENCH_SCRIPTS_DIR/select_random_*.lua)"
# Or override with some specific scripts:
SYSBENCH_ALL_SCRIPTS="oltp_read_write.lua"


export MYSQL_DATA_DIR="/tmp/mysql-benchmarks-datadir"

# Force using of VTune or `time`:
INSCRIPT_BENCH_USE_VTUNE="false"
INSCRIPT_BENCH_USE_TIME="false"


#MYSQLBUILDLIST=$(echo "$MYSQLBUILDLIST" | sed "s/[,\n\t]/ /g" | sed "s/\s\s\+/ /g")
MYSQLBUILDLIST=$(ls -d "$MYSQL_BUILDS_DIR"/mysql-tsan "$MYSQL_BUILDS_DIR"/mysql-tsan-* "$MYSQL_BUILDS_DIR"/mysql-orig | sed  -e "y/,\n\t/   /"  -e "s/\s\s\+/ /g"  -e "s/^\s//1" | xargs basename -a | xargs)

#MYSQLBUILDLIST="mysql-tsan-dom-ea-lo-st-swmr"


logmessage() {
	echo -e "\n  \e[94m$1\e[m  \n"
}

set -e

export MYSQL_DIR="$MYSQL_BUILDS_DIR/$(echo $MYSQLBUILDLIST | tr ' ' '\n' | head -n1)/bin"
./server-datadir-init.sh || logmessage "Server datadir initialized already."

export BENCH_USE_TIME=false
export BENCH_USE_VTUNE=false

SYSBENCH_ALL_SCRIPTS="$(echo $SYSBENCH_ALL_SCRIPTS | xargs basename -a | grep -v oltp_common\.lua | xargs)"


[ "$INSCRIPT_BENCH_USE_TIME" = "true" ] && export BENCH_USE_TIME=true
[ "$INSCRIPT_BENCH_USE_VTUNE" = "true" ] && export BENCH_USE_VTUNE=true
BENCH_RUN_OPTION=false

print_usage() {
	logmessage "Usage:
	$0 \t\t\t Print the data about run
	$0 -r|--run\t\t Run benchmarks
	$0 -t|--time\t Add '/usr/bin/time' call to run
	$0 --vtune\t\t Add VTune profiling to run
	$0 -h|--help\t Show this help"
}

# Args parsing:
while true; do
	case "$1" in
		"--time"|"-t")
		    logmessage "Time and peak memory profiling (via /usr/bin/time) will be enabled for runs."
			export BENCH_USE_TIME=true
			;;
		"--vtune")
		    logmessage "VTune profiling will be enabled for runs."
			export BENCH_USE_VTUNE=true
			;;
		"--run"|"-r")
			BENCH_RUN_OPTION=true
			;;
		"-h"|"--help")
			print_usage
			exit 0
			;;
		"") ;;
		*)	echo "Wrong arg '$1'."
			exit 1
			;;
	esac

	# `do { ... } while ( shift() );`
	shift || break
done

if [[ "$BENCH_USE_TIME" == "true" && "$BENCH_USE_VTUNE" == "true" ]]; then
	logmessage "\e[31mCannot use both --time and --vtune"
	exit 1
fi


# Debug strings:
echo -e "\$MYSQLBUILDLIST:\n$MYSQLBUILDLIST\n"
echo -e "\$SYSBENCH_ALL_SCRIPTS:\n$SYSBENCH_ALL_SCRIPTS\n"
echo "Use /usr/bin/time : $BENCH_USE_TIME"
echo "Use VTune         : $BENCH_USE_VTUNE"

if [ "$BENCH_RUN_OPTION" != "true" ]; then
	logmessage "Type \"\e[96m$0 --run\e[94m\" to launch the benchmarks!\n  Type \"\e[96m$0 --help\e[94m\" to get the full help."
	exit
fi


for BENCHSCRIPT in $SYSBENCH_ALL_SCRIPTS; do
	logmessage "\n######################=#==- =##+- ===-=--- -\n#\n# \e[1;36m$BENCHSCRIPT\e[0;94m \n#\n#####===-=-- -   -"

	for BUILD in $MYSQLBUILDLIST; do
		OUTPUT_FILE_NAME="benchmark_${BUILD/mysql-/}_$(echo ${BENCHSCRIPT//_/-} | sed "s/\.lua/.txt/1" | xargs basename)"

		export MYSQL_DIR="$MYSQL_BUILDS_DIR/$BUILD/bin"
		export SYSBENCH_SCRIPT_FILENAME="$BENCHSCRIPT"
		#export SYSBENCH_RUN_SECONDS=10

		if [ "$BENCH_USE_VTUNE" = "true" ]; then
			VTUNE_RESULT_DIR="vtune_results/${BUILD}_${BENCHSCRIPT%.lua}"
			[ -d "$VTUNE_RESULT_DIR" ] && echo "Moving previous '$VTUNE_RESULT_DIR' to '$VTUNE_RESULT_DIR-old'" && mv -f "$VTUNE_RESULT_DIR" "$VTUNE_RESULT_DIR-old"

			mkdir -p "$VTUNE_RESULT_DIR"
			export V_TUNE_RESULT_DIR="$VTUNE_RESULT_DIR"
			echo "VTune results will be saved to $VTUNE_RESULT_DIR"
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

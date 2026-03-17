#!/bin/bash

# This script 'benchmarks-launch-progress.sh' calls all other benchmark scripts
# and additionally prints overall progress / remaining work estimates.

export MYSQL_BUILDS_DIR=".."

export SYSBENCH_SCRIPTS_DIR="/usr/share/sysbench"

# Select all or override with some specific scripts:
#SYSBENCH_ALL_SCRIPTS="$(ls $SYSBENCH_SCRIPTS_DIR/oltp_*.lua $SYSBENCH_SCRIPTS_DIR/select_random_*.lua)"
#SYSBENCH_ALL_SCRIPTS="oltp_read_write.lua"
SYSBENCH_ALL_SCRIPTS="oltp_read_write.lua oltp_read_only.lua oltp_write_only.lua select_random_ranges.lua select_random_points.lua"
TRACE_ONLY_SYSBENCH_SCRIPT="oltp_read_write.lua"


export MYSQL_DATA_DIR="/tmp/mysql-benchmarks-datadir"

# Force using of VTune or `time`:
INSCRIPT_BENCH_USE_VTUNE="false"
INSCRIPT_BENCH_USE_TIME="false"
INSCRIPT_BENCH_USE_TRACE="false"
INSCRIPT_BENCH_TRACE_COMPRESSOR="zstd"
INSCRIPT_BENCH_TRACE_DIR="trace_logs"


# Select all or override with some specific builds:
#MYSQLBUILDLIST=$(echo "$MYSQLBUILDLIST" | sed "s/[,\n\t]/ /g" | sed "s/\s\s\+/ /g")
MYSQLBUILDLIST=$(ls -d "$MYSQL_BUILDS_DIR"/mysql-tsan "$MYSQL_BUILDS_DIR"/mysql-tsan-* "$MYSQL_BUILDS_DIR"/mysql-orig | sed  -e "y/,\n\t/   /"  -e "s/\s\s\+/ /g"  -e "s/^\s//1" | xargs basename -a | xargs)
#MYSQLBUILDLIST="mysql-orig mysql-tsan mysql-tsan-dom mysql-tsan-dom_peeling mysql-tsan-stmt"
#MYSQLBUILDLIST="mysql-tsan mysql-tsan-dom mysql-tsan-dom_peeling mysql-tsan-stmt mysql-orig"


logmessage() {
	echo -e "\n  \e[94m$1\e[m  \n"
}

validate_trace_compressor() {
	case "$1" in
		"zstd"|"lz4"|"none") ;;
		*)
			echo "Wrong trace compressor '$1'. Expected one of: zstd, lz4, none."
			exit 1
			;;
	esac
}

trace_suffix_for() {
	case "$1" in
		"zstd") echo "zst" ;;
		"lz4") echo "lz4" ;;
		"none") echo "log" ;;
	esac
}

word_count() {
	if [ -z "$1" ]; then
		echo 0
	else
		echo "$1" | wc -w | xargs
	fi
}

format_duration() {
	local total_seconds="${1:-0}"
	local hours=$((total_seconds / 3600))
	local minutes=$(((total_seconds % 3600) / 60))
	local seconds=$((total_seconds % 60))
	printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
}

format_eta() {
	if [ "$RUNS_DONE" -le 0 ]; then
		echo "n/a"
		return
	fi

	local now_ts
	now_ts=$(date +%s)
	local elapsed=$((now_ts - LAUNCH_TS))
	local remaining=$((TOTAL_RUNS - RUNS_DONE))
	local eta_seconds=$(((elapsed * remaining) / RUNS_DONE))
	format_duration "$eta_seconds"
}

print_progress_line() {
	local phase="$1"
	local now_ts
	now_ts=$(date +%s)
	local elapsed=$((now_ts - LAUNCH_TS))
	local elapsed_text
	elapsed_text=$(format_duration "$elapsed")
	local left_total=$((TOTAL_RUNS - RUNS_DONE))
	local queued_after_current=$((TOTAL_RUNS - CURRENT_RUN_INDEX))
	local eta
	eta=$(format_eta)

	echo "[PROGRESS] $phase | run ${CURRENT_RUN_INDEX}/${TOTAL_RUNS} | script ${CURRENT_SCRIPT_INDEX}/${SCRIPT_COUNT} | build ${CURRENT_BUILD_INDEX}/${BUILD_COUNT} | completed=${RUNS_DONE} left_total=${left_total} queued_after_current=${queued_after_current} | ok=${RUNS_OK} skipped=${RUNS_SKIPPED} failed=${RUNS_FAILED} | elapsed=${elapsed_text} | eta=${eta}"
}

finish_current_run() {
	local outcome="$1"
	RUNS_DONE=$((RUNS_DONE + 1))
	case "$outcome" in
		ok)
			RUNS_OK=$((RUNS_OK + 1))
			;;
		skipped)
			RUNS_SKIPPED=$((RUNS_SKIPPED + 1))
			;;
		failed)
			RUNS_FAILED=$((RUNS_FAILED + 1))
			;;
	esac
	print_progress_line "finished"
}

print_final_summary() {
	local status_label="$1"
	local now_ts
	now_ts=$(date +%s)
	local elapsed=$((now_ts - LAUNCH_TS))
	echo "[SUMMARY] ${status_label} | total=${TOTAL_RUNS} done=${RUNS_DONE} ok=${RUNS_OK} skipped=${RUNS_SKIPPED} failed=${RUNS_FAILED} left=$((TOTAL_RUNS - RUNS_DONE)) | elapsed=$(format_duration "$elapsed")"
}

handle_interrupt() {
	local signal_name="$1"
	logmessage "\e[93mInterrupted by ${signal_name}."
	print_final_summary "interrupted"
	exit 130
}

set -e

FIRST_BUILD=$(echo $MYSQLBUILDLIST | tr ' ' '\n' | head -n1)
export MYSQL_DIR="$MYSQL_BUILDS_DIR/$FIRST_BUILD/bin"
./server-datadir-init.sh || logmessage "Server datadir initialized already."

export BENCH_USE_TIME=false
export BENCH_USE_VTUNE=false
export BENCH_USE_TRACE=false
export BENCH_TRACE_COMPRESSOR="${INSCRIPT_BENCH_TRACE_COMPRESSOR:-zstd}"
export BENCH_TRACE_DIR="$INSCRIPT_BENCH_TRACE_DIR"

SYSBENCH_ALL_SCRIPTS="$(echo $SYSBENCH_ALL_SCRIPTS | xargs basename -a | grep -v oltp_common\.lua | xargs)"


[ "$INSCRIPT_BENCH_USE_TIME" = "true" ] && export BENCH_USE_TIME=true
[ "$INSCRIPT_BENCH_USE_VTUNE" = "true" ] && export BENCH_USE_VTUNE=true
[ "$INSCRIPT_BENCH_USE_TRACE" = "true" ] && export BENCH_USE_TRACE=true
BENCH_TRACE_COMPRESSOR="${BENCH_TRACE_COMPRESSOR:-zstd}"
validate_trace_compressor "$BENCH_TRACE_COMPRESSOR"
BENCH_RUN_OPTION=false

print_usage() {
	logmessage "Usage:
	$0 \t\t\t Print the data about run
	$0 -r|--run\t\t Run benchmarks
	$0 -t|--time\t Add '/usr/bin/time' call to run
	$0 --vtune\t\t Add VTune profiling to run
	$0 --trace\t\t Capture mysqld trace to a per-run file
	$0 --trace-raw\t\t Capture mysqld trace without compression
	$0 --trace-dir DIR\t Directory for trace files (default: $INSCRIPT_BENCH_TRACE_DIR)
	$0 --trace-compressor {zstd|lz4|none}\t Compression for trace files
	$0 -h|--help\t Show this help"
}

# Args parsing:
while [ -n "$1" ]; do
	case "$1" in
		"--time"|"-t")
		    logmessage "Time and peak memory profiling (via /usr/bin/time) will be enabled for runs."
			export BENCH_USE_TIME=true
			;;
		"--vtune")
		    logmessage "VTune profiling will be enabled for runs."
			export BENCH_USE_VTUNE=true
			;;
		"--trace")
			logmessage "mysqld trace capture will be enabled for runs."
			export BENCH_USE_TRACE=true
			;;
		"--trace-raw")
			logmessage "mysqld trace capture will be enabled without compression."
			export BENCH_USE_TRACE=true
			export BENCH_TRACE_COMPRESSOR=none
			;;
		"--trace-dir")
			shift || { echo "Missing value for --trace-dir"; exit 1; }
			[ -z "$1" ] && { echo "Missing value for --trace-dir"; exit 1; }
			export BENCH_TRACE_DIR="$1"
			export BENCH_USE_TRACE=true
			;;
		"--trace-dir="*)
			export BENCH_TRACE_DIR="${1#*=}"
			[ -z "$BENCH_TRACE_DIR" ] && { echo "Missing value for --trace-dir"; exit 1; }
			export BENCH_USE_TRACE=true
			;;
		"--trace-compressor")
			shift || { echo "Missing value for --trace-compressor"; exit 1; }
			validate_trace_compressor "$1"
			export BENCH_TRACE_COMPRESSOR="$1"
			export BENCH_USE_TRACE=true
			;;
		"--trace-compressor="*)
			export BENCH_TRACE_COMPRESSOR="${1#*=}"
			validate_trace_compressor "$BENCH_TRACE_COMPRESSOR"
			export BENCH_USE_TRACE=true
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

if [ "$BENCH_USE_TRACE" = "true" ]; then
	BENCH_TRACE_COMPRESSOR="${BENCH_TRACE_COMPRESSOR:-zstd}"
	SYSBENCH_ALL_SCRIPTS="$TRACE_ONLY_SYSBENCH_SCRIPT"
fi

BUILD_COUNT=$(word_count "$MYSQLBUILDLIST")
SCRIPT_COUNT=$(word_count "$SYSBENCH_ALL_SCRIPTS")
TOTAL_RUNS=$((BUILD_COUNT * SCRIPT_COUNT))
RUNS_DONE=0
RUNS_OK=0
RUNS_SKIPPED=0
RUNS_FAILED=0
CURRENT_RUN_INDEX=0
CURRENT_SCRIPT_INDEX=0
CURRENT_BUILD_INDEX=0
LAUNCH_TS=$(date +%s)

trap 'handle_interrupt SIGINT' INT
trap 'handle_interrupt SIGTERM' TERM

# Debug strings:
echo -e "\$MYSQLBUILDLIST:\n$MYSQLBUILDLIST\n"
echo -e "\$SYSBENCH_ALL_SCRIPTS:\n$SYSBENCH_ALL_SCRIPTS\n"
echo "Use /usr/bin/time : $BENCH_USE_TIME"
echo "Use VTune         : $BENCH_USE_VTUNE"
echo "Use trace capture : $BENCH_USE_TRACE"
echo "Trace compressor  : $BENCH_TRACE_COMPRESSOR"
echo "Trace dir         : $BENCH_TRACE_DIR"
echo "Planned runs total: $TOTAL_RUNS ($SCRIPT_COUNT scripts x $BUILD_COUNT builds)"

if [ "$BENCH_RUN_OPTION" != "true" ]; then
	logmessage "Type \"\e[96m$0 --run\e[94m\" to launch the benchmarks!\n  Type \"\e[96m$0 --help\e[94m\" to get the full help."
	exit
fi

if [ "$TOTAL_RUNS" -le 0 ]; then
	logmessage "\e[93mNo benchmark runs selected, nothing to do."
	exit 0
fi

for BENCHSCRIPT in $SYSBENCH_ALL_SCRIPTS; do
	CURRENT_SCRIPT_INDEX=$((CURRENT_SCRIPT_INDEX + 1))
	CURRENT_BUILD_INDEX=0
	logmessage "\n######################=#==- =##+- ===-=--- -\n#\n# \e[1;36m$BENCHSCRIPT\e[0;94m \n#\n#####===-=-- -   -"

	for BUILD in $MYSQLBUILDLIST; do
		CURRENT_BUILD_INDEX=$((CURRENT_BUILD_INDEX + 1))
		CURRENT_RUN_INDEX=$((RUNS_DONE + 1))
		OUTPUT_FILE_NAME="benchmark_${BUILD/mysql-/}_$(echo ${BENCHSCRIPT//_/-} | sed "s/\.lua/.txt/1" | xargs basename)"

		export MYSQL_DIR="$MYSQL_BUILDS_DIR/$BUILD/bin"
		export SYSBENCH_SCRIPT_FILENAME="$BENCHSCRIPT"
		#export SYSBENCH_RUN_SECONDS=5

		if [ "$BENCH_USE_TRACE" = "true" ]; then
			mkdir -p "$BENCH_TRACE_DIR"
			TRACE_SUFFIX=$(trace_suffix_for "$BENCH_TRACE_COMPRESSOR")
			export BENCH_TRACE_OUTPUT_FILE="$BENCH_TRACE_DIR/${OUTPUT_FILE_NAME%.txt}.trace.$TRACE_SUFFIX"
			echo "mysqld trace will be saved to $BENCH_TRACE_OUTPUT_FILE"
		else
			unset BENCH_TRACE_OUTPUT_FILE
		fi

		if [ "$BENCH_USE_VTUNE" = "true" ]; then
			VTUNE_RESULT_DIR="vtune_results/${BUILD}_${BENCHSCRIPT%.lua}"
			[ -d "$VTUNE_RESULT_DIR" ] && echo "Moving previous '$VTUNE_RESULT_DIR' to '$VTUNE_RESULT_DIR-old'" && mv -f "$VTUNE_RESULT_DIR" "$VTUNE_RESULT_DIR-old"

			mkdir -p "$VTUNE_RESULT_DIR"
			export V_TUNE_RESULT_DIR="$VTUNE_RESULT_DIR"
			echo "VTune results will be saved to $VTUNE_RESULT_DIR"
		fi

		print_progress_line "starting"
		echo "[RUN] build=$BUILD | script=$BENCHSCRIPT | output=$OUTPUT_FILE_NAME"

		if [ ! -x "$MYSQL_DIR/mysqld" ]; then
			logmessage "\e[93mNo executable MySQL server found at \"$MYSQL_DIR/mysqld\", skipping this build."
			finish_current_run skipped
			continue
		fi

		logmessage " ===== Started: $BUILD ===== "

		./server-run.sh || { logmessage "\e[31mCannot run the server for build $BUILD."; finish_current_run failed; continue; }

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

		finish_current_run ok
	done
done

./bench-post-logs2csv.sh
print_final_summary "done"


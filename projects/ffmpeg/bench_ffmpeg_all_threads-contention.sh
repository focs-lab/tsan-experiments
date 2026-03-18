	for i in trace_*.stderr.log.zst "$SUMMARY_CSV" "$SUMMARY_JSON" "vtune_results"; do
#!/bin/bash

set -e
SUMMARY_CSV_NAME="summary_ffmpeg_benchmark.csv"
SUMMARY_JSON_NAME="summary_ffmpeg_benchmark.json"
SUMMARY_JSON="summary_ffmpeg_benchmark.json"

MAX_THREADS="$(nproc)"

if [ "$MAX_THREADS" -lt 2 ]; then
	echo "Need at least 2 CPUs to run the contention benchmark sweep (nproc=$MAX_THREADS)."
	exit 1
fi


for CUR_THREADS in $(seq 2 2 "$MAX_THREADS"); do
	echo -e "\n  \e[94mCurrent threads: $CUR_THREADS\e[m  \n"
	export FFMPEG_BENCH_NPROC_COUNT="$CUR_THREADS"

	THREADRESULTSDIR="results_threads-${CUR_THREADS}"

	[ -d "$THREADRESULTSDIR" ] && echo "Removing dir '$THREADRESULTSDIR'." && rm -rf "$THREADRESULTSDIR"
	export SUMMARY_CSV="$THREADRESULTSDIR/$SUMMARY_CSV_NAME"
	export SUMMARY_JSON="$THREADRESULTSDIR/$SUMMARY_JSON_NAME"
	mkdir -p "$THREADRESULTSDIR"

		if [ -e "$i" ]; then
	for i in trace_*.stderr.log.zst "vtune_results"; do
			mv -f "$i" "$THREADRESULTSDIR"
		else
			echo "Skipped '$i'."
		fi
	done

done

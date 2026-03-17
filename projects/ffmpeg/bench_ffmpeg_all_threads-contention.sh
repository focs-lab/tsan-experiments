#!/bin/bash

set -e

SUMMARY_CSV="summary_ffmpeg_benchmark.csv"
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
	mkdir -p "$THREADRESULTSDIR"

	./bench_ffmpeg_all.sh

	for i in trace_*.stderr.log.zst "$SUMMARY_CSV" "$SUMMARY_JSON" "vtune_results"; do
		if [ -e "$i" ]; then
			echo "Move '$i' to '$THREADRESULTSDIR'."
			mv -f "$i" "$THREADRESULTSDIR"
		else
			echo "Skipped '$i'."
		fi
	done

done

#!/bin/bash

set -e

# --- Configuration ---
FF_TEST_VIDEO="./input/WatchingEyeTexture.mkv"
[ ! -f "$FF_TEST_VIDEO" ] && echo "No video file found at $FF_TEST_VIDEO" && exit 1

FF_BUILD_LIST_STR=$(ls -d ffmpeg-orig ffmpeg-tsan* 2>/dev/null | xargs)
[ -z "$FF_BUILD_LIST_STR" ] && echo "No FFmpeg builds found (directory pattern \"ffmpeg-tsan* ffmpeg-orig\")." && exit 2

#FF_BUILD_LIST_STR="ffmpeg-tsan-dom"; echo -e "\e[93mNote: \$FF_BUILD_LIST_STR overridden to '$FF_BUILD_LIST_STR'.\e[0m" && echo "(3-sec delay...)" && sleep 3

# Number of runs to average the results (force set to 1 with `--trace`):
RUNS_COUNT=3

[ -z "$FFMPEG_BENCH_NPROC_COUNT" ] && FFMPEG_BENCH_NPROC_COUNT="$(nproc)"

# --- Profiling Configuration (optional) ---
USE_VTUNE=false
VTUNE_SAMPLING_MODE="hw"
VTUNE_ANALYSIS_TYPE="hotspots"
TRACE_MODE=false

# --- Argument Parsing ---
for ARG in "$@"
do
	case $ARG in
		--vtune)
		USE_VTUNE=true
		echo "VTune profiling enabled."
		shift
		;;
		--trace)
		TRACE_MODE=true
		RUNS_COUNT=1
		echo "Trace mode enabled. Run count forced to 1."
		shift
		;;
	esac
done

# --- Check for required tools ---
if ! command -v /usr/bin/time > /dev/null 2>&1; then
	echo "The '/usr/bin/time' program was not found. Please install it."
	exit 3
fi
if ! command -v bc > /dev/null 2>&1; then
	echo "The 'bc' program was not found. It is required for floating-point math."
	exit 3
fi
if [ "$TRACE_MODE" = "true" ] && ! command -v zstd > /dev/null 2>&1; then
	echo "The 'zstd' program was not found. It is required for `--trace` stderr handling."
	exit 3
fi
if command -v jq > /dev/null 2>&1; then
	JQ_AVAILABLE=true
	JSON_RESULTS_FILE=$(mktemp)
	SUMMARY_JSON="summary_ffmpeg_benchmark.json"
	echo "jq found, will generate JSON output to $SUMMARY_JSON."
else
	JQ_AVAILABLE=false
	echo "jq not found, will generate CSV output only."
fi

# --- Codec Definitions ---
declare -A CODECS
CODECS[h264_libx264]="-c:v libx264 -preset medium -crf 23 ::mp4"
CODECS[h265_libx265]="-c:v libx265 -preset medium -crf 28 -tag:v hvc1 ::mp4"
CODECS[mjpeg]="-c:v mjpeg -pix_fmt yuvj420p -q:v 2 ::avi"
CODECS[copy_passthrough]="-c:v copy -c:a copy ::mkv"

# --- FFmpeg Benchmark Start ---
echo "--- FFmpeg Benchmark Start (using /usr/bin/time) ---"
echo "Builds to test: $FF_BUILD_LIST_STR"
echo "Video file: $FF_TEST_VIDEO"
echo "Runs per test: $RUNS_COUNT"
echo ""

SUMMARY_CSV="summary_ffmpeg_benchmark.csv"
echo "Codec,FFBUILD,runs_completed,mean_time_s,stddev_time_s,min_time_s,max_time_s,mean_user_s,mean_system_s,max_mem_kb,command_template" > "$SUMMARY_CSV"

read -ra FF_BUILD_ARRAY <<< "$FF_BUILD_LIST_STR"
TIME_OUTPUT_FILE=$(mktemp)
trap 'rm -f "$TIME_OUTPUT_FILE" ${JSON_RESULTS_FILE:-}' EXIT

for CODEC_KEY in "${!CODECS[@]}"; do
	CODEC_INFO="${CODECS[$CODEC_KEY]}"
	ENCODING_PARAMS="${CODEC_INFO%%::*}"
	OUTPUT_EXT="${CODEC_INFO##*::}"

	for BUILD in "${FF_BUILD_ARRAY[@]}"; do
		echo "--- Benchmarking: Codec [$CODEC_KEY], Build [$BUILD] ---"

		ELAPSED_TIMES=()
		USER_TIMES=()
		SYSTEM_TIMES=()
		MEM_USAGES=()

		export LD_LIBRARY_PATH="$BUILD/lib/:$LD_LIBRARY_PATH"
		CMD_TEMPLATE="$BUILD/bin/ffmpeg -hide_banner -i \"$FF_TEST_VIDEO\" -threads $FFMPEG_BENCH_NPROC_COUNT -y $ENCODING_PARAMS -loglevel error /dev/shm/out.$OUTPUT_EXT"

		if [ "$USE_VTUNE" = true ]; then
			VTUNE_RESULT_DIR="vtune_results/${BUILD}_${CODEC_KEY}"
			mkdir -p "$VTUNE_RESULT_DIR"

			VTUNE_OPTIONS="--collect=$VTUNE_ANALYSIS_TYPE --result-dir=$VTUNE_RESULT_DIR \
				-knob sampling-mode=$VTUNE_SAMPLING_MODE \
				-knob enable-stack-collection=true \
				-data-limit=5000"

			CMD_TEMPLATE="vtune $VTUNE_OPTIONS -- $CMD_TEMPLATE"
			echo "  VTune enabled. Results will be in: $VTUNE_RESULT_DIR"
		fi

		echo -e "\n\e[96;1m$CMD_TEMPLATE\e[0m\n"

		for (( i=1; i<=RUNS_COUNT; i++ )); do
			echo -n "  Run $i/$RUNS_COUNT... "

			if [ "$TRACE_MODE" = true ]; then
				TRACE_LOG_FILE="trace_${BUILD}_${CODEC_KEY}.stderr.log.zst"
				echo -n "Tracing stderr to ${TRACE_LOG_FILE}... "

				/usr/bin/time -v -o "$TIME_OUTPUT_FILE" bash -c "$CMD_TEMPLATE" 2>&1 >/dev/null | zstd -1 -f -o "$TRACE_LOG_FILE" || {
					echo "FAILED! Check trace log. This run will be skipped."
					continue
				}
			else
				/usr/bin/time -v -o "$TIME_OUTPUT_FILE" bash -c "$CMD_TEMPLATE" >/dev/null 2>&1 || {
					echo "FAILED! This run will be skipped."
					continue
				}
			fi

			ELAPSED_RAW=$(grep "Elapsed (wall clock) time" "$TIME_OUTPUT_FILE" | awk '{print $NF}')
			if [[ $ELAPSED_RAW == *":"* ]]; then
				ELAPSED_S=$(echo "$ELAPSED_RAW" | awk -F: '{ secs=0; for(i=1;i<=NF;i++) secs = secs*60 + $i; print secs }')
				#"#
			else
				ELAPSED_S=$ELAPSED_RAW
			fi

			USER_S=$(grep "User time (seconds)" "$TIME_OUTPUT_FILE" | awk '{print $NF}')
			SYSTEM_S=$(grep "System time (seconds)" "$TIME_OUTPUT_FILE" | awk '{print $NF}')
			MAX_MEM=$(grep "Maximum resident set size" "$TIME_OUTPUT_FILE" | awk '{print $NF}')

			echo "OK (Time: ${ELAPSED_S}s, Mem: ${MAX_MEM}KB)"

			ELAPSED_TIMES+=("$ELAPSED_S")
			USER_TIMES+=("$USER_S")
			SYSTEM_TIMES+=("$SYSTEM_S")
			MEM_USAGES+=("$MAX_MEM")
		done

		SUCCESSFUL_RUNS=${#ELAPSED_TIMES[@]}
		if [ "$SUCCESSFUL_RUNS" -eq 0 ]; then
			echo "  No successful runs for this configuration. Skipping."
			echo "--------------------------------------------------------"
			echo ""
			continue
		fi

		# --- Calculate Statistics ---
		SUM_TIME=$(printf "%s\n" "${ELAPSED_TIMES[@]}" | paste -sd+ - | bc)
		MEAN_TIME=$(echo "scale=4; $SUM_TIME / $SUCCESSFUL_RUNS" | bc)
		MIN_TIME=$(printf "%s\n" "${ELAPSED_TIMES[@]}" | sort -n | head -1)
		MAX_TIME=$(printf "%s\n" "${ELAPSED_TIMES[@]}" | sort -n | tail -1)

		SUM_SQ_DIFF=0
		for t in "${ELAPSED_TIMES[@]}"; do
			DIFF=$(echo "$t - $MEAN_TIME" | bc)
			SUM_SQ_DIFF=$(echo "$SUM_SQ_DIFF + ($DIFF * $DIFF)" | bc)
		done

		if [ "$SUCCESSFUL_RUNS" -gt 1 ]; then
			STDDEV_TIME=$(echo "scale=4; sqrt($SUM_SQ_DIFF / ($SUCCESSFUL_RUNS))" | bc)
		else
			STDDEV_TIME=0
		fi

		SUM_USER=$(printf "%s\n" "${USER_TIMES[@]}" | paste -sd+ - | bc)
		MEAN_USER=$(echo "scale=4; $SUM_USER / $SUCCESSFUL_RUNS" | bc)

		SUM_SYSTEM=$(printf "%s\n" "${SYSTEM_TIMES[@]}" | paste -sd+ - | bc)
		MEAN_SYSTEM=$(echo "scale=4; $SUM_SYSTEM / $SUCCESSFUL_RUNS" | bc)

		MAX_MEM_PEAK=$(printf "%s\n" "${MEM_USAGES[@]}" | sort -n | tail -1)

		# --- Output results and append to files ---
		echo "  Results: Time(avg±std): ${MEAN_TIME}s ± ${STDDEV_TIME}s | Mem(peak): ${MAX_MEM_PEAK}KB | Runs: ${SUCCESSFUL_RUNS}/${RUNS_COUNT}"

		CSV_LINE=$(printf '"%s","%s","%s",%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d,"%s"\n' \
			"$CODEC_KEY" "$BUILD" "${SUCCESSFUL_RUNS}/${RUNS_COUNT}" "$MEAN_TIME" "$STDDEV_TIME" \
			"$MIN_TIME" "$MAX_TIME" "$MEAN_USER" "$MEAN_SYSTEM" "$MAX_MEM_PEAK" "$CMD_TEMPLATE")
		echo "$CSV_LINE" >> "$SUMMARY_CSV"

		if [ "$JQ_AVAILABLE" = true ]; then
			jq -n \
				--arg codec "$CODEC_KEY" --arg build "$BUILD" --argjson runs_successful "$SUCCESSFUL_RUNS" \
				--argjson runs_total "$RUNS_COUNT" --argjson mean_time "$MEAN_TIME" --argjson stddev_time "$STDDEV_TIME" \
				--argjson min_time "$MIN_TIME" --argjson max_time "$MAX_TIME" --argjson mean_user "$MEAN_USER" \
				--argjson mean_system "$MEAN_SYSTEM" --argjson max_mem_kb "$MAX_MEM_PEAK" --arg command_template "$CMD_TEMPLATE" \
				'{ "codec": $codec, "build": $build, "runs": { "successful": $runs_successful, "total": $runs_total }, "time": { "mean_s": $mean_time, "stddev_s": $stddev_time, "min_s": $min_time, "max_s": $max_time }, "cpu": { "mean_user_s": $mean_user, "mean_system_s": $mean_system }, "memory": { "max_peak_kb": $max_mem_kb }, "command_template": $command_template }' >> "$JSON_RESULTS_FILE"
		fi

		echo "--------------------------------------------------------"
		echo ""
	done
	rm -f "/dev/shm/out.$OUTPUT_EXT"
done

if [ "$JQ_AVAILABLE" = true ]; then
	jq -s '{benchmarks: .}' "$JSON_RESULTS_FILE" > "$SUMMARY_JSON"
	echo "JSON results have been finalized in $SUMMARY_JSON"
fi

echo "Benchmark finished. CSV results are in $SUMMARY_CSV"

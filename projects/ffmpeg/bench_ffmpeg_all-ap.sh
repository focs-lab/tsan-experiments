#!/bin/bash

set -e

# --- VTune Profiling & Trace Configuration (optional) ---
USE_VTUNE=false
TRACE_MODE=false
TRACES_DIR="traces"
VTUNE_SAMPLING_MODE="hw"
VTUNE_ANALYSIS_TYPE="hotspots"

# --- Argument Parsing ---
# This loop handles flags like --vtune and trace
for arg in "$@"; do
    case $arg in
        --vtune)
        USE_VTUNE=true
        ;;
        trace)
        TRACE_MODE=true
        ;;
    esac
done

# --- Configuration based on modes ---
if [ "$TRACE_MODE" = true ]; then
    FFTESTVIDEO="./input/WatchingEyeTexture.for_trace.mkv"
    RUNS_COUNT=1
    echo "Trace mode enabled. Number of runs will be 1."
    if ! command -v zstd > /dev/null 2>&1; then
        echo "Error: 'zstd' is not found, but is required for trace mode." >&2
        exit 1
    fi
    mkdir -p "$TRACES_DIR"
    echo "Compressed traces will be saved to '$TRACES_DIR/'."
else
    FFTESTVIDEO="./input/WatchingEyeTexture.mkv"
    RUNS_COUNT=3
fi

[ ! -f "$FFTESTVIDEO" ] && echo "No video file found at $FFTESTVIDEO" && exit 1

FF_BUILD_LIST_STR=$(ls -d ffmpeg-orig ffmpeg-tsan* 2>/dev/null | xargs)
[ -z "$FF_BUILD_LIST_STR" ] && echo "No FFmpeg builds found (directory pattern \"ffmpeg-tsan* ffmpeg-orig\")." && exit 2


if [ "$USE_VTUNE" = true ]; then
    RUNS_COUNT=1
    echo "VTune profiling enabled."
fi


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
JQ_AVAILABLE=false
if [ "$TRACE_MODE" = false ]; then
    if command -v jq > /dev/null 2>&1; then
        JQ_AVAILABLE=true
        JSON_RESULTS_FILE=$(mktemp)
        SUMMARY_JSON="summary_ffmpeg_benchmark.json"
        echo "jq found, will generate JSON output to $SUMMARY_JSON."
    else
        echo "jq not found, will generate CSV output only."
    fi
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

        export LD_LIBRARY_PATH="$build/lib/:$LD_LIBRARY_PATH"
        CMD_TEMPLATE="$build/bin/ffmpeg -hide_banner -i $FFTESTVIDEO -threads $(nproc) -y $encoding_params -loglevel error /dev/shm/out.$output_ext"

		export LD_LIBRARY_PATH="$BUILD/lib/:$LD_LIBRARY_PATH"
		CMD_TEMPLATE="$BUILD/bin/ffmpeg -hide_banner -i \"$FF_TEST_VIDEO\" -threads $FFMPEG_BENCH_NPROC_COUNT -y $ENCODING_PARAMS -loglevel error /dev/shm/out.$OUTPUT_EXT"

		if [ "$USE_VTUNE" = true ]; then
			VTUNE_RESULT_DIR="vtune_results/${BUILD}_${CODEC_KEY}"
			mkdir -p "$VTUNE_RESULT_DIR"

			VTUNE_OPTIONS="--collect=$VTUNE_ANALYSIS_TYPE --result-dir=$VTUNE_RESULT_DIR \
				-knob sampling-mode=$VTUNE_SAMPLING_MODE \
				-knob enable-stack-collection=true \
				-data-limit=5000"

        for (( i=1; i<=RUNS_COUNT; i++ )); do
            echo -n "  Run $i/$RUNS_COUNT... "
            
            if [ "$TRACE_MODE" = true ]; then
                TRACE_FILE_ZST="$TRACES_DIR/${build}_${codec_key}.log.zst"
                # The command is wrapped in 'bash -c' to handle the pipeline correctly.
                # 'set -o pipefail' ensures that if ffmpeg fails, the whole command fails.
                timed_cmd="bash -c \"set -o pipefail; $CMD_TEMPLATE 2>&1 | zstd -1 -o '$TRACE_FILE_ZST'\""
                
                # We need to use eval to correctly execute the command string with its internal quotes
                if eval "$timed_cmd"; then
                    echo "OK (Trace saved to $TRACE_FILE_ZST)"
                else
                    echo "FAILED! This run will be skipped."
                    continue
                fi
            else
                /usr/bin/time -v -o "$TIME_OUTPUT_FILE" bash -c "$CMD_TEMPLATE" || {
                    echo "FAILED! This run will be skipped."
                    continue
                }
            
                elapsed_raw=`grep "Elapsed (wall clock) time" "$TIME_OUTPUT_FILE" | awk '{print $NF}'`
                if [[ $elapsed_raw == *":"* ]]; then
                    elapsed_s=`echo "$elapsed_raw" | awk -F: '{ secs=0; for(i=1;i<=NF;i++) secs = secs*60 + $i; print secs }'`
                else
                    elapsed_s=$elapsed_raw
                fi
                user_s=$(grep "User time (seconds)" "$TIME_OUTPUT_FILE" | awk '{print $NF}')
                system_s=$(grep "System time (seconds)" "$TIME_OUTPUT_FILE" | awk '{print $NF}')
                max_mem=$(grep "Maximum resident set size" "$TIME_OUTPUT_FILE" | awk '{print $NF}')
                
                echo "OK (Time: ${elapsed_s}s, Mem: ${max_mem}KB)"
                
                elapsed_times+=("$elapsed_s")
                user_times+=("$user_s")
                system_times+=("$system_s")
                mem_usages+=("$max_mem")
            fi
        done

        if [ "$TRACE_MODE" = true ]; then
             echo "--------------------------------------------------------"
             echo ""
             continue
        fi

        successful_runs=${#elapsed_times[@]}
        if [ "$successful_runs" -eq 0 ]; then
            echo "  No successful runs for this configuration. Skipping."
            echo "--------------------------------------------------------"
            echo ""
            continue
        fi

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
if [ "$TRACE_MODE" = true ]; then
    echo "Compressed traces are located in the '$TRACES_DIR/' directory."
fi
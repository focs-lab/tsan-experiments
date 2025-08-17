#!/bin/bash

set -e

# --- Configuration ---
FFTESTVIDEO="./input/WatchingEyeTexture.for_trace.mkv"
[ ! -f "$FFTESTVIDEO" ] && echo "No video file found at $FFTESTVIDEO" && exit 1

FFBUILDLIST_STR=$(ls -d ffmpeg-tsan* 2>/dev/null | xargs)
[ -z "$FFBUILDLIST_STR" ] && echo "No FFmpeg builds found (directory pattern \"ffmpeg-*\")." && exit 2

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

# Number of runs to average the results
RUNS_COUNT=3
if [ "$TRACE_MODE" = true ]; then
    RUNS_COUNT=1
    echo "Trace mode enabled. Number of runs will be 1."
    if ! command -v zstd > /dev/null 2>&1; then
        echo "Error: 'zstd' is not found, but is required for trace mode." >&2
        exit 1
    fi
    mkdir -p "$TRACES_DIR"
    echo "Compressed traces will be saved to '$TRACES_DIR/'."
fi

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
echo "Builds to test: $FFBUILDLIST_STR"
echo "Video file: $FFTESTVIDEO"
echo "Runs per test: $RUNS_COUNT"
echo ""

SUMMARY_CSV="summary_ffmpeg_benchmark.csv"
echo "Codec,FFBUILD,runs_completed,mean_time_s,stddev_time_s,min_time_s,max_time_s,mean_user_s,mean_system_s,max_mem_kb,command_template" > "$SUMMARY_CSV"

read -ra FFBUILD_ARRAY <<< "$FFBUILDLIST_STR"
TIME_OUTPUT_FILE=$(mktemp)
trap 'rm -f "$TIME_OUTPUT_FILE" ${JSON_RESULTS_FILE:-}' EXIT

for codec_key in "${!CODECS[@]}"; do
    codec_info="${CODECS[$codec_key]}"
    encoding_params="${codec_info%%::*}"
    output_ext="${codec_info##*::}"
    
    for build in "${FFBUILD_ARRAY[@]}"; do
        echo "--- Benchmarking: Codec [$codec_key], Build [$build] ---"

        # ======================================================================
        # CRITICAL FIX: Explicitly reset arrays for each new benchmark set.
        # This prevents data from one test from leaking into the next.
        elapsed_times=()
        user_times=()
        system_times=()
        mem_usages=()
        # ======================================================================

        export LD_LIBRARY_PATH="$build/lib/:$LD_LIBRARY_PATH"
        CMD_TEMPLATE="$build/bin/ffmpeg -hide_banner -i $FFTESTVIDEO -threads $(nproc) -y $encoding_params -loglevel error /dev/shm/out.$output_ext"

        if [ "$USE_VTUNE" = true ]; then
            vtune_result_dir="vtune_results/${build}_${codec_key}"
            mkdir -p "$vtune_result_dir"

            vtune_options="--collect=$VTUNE_ANALYSIS_TYPE --result-dir=$vtune_result_dir \
               -knob sampling-mode=$VTUNE_SAMPLING_MODE \
               -knob enable-stack-collection=true \
               -data-limit=5000"

            CMD_TEMPLATE="vtune $vtune_options -- $CMD_TEMPLATE"
            echo "CMD :$CMD_TEMPLATE"
            echo "  VTune enabled. Results will be in: $vtune_result_dir"
        fi

        for (( i=1; i<=RUNS_COUNT; i++ )); do
            echo -n "  Run $i/$RUNS_COUNT... "
            
            if [ "$TRACE_MODE" = true ]; then
                TRACE_FILE_ZST="$TRACES_DIR/${build}_${codec_key}.log.zst"
                # The command is wrapped in 'bash -c' to handle the pipeline correctly.
                # 'set -o pipefail' ensures that if ffmpeg fails, the whole command fails.
                timed_cmd="bash -c \"set -o pipefail; $CMD_TEMPLATE 2>&1 | zstd -1 -o '$TRACE_FILE_ZST'\""
                
                # We need to use eval to correctly execute the command string with its internal quotes
                eval "$timed_cmd" || {
                    echo "FAILED! This run will be skipped."
                    continue
                }
            else
                /usr/bin/time -v -o "$TIME_OUTPUT_FILE" bash -c "$CMD_TEMPLATE" || {
                    echo "FAILED! This run will be skipped."
                    continue
                }
            fi
            
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
        done

        successful_runs=${#elapsed_times[@]}
        if [ "$successful_runs" -eq 0 ]; then
            echo "  No successful runs for this configuration. Skipping."
            echo "--------------------------------------------------------"
            echo ""
            continue
        fi

        # --- Calculate Statistics ---
        sum_time=$(printf "%s\n" "${elapsed_times[@]}" | paste -sd+ - | bc)
        mean_time=$(echo "scale=4; $sum_time / $successful_runs" | bc)
        min_time=$(printf "%s\n" "${elapsed_times[@]}" | sort -n | head -1)
        max_time=$(printf "%s\n" "${elapsed_times[@]}" | sort -n | tail -1)
        
        sum_sq_diff=0
        for t in "${elapsed_times[@]}"; do
            diff=$(echo "$t - $mean_time" | bc)
            sum_sq_diff=$(echo "$sum_sq_diff + ($diff * $diff)" | bc)
        done
        # Handle the case of a single run to avoid division by zero in sqrt
        if [ "$successful_runs" -gt 1 ]; then
            stddev_time=$(echo "scale=4; sqrt($sum_sq_diff / ($successful_runs))" | bc)
        else
            stddev_time=0
        fi

        sum_user=$(printf "%s\n" "${user_times[@]}" | paste -sd+ - | bc)
        mean_user=$(echo "scale=4; $sum_user / $successful_runs" | bc)
        
        sum_system=$(printf "%s\n" "${system_times[@]}" | paste -sd+ - | bc)
        mean_system=$(echo "scale=4; $sum_system / $successful_runs" | bc)
        
        max_mem_peak=$(printf "%s\n" "${mem_usages[@]}" | sort -n | tail -1)

        # (Остальная часть скрипта: вывод и запись в файлы — без изменений)
        echo "  Results: Time(avg±std): ${mean_time}s ± ${stddev_time}s | Mem(peak): ${max_mem_peak}KB | Runs: ${successful_runs}/${RUNS_COUNT}"
        
        csv_line=$(printf '"%s","%s","%s",%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d,"%s"\n' \
            "$codec_key" "$build" "${successful_runs}/${RUNS_COUNT}" "$mean_time" "$stddev_time" \
            "$min_time" "$max_time" "$mean_user" "$mean_system" "$max_mem_peak" "$CMD_TEMPLATE")
        echo "$csv_line" >> "$SUMMARY_CSV"

#        if [ "$JQ_AVAILABLE" = true ]; then
#            jq -n \
#                --arg codec "$codec_key" --arg build "$build" --argjson runs_successful "$successful_runs" \
#                --argjson runs_total "$RUNS_COUNT" --argjson mean_time "$mean_time" --argjson stddev_time "$stddev_time" \
#                --argjson min_time "$min_time" --argjson max_time "$max_time" --argjson mean_user "$mean_user" \
#                --argjson mean_system "$mean_system" --argjson max_mem_kb "$max_mem_peak" --arg command_template "$CMD_TEMPLATE" \
#                '{ "codec": $codec, "build": $build, "runs": { "successful": $runs_successful, "total": $runs_total }, "time": { "mean_s": $mean_time, "stddev_s": $stddev_time, "min_s": $min_time, "max_s": $max_time }, "cpu": { "mean_user_s": $mean_user, "mean_system_s": $mean_system }, "memory": { "max_peak_kb": $max_mem_kb }, "command_template": $command_template }' >> "$JSON_RESULTS_FILE"
#        fi

        echo "--------------------------------------------------------"
        echo ""
    done
    rm -f "/dev/shm/out.$output_ext"
done

#if [ "$JQ_AVAILABLE" = true ]; then
#    jq -s '{benchmarks: .}' "$JSON_RESULTS_FILE" > "$SUMMARY_JSON"
#    echo "JSON results have been finalized in $SUMMARY_JSON"
#fi

echo "Benchmark finished. CSV results are in $SUMMARY_CSV"
if [ "$TRACE_MODE" = true ]; then
    echo "Compressed traces are located in the '$TRACES_DIR/' directory."
fi

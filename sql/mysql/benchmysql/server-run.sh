source callmysql-export-main-vars.sh || exit $?

./server-check-connection.sh && echo "Already launched." && exit 1

TRACE_LAUNCH_PID_FILE="PID_trace_mysql_launched"
rm -f "$TRACE_LAUNCH_PID_FILE"
LAUNCH_COMMAND_PID=

# Base command
declare -a mysql_cmd=(
    "$MYSQL_DIR/mysqld"
    "--datadir=$MYSQL_DATA_DIR"
)

# VTune run:
if [ "$BENCH_USE_VTUNE" = "true" ]; then
    echo -e "\n  \e[94mVTune profiling is enabled.\e[m\n"

    vtune_analysis_type="hotspots"
    vtune_sampling_mode="sw" # "hw"

    if [ -z "$V_TUNE_RESULT_DIR" ]; then
        echo -e "\n  \e[91mError: V_TUNE_RESULT_DIR is not set for VTune profiling.\e[m\n"
        exit 1
    fi

    declare -a vtune_cmd=(
        "vtune"
        "--collect=$vtune_analysis_type"
        "--result-dir=$V_TUNE_RESULT_DIR"
        "-knob" "sampling-mode=$vtune_sampling_mode"
        "-knob" "enable-stack-collection=true"
        "-data-limit=5000"
        "--"
    )

    mysql_cmd=("${vtune_cmd[@]}" "${mysql_cmd[@]}")
fi

if [ "$BENCH_USE_TRACE" = "true" ] && [ -n "$BENCH_TRACE_OUTPUT_FILE" ]; then
    BENCH_TRACE_COMPRESSOR="${BENCH_TRACE_COMPRESSOR:-zstd}"
    mkdir -p "$(dirname "$BENCH_TRACE_OUTPUT_FILE")"

    echo -e "\e[95mTrace capture enabled: ${mysql_cmd[*]} -> $BENCH_TRACE_OUTPUT_FILE\e[0m"

    case "$BENCH_TRACE_COMPRESSOR" in
        "zstd")
            if [ "$BENCH_USE_TIME" = "true" ]; then
                (
                    set -o pipefail
                    /usr/bin/time -v -o time.log "${mysql_cmd[@]}" 2>&1 | zstd -1 -q -o "$BENCH_TRACE_OUTPUT_FILE"
                ) &
            else
                (
                    set -o pipefail
                    "${mysql_cmd[@]}" 2>&1 | zstd -1 -q -o "$BENCH_TRACE_OUTPUT_FILE"
                ) &
            fi
            ;;
        "lz4")
            if [ "$BENCH_USE_TIME" = "true" ]; then
                (
                    set -o pipefail
                    /usr/bin/time -v -o time.log "${mysql_cmd[@]}" 2>&1 | lz4 -1 -q -z -f - "$BENCH_TRACE_OUTPUT_FILE"
                ) &
            else
                (
                    set -o pipefail
                    "${mysql_cmd[@]}" 2>&1 | lz4 -1 -q -z -f - "$BENCH_TRACE_OUTPUT_FILE"
                ) &
            fi
            ;;
        "none")
            if [ "$BENCH_USE_TIME" = "true" ]; then
                (
                    /usr/bin/time -v -o time.log "${mysql_cmd[@]}" > "$BENCH_TRACE_OUTPUT_FILE" 2>&1
                ) &
            else
                (
                    "${mysql_cmd[@]}" > "$BENCH_TRACE_OUTPUT_FILE" 2>&1
                ) &
            fi
            ;;
        *)
            echo -e "\e[91mUnsupported trace compressor '$BENCH_TRACE_COMPRESSOR'.\e[0m"
            exit 1
            ;;
    esac

    LAUNCH_COMMAND_PID=$!
    echo "$LAUNCH_COMMAND_PID" > "$TRACE_LAUNCH_PID_FILE"

# Time/Memory run:
elif [ "$BENCH_USE_TIME" = "true" ]; then
	echo -e "\e[95m/usr/bin/time -v -o time.log ${mysql_cmd[*]} &\e[0m"

    /usr/bin/time -v -o time.log "${mysql_cmd[@]}" 2> server-run.stderr.log &
    LAUNCH_COMMAND_PID=$!

    echo "$LAUNCH_COMMAND_PID" > "PID_time_mysql_launched"
else
	echo -e "\e[95m${mysql_cmd[*]} &\e[0m"
    "${mysql_cmd[@]}" 2> server-run.stderr.log &
    LAUNCH_COMMAND_PID=$!
fi

TIMEOUT_MAX=900
TIMEOUT_CUR=0

while ! ./server-check-connection.sh ; do
	TIMEOUT_CUR=$(( TIMEOUT_CUR + 1 ))

	if [ -n "$LAUNCH_COMMAND_PID" ] && [ ! -d "/proc/$LAUNCH_COMMAND_PID" ]; then
		echo -e "\e[91mNothing is launched under PID $LAUNCH_COMMAND_PID, maybe an early program shutdown."
		exit 2
	fi

	if [ $TIMEOUT_CUR -ge $TIMEOUT_MAX ]; then
		echo -e "\e[91mWaiting timeout (was $TIMEOUT_MAX attempts)."
		exit 3
	fi

	echo -e "\e[94mWaiting for estabilishing the server main worker loop ($TIMEOUT_CUR/$TIMEOUT_MAX)...\e[m"
	sleep 1
done

echo -e "\e[94mWaiting finished at $TIMEOUT_CUR/$TIMEOUT_MAX."

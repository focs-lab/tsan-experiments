source callmysql-export-main-vars.sh || exit $?

./server-check-connection.sh && echo "Already launched." && exit 1

# Base command
declare -a mysql_cmd=(
    "$MYSQL_DIR/mysqld"
    "--datadir=$MYSQL_DATA_DIR"
    "--port=7777"
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


# Time/Memory run:
if [ "$BENCH_USE_TIME" = "true" ]; then
	echo -e "\e[95m/usr/bin/time -v -o time.log "${mysql_cmd[@]}" &\e[0m"

    /usr/bin/time -v -o time.log "${mysql_cmd[@]}" 2> server-run.stderr.log &
    LAUNCH_COMMAND_PID=$!

    echo "$LAUNCH_COMMAND_PID" > "PID_time_mysql_launched"
else
	echo -e "\e[95m"${mysql_cmd[@]}" &\e[0m"
    "${mysql_cmd[@]}" 2> server-run.stderr.log &
    #LAUNCH_COMMAND_PID=$!
fi



TIMEOUT_MAX=900
TIMEOUT_CUR=0

while ! ./server-check-connection.sh ; do
	TIMEOUT_CUR=$(( TIMEOUT_CUR + 1 ))

	if [ ! -d "/proc/$LAUNCH_COMMAND_PID" ]; then
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

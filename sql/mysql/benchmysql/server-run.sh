source callmysql-export-main-vars.sh || exit $?

./server-check-connection.sh && echo "Already launched." && exit 1


LAUNCH_COMMAND="$MYSQL_DIR/mysqld --datadir=\\\"$MYSQL_DATA_DIR\\\""

# VTune run:
if [ "$BENCH_USE_VTUNE" = "true" ]; then
    echo -e "\n  \e[94mVTune profiling is enabled.\e[m\n"

    vtune_analysis_type="hotspots"
    vtune_sampling_mode="sw" # "hw"

    if [ -z "$V_TUNE_RESULT_DIR" ]; then
        echo -e "\n  \e[91mError: V_TUNE_RESULT_DIR is not set for VTune profiling.\e[m\n"
        exit 1
    fi

    vtune_options="--collect=$vtune_analysis_type --result-dir=$V_TUNE_RESULT_DIR \
                   -knob sampling-mode=$vtune_sampling_mode \
                   -knob enable-stack-collection=true \
                   -data-limit=5000"

    LAUNCH_COMMAND="vtune $vtune_options -- $LAUNCH_COMMAND"
fi

# Time/Memory run:
if [ "$BENCH_USE_TIME" = "true" ]; then
	LAUNCH_COMMAND="/usr/bin/time -v -o time.log bash -c \"$LAUNCH_COMMAND\""
fi

if [ "$BENCH_USE_VTUNE" != "true" ] && [ "$BENCH_USE_TIME" != "true" ]; then
	LAUNCH_COMMAND="bash -c \"$LAUNCH_COMMAND\""
fi


echo -e "\e[95m$LAUNCH_COMMAND"
eval "$LAUNCH_COMMAND" 2> server-run.stderr.log &

LAUNCH_COMMAND_PID=$!


#/usr/bin/time -v -o "time.log" bash -c "$LAUNCH_COMMAND" &


if [ "$BENCH_USE_TIME" = "true" ]; then
	echo "$LAUNCH_COMMAND_PID" > "PID_usr_bin_time_mysqld"
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

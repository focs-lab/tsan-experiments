source callmysql-export-main-vars.sh

./server-check-connection.sh && echo "Already launched." && exit 1


LAUNCH_COMMAND="$MYSQL_DIR/mysqld --datadir=\"$MYSQL_DATA_DIR\""

if [ "$USE_VTUNE" = "true" ]; then
    echo -e "\n  \e[94mVTune profiling is enabled.\e[m\n"

    vtune_sampling_mode="hw"
    vtune_analysis_type="hotspots"
    
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

/usr/bin/time -v -o "time.log" bash -c "$LAUNCH_COMMAND" &

echo "$!" > "PID_usr_bin_time_mysqld"

#$MYSQL_DIR/mysqld --datadir="$MYSQL_DATA_DIR" &
#$MYSQL_DIR/mysqld --datadir="$MYSQL_DATA_DIR"

while ! ./server-check-connection.sh ; do
	echo -e "\e[94mWaiting for estabilishing the server main worker loop...\e[m"
	sleep 1
done
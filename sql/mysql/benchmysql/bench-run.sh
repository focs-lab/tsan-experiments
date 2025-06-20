
#[ -z "$SYSBENCH_SCRIPT_FILENAME" ] && SYSBENCH_SCRIPT_FILENAME="oltp_read_write.lua"

source callmysql-export-main-vars.sh

echo "Sysbench script: $SYSBENCH_SCRIPT_FILE"
echo "sysbench $SYSBENCH_SCRIPT_FILE $SYSBENCH_CONNECTION_ARGS $SYSBENCH_RUN_ARGS run | awk '/Latency \(ms\):/ { exit; } 1'"

taskset -c 12-15 sysbench "$SYSBENCH_SCRIPT_FILE" $SYSBENCH_CONNECTION_ARGS $SYSBENCH_RUN_ARGS run | awk '/Latency \(ms\):/ { exit; } 1'
#taskset -c 12-15 sysbench "$SYSBENCH_SCRIPT_FILE" $SYSBENCH_CONNECTION_ARGS $SYSBENCH_RUN_ARGS run
#sysbench "$SYSBENCH_SCRIPT_FILE" $SYSBENCH_CONNECTION_ARGS $SYSBENCH_RUN_ARGS run | awk '/Latency \(ms\):/ { exit; } 1'

echo "MySQL build: $(echo $MYSQL_DIR | awk -F'/' '{print $NF=="" ? $(NF-3) : $(NF-2) }')"

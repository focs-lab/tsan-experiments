source callmysql-export-main-vars.sh

echo "Sysbench script: $SYSBENCH_SCRIPT_FILE"
echo -e "\e[95msysbench $SYSBENCH_SCRIPT_FILE $SYSBENCH_CONNECTION_ARGS $SYSBENCH_RUN_ARGS run | awk '/Latency \(ms\):/ { exit; } 1'\e[0m"

taskset -c 12-15 sysbench "$SYSBENCH_SCRIPT_FILE" $SYSBENCH_CONNECTION_ARGS $SYSBENCH_RUN_ARGS run | awk '/Latency \(ms\):/ { exit; } 1'
#taskset -c 12-15 sysbench "$SYSBENCH_SCRIPT_FILE" $SYSBENCH_CONNECTION_ARGS $SYSBENCH_RUN_ARGS run
#sysbench "$SYSBENCH_SCRIPT_FILE" $SYSBENCH_CONNECTION_ARGS $SYSBENCH_RUN_ARGS run | awk '/Latency \(ms\):/ { exit; } 1'

echo "MySQL build: $(echo $MYSQL_DIR | awk -F'/' '{print $NF=="" ? $(NF-3) : $(NF-2) }')"

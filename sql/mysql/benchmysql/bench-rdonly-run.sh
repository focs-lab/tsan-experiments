
[ -z "$SYSBENCH_SCRIPT_FILENAME" ] && SYSBENCH_SCRIPT_FILENAME="oltp_read_write.lua"

source callmysql-export-main-vars.sh

echo "Sysbench script: $SYSBENCH_SCRIPT_FILE"
time sysbench "$SYSBENCH_SCRIPT_FILE" $SYSBENCH_CONNECTION_ARGS $SYSBENCH_RUN_ARGS run

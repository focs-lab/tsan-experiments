source callmysql-export-main-vars.sh

time sysbench "$SYSBENCH_SCRIPTS_DIR/oltp_read_only.lua" $SYSBENCH_CONNECTION_ARGS $SYSBENCH_RUN_ARGS run

source callmysql-export-main-vars.sh

sysbench "$SYSBENCH_SCRIPTS_DIR/oltp_read_only.lua" $SYSBENCH_CONNECTION_ARGS cleanup

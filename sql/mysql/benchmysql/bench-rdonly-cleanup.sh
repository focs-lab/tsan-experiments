source callmysql-export-main-vars.sh

sysbench "$SYSBENCH_SCRIPT_FILE" $SYSBENCH_CONNECTION_ARGS cleanup

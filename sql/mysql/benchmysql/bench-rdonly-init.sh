source callmysql-export-main-vars.sh


set -e

$MYSQL_DIR/mysql --user=root -e "CREATE DATABASE IF NOT EXISTS sbtest;"

sysbench "$SYSBENCH_SCRIPT_FILE" $SYSBENCH_CONNECTION_ARGS prepare


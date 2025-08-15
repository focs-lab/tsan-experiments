source callmysql-export-main-vars.sh || exit $?

[ -d "$MYSQL_DATA_DIR" ] && echo "Data dir \"$MYSQL_DATA_DIR\" already exists." && exit 1

./server-check-connection.sh && echo "Cannot init MySQL server, already launched." && exit 1

echo Initializing MySQL with datadir \"$MYSQL_DATA_DIR\".

$MYSQL_DIR/mysqld --initialize-insecure --datadir="$MYSQL_DATA_DIR" 2> server-datadir-init.stderr.log

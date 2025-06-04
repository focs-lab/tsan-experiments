source callmysql-export-main-vars.sh

[ -d "$MYSQL_DATA_DIR" ] && echo "Data dir \"$MYSQL_DATA_DIR\" already exists." && exit 2

./server-check-connection.sh && echo "Cannot init MySQL server, already launched." && exit 1

$MYSQL_DIR/mysqld --initialize-insecure --datadir="$MYSQL_DATA_DIR"

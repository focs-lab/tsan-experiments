source callmysql-export-main-vars.sh

# Note: it's better to use the "taskset" command to prevent CPU races between MySQL and its benchmark.

$MYSQL_DIR/mysqld --datadir="$MYSQL_DATA_DIR" &
#$MYSQL_DIR/mysqld --datadir="$MYSQL_DATA_DIR"

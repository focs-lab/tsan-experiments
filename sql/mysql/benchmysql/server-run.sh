source callmysql-export-main-vars.sh

# Note: it's better to use the "taskset" command to prevent CPU races between MySQL and its benchmark.

./server-check-connection.sh && echo "Already launched." && exit 1

$MYSQL_DIR/mysqld --datadir="$MYSQL_DATA_DIR" &
#$MYSQL_DIR/mysqld --datadir="$MYSQL_DATA_DIR" &
#$MYSQL_DIR/mysqld --datadir="$MYSQL_DATA_DIR"

while ! ./server-check-connection.sh ; do
	echo -e "\e[94mWaiting for estabilishing the server main worker loop...\e[m"
	sleep 1
done

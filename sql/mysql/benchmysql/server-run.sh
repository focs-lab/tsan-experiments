source callmysql-export-main-vars.sh

./server-check-connection.sh && echo "Already launched." && exit 1


#/usr/bin/time -v -o "time.log" bash -c "$MYSQL_DIR/mysqld --datadir=\"$MYSQL_DATA_DIR\"" &
/usr/bin/time -v -o "time.log" $MYSQL_DIR/mysqld --datadir="$MYSQL_DATA_DIR" &

echo "$!" > "PID_usr_bin_time_mysqld"

#$MYSQL_DIR/mysqld --datadir="$MYSQL_DATA_DIR" &
#$MYSQL_DIR/mysqld --datadir="$MYSQL_DATA_DIR"

while ! ./server-check-connection.sh ; do
	echo -e "\e[94mWaiting for estabilishing the server main worker loop...\e[m"
	sleep 1
done

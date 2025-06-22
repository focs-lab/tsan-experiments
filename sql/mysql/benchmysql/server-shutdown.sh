source callmysql-export-main-vars.sh

set -e

$MYSQL_DIR/mysqladmin --user=root --socket=/tmp/mysql.sock shutdown

[ -f "PID_usr_bin_time_mysqld" ] && {
	MYSQL_USR_BIN_TIME_PID=$(cat PID_usr_bin_time_mysqld)

	[ -n "${MYSQL_USR_BIN_TIME_PID}" ] && [ "${MYSQL_USR_BIN_TIME_PID}" -ne 0 ] && {
		echo "Waiting for \time PID $MYSQL_USR_BIN_TIME_PID to exit..."

		# Exits with an error "wait: (pid) is not a child of this shell".
		#wait $MYSQL_USR_BIN_TIME_PID

		while [ -e "/proc/$MYSQL_USR_BIN_TIME_PID" ] && [ "$(cat /proc/$MYSQL_USR_BIN_TIME_PID/comm)" = "time" ]; do
			# Theoretically there is a small chance that some program will replace the same PID.
			sleep 0.5
		done
	}

	rm PID_usr_bin_time_mysqld
}

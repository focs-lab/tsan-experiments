source callmysql-export-main-vars.sh


$MYSQL_DIR/mysqladmin --user=root --socket=/tmp/mysql.sock shutdown 2> server-shutdown.stderr.log

if [ -f "PID_time_mysql_launched" ]; then
	MYSQL_USR_BIN_TIME_PID=$(cat PID_time_mysql_launched)

	[ "$BENCH_USE_TIME" != "true" ] && echo -e "\e[93mWarning: \$BENCH_USE_TIME is not 'true' but file 'PID_time_mysql_launched' exist (content \"$MYSQL_USR_BIN_TIME_PID\")\e[0m."

	if [ -n "${MYSQL_USR_BIN_TIME_PID}" ] && [ "${MYSQL_USR_BIN_TIME_PID}" -ne 0 ]; then
		echo "Waiting for \time PID $MYSQL_USR_BIN_TIME_PID to exit..."

		# Exits with an error "wait: (pid) is not a child of this shell".
		#wait $MYSQL_USR_BIN_TIME_PID

		if [ ! -d "/proc/$MYSQL_USR_BIN_TIME_PID" ]; then
			echo "Note: time process does not exist (according to absence of '/proc/$MYSQL_USR_BIN_TIME_PID')."

		elif [ "$(cat /proc/$MYSQL_USR_BIN_TIME_PID/comm)" != "time" ]; then
			echo -e "\e[93mWarning: '/proc/$MYSQL_USR_BIN_TIME_PID/comm' is not a 'time' (got '$(cat /proc/$MYSQL_USR_BIN_TIME_PID/comm)')\e[0m."

		else
			while [ -e "/proc/$MYSQL_USR_BIN_TIME_PID" ] && [ "$(cat /proc/$MYSQL_USR_BIN_TIME_PID/comm)" = "time" ]; do
				# Theoretically there is a small chance that some program will replace the same PID.
				sleep 0.5
			done
		fi
	fi

	rm PID_time_mysql_launched

elif [ "$BENCH_USE_TIME" == "true" ]; then
	echo -e "\e[93mWarning: \$BENCH_USE_TIME is 'true' but file 'PID_time_mysql_launched' does not exist\e[0m."

fi

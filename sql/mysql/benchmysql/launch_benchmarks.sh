#!/bin/bash

MYSQLBUILDLIST="
	mysql-build_main_with-orig-tsan-c609043dd00955bf177ff57b0bad2a87c1e61a36
	mysql-build_tsan-ea-ownership-9250cdbcc8
	mysql-build_tsan-ea-pathes-to-underl-objs_ac06afd3203
	mysql-build_tsan-with-ea-IPA-8a2198773e
"

#Override:
#MYSQLBUILDLIST="mysql-build_tsan-with-ea-enable-disable-tsan-instr_10d6ed8632"

MYSQLBUILDBASEDIR="/home/all/src/tsan-experiments/sql/mysql/build-ready"
SYSBENCH_SCRIPT_FILENAME="oltp_read_write.lua"


#MYSQLBUILDLIST=$(echo "$MYSQLBUILDLIST" | sed "s/[,\n\t]/ /g" | sed "s/\s\s\+/ /g")
MYSQLBUILDLIST=$(echo "$MYSQLBUILDLIST" | sed  -e "y/,\n\t/   /"  -e "s/\s\s\+/ /g"  -e "s/^\s//1" | xargs)


logmessage() {
	echo -e "\n  \e[94m$1\e[m  \n"
}

set -e

./server-init.sh || logmessage "Server initialized already."


for BUILD in $MYSQLBUILDLIST; do
	export MYSQL_DIR="$MYSQLBUILDBASEDIR/$BUILD/install-tsan/bin"
	#export MYSQL_DIR="/home/all/src/tsan-experiments/sql/mysql/build-ready/mysql-build_main-c609043dd0/install-orig/bin/"

	[ ! -f "$MYSQL_DIR/mysqld" ] && logmessage "\e[93mNo MyQSL found at \"$MYSQL_DIR\", skipping." && continue

	logmessage " ===== Started: $BUILD ===== "

	./server-run.sh &
	sleep 5

	logmessage "Ready to initialize the benchmark database."

	while ! ./bench-rdonly-init.sh ; do
		logmessage "Waiting for server reply..."
		sleep 1
	done

	logmessage "\e[92mBenchmark database initialized. Launching..."

	./bench-rdonly-run.sh | tee "benchmark-$BUILD.txt"
	#hyperfine --min-runs 5 --export-csv="myqsl-$i.csv" "./bench-rd"

	logmessage " ===== Finished: $BUILD ===== "

	./server-shutdown.sh
done

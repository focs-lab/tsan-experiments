#!/bin/bash

MYSQLBUILDLIST="
	mysql-build_tsan-with-ea-IPA_780ba8a6e4__no-excludes
	mysql-build_tsan-with-ea-IPA_780ba8a6e4__top10-tsan-optimizes
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

	while ! ./server-check-connection.sh ; do
		logmessage "Waiting for server reply..."
		sleep 1
	done

	./bench-rdonly-init.sh

	logmessage "\e[92mBenchmark database initialized. Launching..."

	./bench-rdonly-run.sh | tee "benchmark-$BUILD.txt"
	#hyperfine --min-runs 5 --export-csv="myqsl-$i.csv" "./bench-run"

	logmessage " ===== Finished: $BUILD ===== "

	./server-shutdown.sh
done

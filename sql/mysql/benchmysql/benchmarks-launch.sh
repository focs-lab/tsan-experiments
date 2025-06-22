#!/bin/bash

# This script 'benchmarks-launch.sh' calls all other benchmark scripts.


export MYSQL_BUILDS_DIR=".."

export SYSBENCH_SCRIPTS_DIR="/usr/share/sysbench"

SYSBENCH_ALL_SCRIPTS="$(ls "$SYSBENCH_SCRIPTS_DIR"/oltp_*.lua "$SYSBENCH_SCRIPTS_DIR"/select_random_*.lua | xargs basename -a | grep -v oltp_common\.lua | xargs)"

export MYSQL_DATA_DIR="/tmp/mysql-benchmarks-datadir"


#MYSQLBUILDLIST=$(echo "$MYSQLBUILDLIST" | sed "s/[,\n\t]/ /g" | sed "s/\s\s\+/ /g")
MYSQLBUILDLIST=$(ls -d "$MYSQL_BUILDS_DIR"/mysql-tsan "$MYSQL_BUILDS_DIR"/mysql-tsan-* "$MYSQL_BUILDS_DIR"/mysql-orig | sed  -e "y/,\n\t/   /"  -e "s/\s\s\+/ /g"  -e "s/^\s//1" | xargs basename -a | xargs)

#MYSQLBUILDLIST="mysql-tsan"

# Debug string with exit:
#echo "$MYSQLBUILDLIST" && echo && echo $SYSBENCH_ALL_SCRIPTS && exit



logmessage() {
	echo -e "\n  \e[94m$1\e[m  \n"
}

set -e

./server-datadir-init.sh || logmessage "Server datadir initialized already."


for BENCHSCRIPT in $SYSBENCH_ALL_SCRIPTS; do
	logmessage "\n######################=#==- =##+- ===-=--- -\n#\n# \e[1;36m$BENCHSCRIPT\e[0;94m \n#\n#####===-=-- -   -"

	for BUILD in $MYSQLBUILDLIST; do
		OUTPUT_FILE_NAME="benchmark_${BUILD/mysql-/}_$(echo ${BENCHSCRIPT//_/-} | sed "s/\.lua/.txt/1" | xargs basename)"

		export MYSQL_DIR="$MYSQL_BUILDS_DIR/$BUILD/bin"
		export SYSBENCH_SCRIPT_FILENAME="$BENCHSCRIPT"
		#export SYSBENCH_RUN_SECONDS=60

		[ ! -f "$MYSQL_DIR/mysqld" ] && logmessage "\e[93mNo MyQSL found at \"$MYSQL_DIR\", skipping." && continue

		logmessage " ===== Started: $BUILD ===== "

		./server-run.sh &
		sleep 5

		logmessage "Ready to initialize the benchmark database."

		while ! ./server-check-connection.sh ; do
			logmessage "Waiting for server reply..."
			sleep 1
		done

		./bench-init.sh

		logmessage "\e[92mBenchmark database initialized. Launching..."

		./bench-run.sh | tee "$OUTPUT_FILE_NAME"

		logmessage " ===== Finished for $BUILD / $BENCHSCRIPT (output file $OUTPUT_FILE_NAME) ===== "

		./bench-cleanup.sh
		./server-shutdown.sh

		if [ -f "time.log" ]; then
			grep "Maximum resident set size" time.log >> "$OUTPUT_FILE_NAME"
			rm time.log
		else
			echo "No \"time.log\", so no resident memory peak size."
		fi
	done
done

./bench-post-logs2csv.sh

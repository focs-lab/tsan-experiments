#!/bin/bash

CSV_OUTPUT_FILE="results_mysql_$(date +%y%m%d_%H%M).csv"

echo "MySQL build,Sysbench script,Transactions/sec,Queries/sec,Memory peak (kb),Read ops,Write ops,Other ops,Total" > "$CSV_OUTPUT_FILE"

for i in benchmark_*.txt; do
	IFS="_" read -a FILENAME_FIELDS <<< "$i"
	MYSQL_BUILD_NAME="${FILENAME_FIELDS[1]}"
	MYSQL_SYSBENCH_SCRIPT="${FILENAME_FIELDS[2]//\.txt/.lua}"
	echo "Reading logs for build $MYSQL_BUILD_NAME, script $MYSQL_SYSBENCH_SCRIPT..."


	TRANSACTIONS_PER_SEC=$(awk '/transactions:/ { sub(/\(/, "", $3); print $3 }' "$i")

	QUERIES_PER_SEC=$(awk '/queries:/ && !/performed/ { sub(/\(/, "", $3); print $3 }' "$i")

	MEM_PEAK=$(awk '/Maximum resident set size \(kbytes\)/ { print $6 }' "$i")
	# '

	READ_OPS=$(awk '/read:/ { print $2 }' "$i")
	WRITE_OPS=$(awk '/write:/ { print $2 }' "$i")
	OTHER_OPS=$(awk '/other:/ { print $2 }' "$i")
	TOTAL_OPS=$(awk '/total:/ && !/time/ { print $2 }' "$i")

    # Defence:
    MEM_PEAK=${MEM_PEAK:-0}
    READ_OPS=${READ_OPS:-0}
    WRITE_OPS=${WRITE_OPS:-0}
    OTHER_OPS=${OTHER_OPS:-0}
    TOTAL_OPS=${TOTAL_OPS:-0}

	echo "${MYSQL_BUILD_NAME},${MYSQL_SYSBENCH_SCRIPT},${TRANSACTIONS_PER_SEC},${QUERIES_PER_SEC},${MEM_PEAK},${READ_OPS},${WRITE_OPS},${OTHER_OPS},${TOTAL_OPS}" >> "$CSV_OUTPUT_FILE"
done

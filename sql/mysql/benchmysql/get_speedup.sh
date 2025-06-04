#!/bin/bash


getbenchdata() {
	transactions_line=$(grep -E "transactions:" "$1")
	queries_line=$(grep -E "queries:" "$1")

	# Transactions: count, per sec
	TRANS_CNT=$(echo "$transactions_line" | awk '{print $2}')
	TRANS_SEC=$(echo "$transactions_line" | awk '{print $3}' | sed 's/[()]//g')
	#'#

	# Queries: count, per sec
	QUERY_CNT=$(echo "$queries_line" | awk '{print $2}')
	QUERY_SEC=$(echo "$queries_line" | awk '{print $3}' | sed 's/[()]//g')
	#'#
}

floatpoint_div() {
	awk "BEGIN { printf( \"%.4f\", $1 / $2 ); }"
}


if [ -n "$1" ]; then
	FIRST_RESULT_COMPARE_FILE="$1"
elif [ -f "benchmark-mysql-main.txt" ]; then
	FIRST_RESULT_COMPARE_FILE="benchmark-mysql-main.txt"
else
	echo "No file to compare in arg 1 and no 'benchmark-mysql-main.txt'!"
	exit 1
fi

getbenchdata "$FIRST_RESULT_COMPARE_FILE"
TRANS_CNT_FRST=$TRANS_CNT
TRANS_SEC_FRST=$TRANS_SEC
QUERY_CNT_FRST=$QUERY_CNT
QUERY_SEC_FRST=$QUERY_SEC

#getbenchdata "benchmark-mysql-build_FRST_with-orig-tsan-c609043dd00955bf177ff57b0bad2a87c1e61a36.txt"
#TRANS_CNT_ORIGTSAN=$TRANS_CNT
#TRANS_SEC_ORIGTSAN=$TRANS_SEC
#QUERY_CNT_ORIGTSAN=$QUERY_CNT
#QUERY_SEC_ORIGTSAN=$QUERY_SEC

for i in $(ls benchmark-*.txt | grep -v -x "$FIRST_RESULT_COMPARE_FILE"); do
	echo
	echo $i
	getbenchdata $i
	#echo "  T/sec: $TRANS_SEC"
	#echo "  Q/sec: $QUERY_SEC"
	#echo "  T cnt: $TRANS_CNT"
	#echo "  Q cnt: $QUERY_CNT"

	TSEC_SPEEDUP_FRST=$(floatpoint_div $TRANS_SEC $TRANS_SEC_FRST)
	QSEC_SPEEDUP_FRST=$(floatpoint_div $QUERY_SEC $QUERY_SEC_FRST)
	TCNT_SPEEDUP_FRST=$(floatpoint_div $TRANS_CNT $TRANS_CNT_FRST)
	QCNT_SPEEDUP_FRST=$(floatpoint_div $QUERY_CNT $QUERY_CNT_FRST)

: '
	TSEC_SPEEDUP_ORIGTSAN=$(floatpoint_div $TRANS_SEC $TRANS_SEC_ORIGTSAN)
	QSEC_SPEEDUP_ORIGTSAN=$(floatpoint_div $QUERY_SEC $QUERY_SEC_ORIGTSAN)
	TCNT_SPEEDUP_ORIGTSAN=$(floatpoint_div $TRANS_CNT $TRANS_CNT_ORIGTSAN)
	QCNT_SPEEDUP_ORIGTSAN=$(floatpoint_div $QUERY_CNT $QUERY_CNT_ORIGTSAN)

	echo -e "Speedup:   TSan CT\tNo TSan"
	echo -e "    T/sec  x$TSEC_SPEEDUP_ORIGTSAN\tx$TSEC_SPEEDUP_FRST"
	echo -e "    Q/sec  x$QSEC_SPEEDUP_ORIGTSAN\tx$QSEC_SPEEDUP_FRST"
	echo -e "    T cnt  x$TCNT_SPEEDUP_ORIGTSAN\tx$TCNT_SPEEDUP_FRST"
	echo -e "    Q cnt  x$QCNT_SPEEDUP_ORIGTSAN\tx$QCNT_SPEEDUP_FRST"
'

	echo -e "Speedup  vs $FIRST_RESULT_COMPARE_FILE"
	echo -e "    T/sec  x$TSEC_SPEEDUP_FRST"
	echo -e "    Q/sec  x$QSEC_SPEEDUP_FRST"
	echo -e "    T cnt  x$TCNT_SPEEDUP_FRST"
	echo -e "    Q cnt  x$QCNT_SPEEDUP_FRST"

	echo -e "$TRANS_SEC\n$QUERY_SEC\n$TRANS_CNT\n$QUERY_CNT"
done

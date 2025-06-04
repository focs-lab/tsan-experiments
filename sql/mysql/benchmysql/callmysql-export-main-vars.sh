# A small "library" for the MySQL benchmarks infrastructure.

[ -z "$MYSQL_DIR" ]      && export MYSQL_DIR="/home/mcm-remote/all/src/tsan-experiments/sql/mysql/build-ready/mysql-build_tsan-ea-ownership-9250cdbcc8/install-tsan/bin" && echo "Using default \$MYSQL_DIR location: $MYSQL_DIR"
[ -z "$MYSQL_DATA_DIR" ] && export MYSQL_DATA_DIR="/home/all/src/tsan-experiments/sql/mysql/benchmysql/data" && echo "Using default \$MYSQL_DATA_DIR location: $MYSQL_DATA_DIR"


[ ! -d "$MYSQL_DIR" ] && echo "No directory $MYSQL_DIR." && exit 1

if [ -f "$MYSQL_DIR/bin/mysqld" ]; then
	export MYSQL_DIR="$MYSQL_DIR/bin"

elif [ -f "$MYSQL_DIR/install-tsan/bin/mysqld" ]; then
	export MYSQL_DIR="$MYSQL_DIR/install-tsan/bin"

elif [ ! -f "$MYSQL_DIR/mysqld" ]; then
	echo "No file $MYSQL_DIR/[[install-tsan/]bin/]mysqld." && exit 1
fi


export SYSBENCH_SCRIPTS_DIR="/usr/share/sysbench"
export SYSBENCH_CONNECTION_ARGS="--mysql-user=root --mysql-socket=/tmp/mysql.sock "
export SYSBENCH_RUN_THREADS="$(( $(nproc) * 3 / 4 ))"
export SYSBENCH_RUN_ARGS="--threads=$SYSBENCH_RUN_THREADS --time=60 --report-interval=10 --rand-type=special"
#--rand-type=uniform

# Sysbench script file selection. "$SYSBENCH_SCRIPT_FILEPATH" is a resulting file:
[ -z "$SYSBENCH_SCRIPT_FILE" ] && {
	[ -z "$SYSBENCH_SCRIPT_FILENAME" ] && SYSBENCH_SCRIPT_FILENAME="oltp_read_only.lua"

	export SYSBENCH_SCRIPT_FILE="$SYSBENCH_SCRIPTS_DIR/$SYSBENCH_SCRIPT_FILENAME"
}

[ ! -f "$SYSBENCH_SCRIPT_FILE" ] && echo "No file $SYSBENCH_SCRIPT_FILE found." && exit 1


# TSan runtime options:
export TSAN_OPTIONS="report_bugs=0 verbosity=0"

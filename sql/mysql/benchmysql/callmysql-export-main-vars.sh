# A small "library" for the MySQL benchmarks infrastructure.

[ -z "$MYSQL_DIR" ] && {
	export MYSQL_DIR="/home/all/src/tsan-experiments/sql/mysql/build-ready/mysql-build_main-c609043dd0/install-tsan/bin"
	[ ! -d "$MYSQL_DIR" ] && export MYSQL_DIR="$(pwd)/../builds/mysql-tsan/bin"
	[ ! -d "$MYSQL_DIR" ] && export MYSQL_DIR="$(pwd)/../mysql-tsan/bin"

	echo "Using default \$MYSQL_DIR location: $MYSQL_DIR"
}

[ -z "$MYSQL_DATA_DIR" ] && {
	export MYSQL_DATA_DIR="/home/all/src/tsan-experiments/sql/mysql/benchmysql/data"
	[ ! -d "$MYSQL_DATA_DIR" ] && export MYSQL_DATA_DIR="$(pwd)/datadir"
	[ ! -d "$MYSQL_DATA_DIR" ] && export MYSQL_DATA_DIR="/tmp/mysql-benchmarks-datadir"

	echo "Using default \$MYSQL_DATA_DIR location: $MYSQL_DATA_DIR"
}


[ ! -d "$MYSQL_DIR" ] && echo "No \$MYSQL_DIR directory $MYSQL_DIR." && exit 1

[ ! -f "$MYSQL_DIR/mysqld" ] && export MYSQL_DIR="$MYSQL_DIR/bin"
[ ! -f "$MYSQL_DIR/mysqld" ] && export MYSQL_DIR="$MYSQL_DIR/build/bin"
[ ! -f "$MYSQL_DIR/mysqld" ] && export MYSQL_DIR="$MYSQL_DIR/install-tsan/bin"
[ ! -f "$MYSQL_DIR/mysqld" ] && export MYSQL_DIR="$MYSQL_DIR/install/bin"

[ ! -f "$MYSQL_DIR/mysqld" ] && echo "No file [.../]mysqld in standart paths." && exit 1


[ -z "$SYSBENCH_SCRIPTS_DIR" ] 		&& export SYSBENCH_SCRIPTS_DIR="/usr/share/sysbench"
[ -z "$SYSBENCH_CONNECTION_ARGS" ] 	&& export SYSBENCH_CONNECTION_ARGS="--mysql-user=root --mysql-socket=/tmp/mysql.sock "
[ -z "$SYSBENCH_RUN_THREADS" ] 		&& export SYSBENCH_RUN_THREADS="$(( $(nproc) * 3 / 4 ))"
[ -z "$SYSBENCH_RUN_SECONDS" ] 		&& export SYSBENCH_RUN_SECONDS="60"

[ -z "$SYSBENCH_RUN_ARGS" ] 		&& export SYSBENCH_RUN_ARGS="--threads=$SYSBENCH_RUN_THREADS --time=$SYSBENCH_RUN_SECONDS --rand-type=special"
#--rand-type=uniform --report-interval=10


# Sysbench script file selection. "$SYSBENCH_SCRIPT_FILEPATH" is a resulting file:
[ -z "$SYSBENCH_SCRIPT_FILE" ] && {
	[ -z "$SYSBENCH_SCRIPT_FILENAME" ] && SYSBENCH_SCRIPT_FILENAME="oltp_read_only.lua"

	export SYSBENCH_SCRIPT_FILE="$SYSBENCH_SCRIPTS_DIR/$SYSBENCH_SCRIPT_FILENAME"
}

[ ! -f "$SYSBENCH_SCRIPT_FILE" ] && echo "No file $SYSBENCH_SCRIPT_FILE found." && exit 1


# TSan runtime options:
export TSAN_OPTIONS="report_bugs=0 verbosity=0"

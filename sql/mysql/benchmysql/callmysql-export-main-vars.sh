# A small "library" for the MySQL benchmarks infrastructure.

[ -z "$MYSQL_DIR" ]      && export MYSQL_DIR="/home/all/src/tsan-experiments/sql/mysql/build-ready/mysql-build_tsan-with-ea-IPA-9836385836/install-tsan/bin"
[ -z "$MYSQL_DATA_DIR" ] && export MYSQL_DATA_DIR="/home/all/src/tsan-experiments/sql/mysql/benchmysql/data"


export SYSBENCH_SCRIPTS_DIR="/usr/share/sysbench"
export SYSBENCH_CONNECTION_ARGS="--mysql-user=root --mysql-socket=/tmp/mysql.sock "
export SYSBENCH_RUN_THREADS="$(( $(nproc) / 4 * 3 ))"
export SYSBENCH_RUN_ARGS="--threads=$SYSBENCH_RUN_THREADS "


# Sysbench script file selection. "$SYSBENCH_SCRIPT_FILEPATH" is a resulting file:
[ -z "$SYSBENCH_SCRIPT_FILE" ] && {
	[ -z "$SYSBENCH_SCRIPT_FILENAME" ] && SYSBENCH_SCRIPT_FILENAME="oltp_read_only.lua"

	export SYSBENCH_SCRIPT_FILE="$SYSBENCH_SCRIPTS_DIR/$SYSBENCH_SCRIPT_FILENAME"
}

[ ! -f "$SYSBENCH_SCRIPT_FILE" ] && echo "No file $SYSBENCH_SCRIPT_FILE found." && exit 1


# TSan runtime options:
export TSAN_OPTIONS="report_bugs=0 verbosity=0"

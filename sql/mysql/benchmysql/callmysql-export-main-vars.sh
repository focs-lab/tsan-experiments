export MYSQL_DIR="/home/all/src/tsan-experiments/sql/mysql/build-ready/mysql-build_tsan-with-ea-IPA-9836385836/install-tsan/bin"
export MYSQL_DATA_DIR="/home/all/src/tsan-experiments/sql/mysql/benchmysql/data"

export SYSBENCH_SCRIPTS_DIR="/usr/share/sysbench"
export SYSBENCH_CONNECTION_ARGS="--mysql-user=root --mysql-socket=/tmp/mysql.sock "
export SYSBENCH_RUN_THREADS="$(( $(nproc) / 4 * 3 ))"
export SYSBENCH_RUN_ARGS="--threads=$SYSBENCH_RUN_THREADS "

export TSAN_OPTIONS="report_bugs=0 verbosity=0"

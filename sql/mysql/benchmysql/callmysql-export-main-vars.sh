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


# MYSQLD REFUSES TO RUN AS ROOT without being told so: measured on this build (8.0.39, 22 Sep 2026), the
# SERVER exits 1 with `Fatal error: Please read "Security" section of the manual to find out how to run
# mysqld as root!` and starts normally with --user=root. `--initialize-insecure` does NOT refuse -- it
# exits 0 either way -- so the flag is passed there for symmetry and against a future version that does,
# not because today's needs it; the comment says so rather than implying a refusal we did not observe.
# --user=root keeps mysqld running as root, which is the option's documented meaning; below uid 0 it must
# NOT be passed, or the server tries to drop to a user we are not. Decided here, in the file both
# launchers source, so the two cannot drift. (Students' runs, 22 Sep 2026.)
if [ "$(id -u)" = 0 ]; then export MYSQL_RUN_AS_ROOT="--user=root"; else export MYSQL_RUN_AS_ROOT=""; fi

[ -z "$SYSBENCH_SCRIPTS_DIR" ] 		&& export SYSBENCH_SCRIPTS_DIR="/usr/share/sysbench"
[ -z "$SYSBENCH_CONNECTION_ARGS" ] 	&& export SYSBENCH_CONNECTION_ARGS="--mysql-user=root --mysql-socket=/tmp/mysql.sock "
[ -z "$SYSBENCH_RUN_THREADS" ] 		&& export SYSBENCH_RUN_THREADS="$(( $(nproc) * 3 / 4 ))"
[ -z "$SYSBENCH_RUN_SECONDS" ] 		&& export SYSBENCH_RUN_SECONDS="180" #"300"

# --rand-seed: a fresh random seed per workload instead of sysbench's clock seed (0), equivalent in distribution but replayable; bench-run.sh
# echoes the full command line into the workload output, so the seed is recorded with every result (cov1, 28 Sep 2026, after an InnoDB
# assertion in one apollo run that could not be replayed).
if [ -n "${SYSBENCH_RUN_EVENTS:-}" ]; then SYSBENCH_RUN_LIMIT="--events=$SYSBENCH_RUN_EVENTS --time=0"; else SYSBENCH_RUN_LIMIT="--time=$SYSBENCH_RUN_SECONDS"; fi
[ -z "$SYSBENCH_RUN_ARGS" ] 		&& export SYSBENCH_RUN_ARGS="--threads=$SYSBENCH_RUN_THREADS $SYSBENCH_RUN_LIMIT --rand-type=special --rand-seed=$(( (RANDOM << 15 | RANDOM) + 1 ))"
# SYSBENCH_RUN_EVENTS (1 Oct): fixed work for counting runs (--events=N --time=0); unset = time-based as before.
#--rand-type=uniform --report-interval=10


# Sysbench script file selection. "$SYSBENCH_SCRIPT_FILEPATH" is a resulting file:
[ -z "$SYSBENCH_SCRIPT_FILE" ] && {
	[ -z "$SYSBENCH_SCRIPT_FILENAME" ] && SYSBENCH_SCRIPT_FILENAME="oltp_read_only.lua"

	export SYSBENCH_SCRIPT_FILE="$SYSBENCH_SCRIPTS_DIR/$SYSBENCH_SCRIPT_FILENAME"
}

[ ! -f "$SYSBENCH_SCRIPT_FILE" ] && echo "No file $SYSBENCH_SCRIPT_FILE found." && exit 1


# TSan runtime options.  The default silences reports (benchmarking); the preservation runner
# (tools/preservation/run_preservation.py) starts mysqld itself with its own TSAN_OPTIONS
# and only needs the clients quiet, but server-run*.sh callers can set
# TSAN_OPTIONS_OVERRIDE to collect reports (e.g. "log_path=/abs/mysql.cfg.1 exitcode=0").
export TSAN_OPTIONS="${TSAN_OPTIONS_OVERRIDE:-report_bugs=0 verbosity=0}"

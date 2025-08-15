source callmysql-export-main-vars.sh


set -e

$MYSQL_DIR/mysql --user=root -e "CREATE DATABASE IF NOT EXISTS sbtest;" 2> bench-init.stderr.log

# Query the information_schema to see if the table exists.
SBTEST1_EXISTS=$($MYSQL_DIR/mysql --batch --skip-column-names --user=root -e "SELECT TABLE_NAME FROM information_schema.tables WHERE TABLE_SCHEMA = 'sbtest' AND TABLE_NAME = 'sbtest1';")

if [ "$SBTEST1_EXISTS" != "sbtest1" ]; then
	sysbench "$SYSBENCH_SCRIPT_FILE" $SYSBENCH_CONNECTION_ARGS prepare
else
	echo "Table 'sbtest1' already exists,"
	echo "Skipping command 'sysbench \"$SYSBENCH_SCRIPT_FILE\" $SYSBENCH_CONNECTION_ARGS prepare'."
fi

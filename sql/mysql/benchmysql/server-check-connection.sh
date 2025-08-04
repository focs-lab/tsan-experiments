#!/bin/bash

source callmysql-export-main-vars.sh || exit $?

set -e
$MYSQL_DIR/mysqladmin --user=root ping > /dev/null 2>&1
set +e

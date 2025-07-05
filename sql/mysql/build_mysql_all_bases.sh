#!/bin/bash

set -e

source ./config_definitions.sh || exit $?

#BUILDTYPELIST="tsan   tsan-swmr   tsan-lo"
#BUILDTYPELIST="tsan   tsan-dom-ea-lo-st-swmr   tsan-dom   tsan-ea   tsan-st   tsan-swmr   tsan-lo"
BUILDTYPELIST="${!CONFIG_DETAILS[@]}"

BUILDTYPELIST="$(echo $BUILDTYPELIST | xargs)"

for i in ${BUILDTYPELIST}; do
	echo -e "\n\e[94m ===== $i =====\e[0m\n"

	[ -f "mysql-$i/bin/mysqld" ] && echo -e "\n\e[94mSkipping $i, exists already...\e[0m\n" && sleep 3 && continue

	[ -d "mysql-$i" ] && echo "Moving directory 'mysql-$i' without bin/mysqld inside to 'mysql-$i-partial'..." && mv "mysql-$i" "mysql-$i-partial"

	./build_mysql.sh $i || {
		[ -d "mysql-$i-failed" ] && rm -r "mysql-$i-failed"
		mv "mysql-$i" "mysql-$i-failed"
		exit 1
	}
done

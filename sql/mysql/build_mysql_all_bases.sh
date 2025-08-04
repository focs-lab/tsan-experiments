#!/bin/bash

set -e

source ./config_definitions.sh || exit $?

#BUILDTYPELIST="tsan   tsan-swmr   tsan-lo"
#BUILDTYPELIST="tsan   tsan-dom-ea-lo-st-swmr   tsan-dom   tsan-ea   tsan-st   tsan-swmr   tsan-lo"
BUILDTYPELIST="${!CONFIG_DETAILS[@]}"


# === Internal section ===

BUILDTYPELIST="$(echo $BUILDTYPELIST | xargs)"

for i in ${BUILDTYPELIST}; do
	echo -e "\n\e[94m ===== $i =====\e[0m\n"

	[ -f "mysql-$i/bin/mysqld" ] && echo -e "\n\e[94mSkipping $i, exists already...\e[0m\n" && sleep 3 && continue

	[ -d "mysql-$i" ] && echo "Moving directory 'mysql-$i' without bin/mysqld inside to 'partial-mysql-$i'..." && mv "mysql-$i" "partial-mysql-$i"

	./build_mysql.sh $i || {
		[ -d "failed-mysql-$i" ] && rm -r "failed-mysql-$i"
		mv "mysql-$i" "failed-mysql-$i"
		exit 1
	}
done

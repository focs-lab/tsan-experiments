#!/bin/bash

# A wrapper script around the `./build_by_config.sh`.
# After run, ".." will have several subdirectories `outbin-*` named exactly 
#like `./config-memcached-*` in the memcached source dir, every has a binary 
#file `memcached` inside.
#
# Example. Current path is a memcached source dir:
# $ ls
# config-memcached-orig.sh config-memcached-tsan-ea.sh config-memcached-tsan-own.sh
#
# $ ./build_by_config.sh
# <A huge text output...>
#
# $ ls -p ../outbin-*
# outbin-orig/ outbin-tsan-ea/ outbin-tsan-own/
#
# $ ls ../outbin-tsan-ea
# memcached
#

BUILD_LIST_SCRIPTS="$(ls config-memcached-*.sh)"

for BUILD in $BUILD_LIST_SCRIPTS; do
	CUR_BUILD_PREFIX=`echo ${BUILD} | sed "s/config-memcached-\(.\+\)\.sh/\1/1"`

	echo -e "\n\e[1;97m === $CUR_BUILD_PREFIX === \e[m\n"

	./build_by_config.sh "$CUR_BUILD_PREFIX" --force-overwrite
done

#build_by_config.sh

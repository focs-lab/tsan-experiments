#!/bin/bash

# Just a wrapper around a command
#    `./run-memcached.sh outbin-TYPE && ./run-bench.sh`
#
# There's no VTune or perf profile saving, but you can freely add it.
#
# Also see a script "memcached-(version)/build_by_config_all_in_chain.sh".

set -e

for OUTBIN_DIR in $(ls outbin-*/memcached | sed "s=/.\+==g"); do
	./run-memcached.sh $OUTBIN_DIR && ./run-bench.sh || exit 2

	sleep 5
done

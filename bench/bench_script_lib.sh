#!/bin/bash

error_handling() {
	local -r EXITCODE=$?

	# Special error codes:
	#   66: overrided TSan warning;
	#   77: overrided MSan warning.
	local -ar SKIPCODES=(66 77)

	for SKIP in ${SKIPCODES[*]}; do
		if [ "$SKIP" -eq "$EXITCODE"  ]; then
			echo -e "\e[90mSkipping error code $EXITCODE.\e[0m"
			return 0
		fi
	done

	echo -e "\e[31mError code $EXITCODE on line $(caller)\e[0m"
	exit $EXITCODE
}

exit_handling() {
	error_handling_release
	trap - EXIT
}

error_handling_release() {
	trap - ERR
	#set +e
}

error_handling_set() {
	trap error_handling ERR
	trap exit_handling EXIT

	# Make script extremely sensible to errors:
	#set -e
}

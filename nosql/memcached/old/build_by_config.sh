#!/bin/bash

# A script to automate several actions when building memcached:
#  1. Call `make clean` to remove old artifacts.
#  2. Call `./config-memcached-$1.sh` (where '$1' is a first script argument, may be with or without a "tsan-" prefix).
#  3. Call `make -jN`. The project builds pretty fast on almost any number of threads...
#  4. Move the new `memcached` artifact by path "../outbin-$1".
#
# A wrapper `./build_by_config_all_in_chain.sh` utilizes this script.


[ -z "$1" ] && echo "Should be the ./config-memcached-*.sh file suffix." && exit 1

[ "$2" == "--force-overwrite" ] && echo "Force overwrite mode enabled." && OUTBIN_FORCE_OVERWRITE=1

if [ -x "config-memcached-$1.sh" ]; then
	CONFIG_SUFFIX="$1"

elif [ -x "config-memcached-tsan-$1.sh" ]; then
	CONFIG_SUFFIX="tsan-$1"

else
	echo "No file \"./config-memcached[-tsan]-$1.sh\"!"
	exit 2
fi

CONFIG_FILE="./config-memcached-${CONFIG_SUFFIX}.sh"
OUTBIN_DIR="../outbin-$CONFIG_SUFFIX"

if [ -f "$OUTBIN_DIR/memcached" ]; then
	if [ -z "$OUTBIN_FORCE_OVERWRITE" ]; then
		echo -e "\e[93mWarning: file \"$OUTBIN_DIR/memcached\" already exists.\e[m\nPress any key to continue or Ctrl + C to break..." && read -sn1
	else
		echo -e "\e[97mNote: file \"$OUTBIN_DIR/memcached\" already exists, overwriting because the \$OUTBIN_FORCE_OVERWRITE is set (via 2nd arg).\e[m\n"
	fi
fi

set -e


# Clean old artifacts:
echo -e "\e[34m\nCleaning...\n\e[m"
make clean

# Call config:
echo -e "\e[34m\nCall config \"$CONFIG_FILE\"...\n\e[m"
$CONFIG_FILE

# Make the file:
echo -e "\e[34m\nCall config \"$CONFIG_FILE\"...\n\e[m"
make -j12

# Move to necessary directory:
echo -e "\e[34m\nMoving to $OUTBIN_DIR ...\n\e[m"

[ ! -d "$OUTBIN_DIR" ] && echo -e "\e[34m\nCreating the directory...\n\e[m" && mkdir "$OUTBIN_DIR"
mv "memcached" "$OUTBIN_DIR/memcached"


# Finale:
echo -e "\e[92m\nSuccess!\n\e[m"

set +e

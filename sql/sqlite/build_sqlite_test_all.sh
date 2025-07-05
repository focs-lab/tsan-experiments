#!/bin/bash

set -e

# Source the configuration definitions
source ../../config_definitions.sh || exit $?

# Check if the CONFIG_DETAILS array was loaded
if [ ${#CONFIG_DETAILS[@]} -eq 0 ]; then
    echo "Error: Failed to load configuration definitions from config_definitions_sqlite.sh"
    exit 1
fi

echo "Starting build for all test configurations..."

# Iterate over all keys (configuration names) in CONFIG_DETAILS
for config_name in "${!CONFIG_DETAILS[@]}"; do
    echo "----------------------------------------"
    echo "Building configuration: $config_name"

    if ! bash ./build_sqlite_test.sh "$config_name"; then
        echo "Error building configuration: $config_name"
        exit 1
    fi

    rm -f *.db *.db-wal
done

# All optimizations
if ! bash ./build_sqlite_test.sh "tsan-dom-ea-lo-st-swmr"; then
    echo "Error building configuration: $config_name"
    exit 1
fi

rm -f *.db *.db-wal

echo "----------------------------------------"
echo "Building all configurations completed."
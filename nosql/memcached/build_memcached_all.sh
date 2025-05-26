#!/bin/bash

# Source the file with configuration definitions
# Make sure the path to config_definitions.sh is correct
# if it is not in the same directory as this script.
source ./config_definitions.sh

# Check if CONFIG_DETAILS was loaded
if [ ${#CONFIG_DETAILS[@]} -eq 0 ]; then
    echo "Error: Failed to load configuration definitions from config_definitions.sh"
    exit 1
fi

echo "Starting build for all configurations..."

# Iterate over all keys (configuration names) in CONFIG_DETAILS
for config_name in "${!CONFIG_DETAILS[@]}"; do
    echo "Building configuration: $config_name"

    # Run ./build_memcached.sh with the configuration name
    # Ensure build_memcached.sh is executable and in PATH
    # or provide the full/relative path to it.
    if ! bash ./build_memcached.sh "$config_name"; then
        echo "Error building configuration: $config_name"
        # You can decide whether to abort the entire process on error
        # exit 1
    fi
    echo "----------------------------------------"
done

echo "Building all configurations completed."
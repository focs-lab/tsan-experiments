#!/bin/bash

# Check if an argument was provided
if [ -z "$1" ]; then
    echo "Usage: $0 <path_to_log_directory>"
    exit 1
fi

LOG_DIR=$1

# Check if the path is a directory
if [ ! -d "$LOG_DIR" ]; then
    echo "Error: Directory not found '$LOG_DIR'"
    exit 1
fi

# Print table header
printf "+%s+%s+%s+\n" "---------------------------------------------------------" "----------------------" "----------------------"
printf "| %-55s | %-20s | %-20s |\n" "Log File" "Unique addresses" "Accesses"
# Print separator
printf "+%s+%s+%s+\n" "---------------------------------------------------------" "----------------------" "----------------------"

# Loop through all .log files in the directory
for logfile in "$LOG_DIR"/*.log; do
    # Make sure it's a file
    if [ -f "$logfile" ]; then
        # Extract the LAST non-zero value for "Unique addresses"
        addresses=$(grep "^Unique addresses:" "$logfile" | grep -v ":\s\+0$" | tail -n 1 | awk '{print $NF}')
        # Extract the LAST non-zero value for "Accesses"
        accesses=$(grep "^Accesses:" "$logfile" | grep -v ":\s\+0$" | tail -n 1 | awk '{print $NF}')

        # If both metrics are found, print a table row
        if [ -n "$addresses" ] && [ -n "$accesses" ]; then
            filename=$(basename "$logfile")
            printf "| %-55s | %-20s | %-20s |\n" "$filename" "$addresses" "$accesses"
        fi
    fi
done

# Print the bottom border of the table
printf "+%s+%s+%s+\n" "---------------------------------------------------------" "----------------------" "----------------------"
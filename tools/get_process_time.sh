#!/bin/bash

# Usage: ./monitor.sh <PID> <output_file>

PID=$1
OUTFILE=$2

if [ -z "$PID" ] || [ -z "$OUTFILE" ]; then
    echo "Usage: $0 <PID> <output_file>"
    exit 1
fi

if ! ps -p "$PID" > /dev/null 2>&1; then
    echo "Process with PID $PID not found"
    exit 1
fi

# Get system parameters
HZ=$(getconf CLK_TCK)
proc_stat=$(</proc/$PID/stat)
proc_start_ticks=$(echo "$proc_stat" | awk '{print $22}')
uptime=$(awk '{print $1}' /proc/uptime)

# Process start time in seconds since Unix epoch
boot_time=$(($(date +%s) - ${uptime%.*}))
proc_start_sec=$(( boot_time + proc_start_ticks / HZ ))

# Wait for process to finish
while ps -p "$PID" > /dev/null 2>&1; do
    sleep 1
done

end_time=$(date +%s)
elapsed=$(( end_time - proc_start_sec ))

echo "Process $PID ran for $elapsed seconds" >> "$OUTFILE"


cat $1 | grep -E '======|^Summary:|^  throughput summary:|avg|^  latency summary:|^[[:space:]]*[0-9.]+' | grep -vE "cumulative|benchmark" 2>&1 | grep .


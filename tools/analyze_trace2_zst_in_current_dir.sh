#!/bin/bash

set -u -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
ANALYSIS_SCRIPT="$SCRIPT_DIR/trace-analyze2.py"
TARGET_DIR=$(pwd)
RESULTS_DIR="$TARGET_DIR/results"

declare -a PIDS=()

_total_cpus() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    else
        getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
    fi
}

resolve_max_jobs() {
    local jobs_value

    jobs_value="${TRACE_ANALYZE_JOBS:-$(_total_cpus)}"

    if ! [[ "$jobs_value" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: TRACE_ANALYZE_JOBS must be a positive integer, got '$jobs_value'." >&2
        return 1
    fi

    echo "$jobs_value"
}

action_on_signal() {
    local pid
    echo
    echo "Interrupted. Stopping running analyses..." >&2
    for pid in "${PIDS[@]}"; do
        kill "$pid" >/dev/null 2>&1 || true
    done
    wait >/dev/null 2>&1 || true
    exit 130
}

process_trace() {
    local zst_file="$1"
    local base_name output_file

    base_name=$(basename -- "$zst_file" .zst)
    output_file="$RESULTS_DIR/${base_name}.log"

    (
        temp_file=$(mktemp --tmpdir="$TARGET_DIR" ".${base_name}.trace-analyze2.XXXXXX")
        trap 'rm -f -- "$temp_file"' EXIT INT TERM

        echo " - Processing '$(basename -- "$zst_file")'..."

        if ! zstd -d -c -- "$zst_file" > "$temp_file"; then
            echo "   -> Failed to decompress '$zst_file'" >&2
            exit 1
        fi

        if python3 "$ANALYSIS_SCRIPT" "$temp_file" > "$output_file"; then
            echo "   -> Result saved to '$output_file'"
            exit 0
        fi

        echo "   -> Error while analyzing '$zst_file'. Check '$output_file'." >&2
        exit 1
    )
}

trap action_on_signal INT TERM

if ! MAX_JOBS=$(resolve_max_jobs); then
    exit 1
fi

echo "Searching for .zst traces in '$TARGET_DIR'..."
echo "Running up to $MAX_JOBS analysis process(es) in parallel."

found_any=0
failed_any=0
active_jobs=0

while IFS= read -r -d '' zst_file; do
    if [ "$found_any" -eq 0 ]; then
        mkdir -p -- "$RESULTS_DIR"
    fi
    found_any=1

    process_trace "$zst_file" &
    PIDS+=("$!")
    active_jobs=$((active_jobs + 1))

    if [ "$active_jobs" -ge "$MAX_JOBS" ]; then
        if ! wait -n; then
            failed_any=1
        fi
        active_jobs=$((active_jobs - 1))
    fi
done < <(find "$TARGET_DIR" -maxdepth 1 -type f -name '*.zst' -print0)

if [ "$found_any" -eq 0 ]; then
    echo "No .zst files found in '$TARGET_DIR'."
    exit 0
fi

while [ "$active_jobs" -gt 0 ]; do
    if ! wait -n; then
        failed_any=1
    fi
    active_jobs=$((active_jobs - 1))
done

echo
if [ "$failed_any" -eq 0 ]; then
    echo "Analysis complete. All results are in '$RESULTS_DIR'."
else
    echo "Analysis complete with errors. Partial results are in '$RESULTS_DIR'." >&2
    exit 1
fi


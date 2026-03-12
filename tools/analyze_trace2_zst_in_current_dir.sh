#!/bin/bash

set -u -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
ANALYSIS_SCRIPT="$SCRIPT_DIR/trace-analyze2.py"
TARGET_DIR=$(pwd)
RESULTS_DIR="$TARGET_DIR/results"

declare -a TEMP_FILES=()

cleanup() {
    local temp_file
    for temp_file in "${TEMP_FILES[@]}"; do
        if [ -n "$temp_file" ] && [ -f "$temp_file" ]; then
            rm -f -- "$temp_file"
        fi
    done
}

trap cleanup EXIT INT TERM

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: 'python3' is not installed or not available in PATH." >&2
    exit 1
fi

if ! command -v zstd >/dev/null 2>&1; then
    echo "Error: 'zstd' command-line utility is not installed." >&2
    exit 1
fi

if [ ! -f "$ANALYSIS_SCRIPT" ]; then
    echo "Error: analysis script '$ANALYSIS_SCRIPT' was not found." >&2
    exit 1
fi

echo "Searching for .zst traces in '$TARGET_DIR'..."

found_any=0
failed_any=0

while IFS= read -r -d '' zst_file; do
    if [ "$found_any" -eq 0 ]; then
        mkdir -p -- "$RESULTS_DIR"
    fi
    found_any=1

    base_name=$(basename -- "$zst_file" .zst)
    output_file="$RESULTS_DIR/${base_name}.log"
    temp_file=$(mktemp --tmpdir="$TARGET_DIR" ".${base_name}.trace-analyze2.XXXXXX")
    TEMP_FILES+=("$temp_file")

    echo " - Processing '$(basename -- "$zst_file")'..."

    if ! zstd -d -c -- "$zst_file" > "$temp_file"; then
        echo "   -> Failed to decompress '$zst_file'" >&2
        rm -f -- "$temp_file"
        TEMP_FILES=("${TEMP_FILES[@]/$temp_file}")
        failed_any=1
        continue
    fi

    if python3 "$ANALYSIS_SCRIPT" "$temp_file" > "$output_file"; then
        echo "   -> Result saved to '$output_file'"
    else
        echo "   -> Error while analyzing '$zst_file'. Check '$output_file'." >&2
        failed_any=1
    fi

    rm -f -- "$temp_file"
    TEMP_FILES=("${TEMP_FILES[@]/$temp_file}")
done < <(find "$TARGET_DIR" -maxdepth 1 -type f -name '*.zst' -print0)

if [ "$found_any" -eq 0 ]; then
    echo "No .zst files found in '$TARGET_DIR'."
    exit 0
fi

echo
if [ "$failed_any" -eq 0 ]; then
    echo "Analysis complete. All results are in '$RESULTS_DIR'."
else
    echo "Analysis complete with errors. Partial results are in '$RESULTS_DIR'." >&2
    exit 1
fi


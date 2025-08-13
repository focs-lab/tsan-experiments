#!/bin/bash

# Make sure the script exits on error
set -e

# --- Variables ---
CONFIG_DIR="build/config/sanitizers"
BUILD_GN_PATH="$CONFIG_DIR/BUILD.gn"
RESULTS_DIR="__results__"
RESULTS_FILE="$RESULTS_DIR/compilation_time.txt"
STATS_DIR="$RESULTS_DIR/stats"
STATS_FILE="$STATS_DIR/instr_count.log"
OUT_DIR="out"
TSAN_DIR="tsan"

# --- Functions ---

# Function for printing log messages
log() {
  echo "==> $1"
}

# Function to rename the tsan directory if it exists
rename_tsan_dir() {
  if [ -d "$TSAN_DIR" ]; then
    local dest_dir="__tsan__old"
    if [ -d "$dest_dir" ]; then
      local i=1
      while [ -d "${dest_dir}${i}" ]; do
        i=$((i+1))
      done
      dest_dir="${dest_dir}${i}"
    fi
    log "Renaming '$TSAN_DIR' to '$dest_dir'"
    mv "$TSAN_DIR" "$dest_dir"
  else
    log "'$TSAN_DIR' directory not found, skipping rename."
  fi
}

# --- Main Script ---

# 1. Create the results directory and clear the results file
log "Creating results directory: $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
echo "Compilation time (in seconds):" > "$RESULTS_FILE"
log "Results file '$RESULTS_FILE' has been cleared."

# Create stats directory and file
log "Creating stats directory: $STATS_DIR"
mkdir -p "$STATS_DIR"
echo "Instrumented instruction count:" > "$STATS_FILE"
log "Stats file '$STATS_FILE' has been created."
echo ""

# 2. Back up the original BUILD.gn
if [ -f "$BUILD_GN_PATH" ]; then
  log "Backing up original $BUILD_GN_PATH to $BUILD_GN_PATH.bak"
  cp "$BUILD_GN_PATH" "$BUILD_GN_PATH.bak"
else
  log "Original $BUILD_GN_PATH not found. Skipping backup."
fi

# 3. Build the original 'orig' configuration
log "Building original configuration: chrome-orig"
rename_tsan_dir
start_time=$SECONDS
autoninja -C "$OUT_DIR/chrome-orig" chrome
duration=$(( SECONDS - start_time ))
log "Finished in $duration seconds."
echo "orig: $duration" >> "$RESULTS_FILE"
log "Result for 'orig' saved to $RESULTS_FILE"

# Summarize and save instruction stats for 'orig'
log "Summarizing instruction statistics for orig"
instr_count=$(summarize_instr_stats.py)
log "Instrumented instructions: $instr_count"
echo "orig: $instr_count" >> "$STATS_FILE"
log "Result for 'orig' saved to $STATS_FILE"
echo ""


# 4. Iterate over sanitizer configurations
for config_file in "$CONFIG_DIR"/BUILD.gn.*; do
  # Skip the backup file
  if [[ "$config_file" == *".bak" ]]; then
    continue
  fi

  # 5. Extract the configuration name from the filename
  CONFIG=$(echo "$config_file" | sed "s|$CONFIG_DIR/BUILD.gn.||")
  log "Starting work on configuration: $CONFIG"

  # 6. Replace the BUILD.gn file
  log "Copying $config_file to $BUILD_GN_PATH"
  cp "$config_file" "$BUILD_GN_PATH"

  # 7. Run the build and measure the time
  rename_tsan_dir
  log "Running autoninja for chrome-$CONFIG"
  start_time=$SECONDS
  autoninja -C "$OUT_DIR/chrome-$CONFIG" chrome
  duration=$(( SECONDS - start_time ))
  log "Finished in $duration seconds."

  # 8. Write the result to the file
  echo "$CONFIG: $duration" >> "$RESULTS_FILE"
  log "Result for '$CONFIG' saved to $RESULTS_FILE"

  # Summarize and save instruction stats for the current config
  log "Summarizing instruction statistics for $CONFIG"
  instr_count=$(summarize_instr_stats.py)
  log "Instrumented instructions: $instr_count"
  echo "$CONFIG: $instr_count" >> "$STATS_FILE"
  log "Result for '$CONFIG' saved to $STATS_FILE"
  echo ""
done

# 9. Restore the original BUILD.gn
if [ -f "$BUILD_GN_PATH.bak" ]; then
  log "Restoring original $BUILD_GN_PATH from backup"
  mv "$BUILD_GN_PATH.bak" "$BUILD_GN_PATH"
fi

log "Script finished successfully. All results are in $RESULTS_FILE and $STATS_FILE."
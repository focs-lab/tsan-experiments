#!/bin/bash

# Make sure the script exits on error
set -e

# --- Variables ---
CONFIG_DIR="build/config/sanitizers"
BUILD_GN_PATH="$CONFIG_DIR/BUILD.gn"
ARGS_GN_TEMPLATE_DIR="args.gn"
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

# Function to rename a directory if it exists by adding a suffix
rename_dir_with_suffix() {
  local dir_to_rename=$1
  local dest_base_name=$2
  if [ -d "$dir_to_rename" ]; then
    local dest_dir="$dest_base_name"
    if [ -d "$dest_dir" ]; then
      local i=1
      while [ -d "${dest_dir}${i}" ]; do
        i=$((i+1))
      done
      dest_dir="${dest_dir}${i}"
    fi
    log "Renaming '$dir_to_rename' to '$dest_dir'"
    mv "$dir_to_rename" "$dest_dir"
  else
    log "'$dir_to_rename' directory not found, skipping rename."
  fi
}

# --- Main Script ---

# 0. Rename old directories
rename_dir_with_suffix "$OUT_DIR" "out_old"
rename_dir_with_suffix "$TSAN_DIR" "__tsan__old"

# 1. Create the results and output directories
log "Creating results directory: $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
echo "Compilation time (in seconds):" > "$RESULTS_FILE"
log "Results file '$RESULTS_FILE' has been cleared."

log "Creating new output directory: $OUT_DIR"
mkdir -p "$OUT_DIR"

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
CONFIG_NAME="orig"
CURRENT_OUT_DIR="$OUT_DIR/chrome-$CONFIG_NAME"
log "Starting work on configuration: $CONFIG_NAME"
log "Creating output directory: $CURRENT_OUT_DIR"
mkdir -p "$CURRENT_OUT_DIR"

log "Copying args.gn for $CONFIG_NAME"
cp "$ARGS_GN_TEMPLATE_DIR/args.gn.orig" "$CURRENT_OUT_DIR/args.gn"

log "Building original configuration: chrome-$CONFIG_NAME"
SECONDS=0
start_time=$SECONDS
autoninja -C "$CURRENT_OUT_DIR" chrome
duration=$(( SECONDS - start_time ))
log "Finished in $duration seconds."
echo "$CONFIG_NAME: $duration" >> "$RESULTS_FILE"
log "Result for '$CONFIG_NAME' saved to $RESULTS_FILE"

# Summarize and save instruction stats for 'orig'
log "Summarizing instruction statistics for $CONFIG_NAME"
instr_count=$(summarize_instr_stats.py)
log "Instrumented instructions: $instr_count"
echo "$CONFIG_NAME: $instr_count" >> "$STATS_FILE"
log "Result for '$CONFIG_NAME' saved to $STATS_FILE"
echo ""

# 4. Iterate over sanitizer configurations
for config_file in "$CONFIG_DIR"/BUILD.gn.*; do
  # Skip the backup file
  if [[ "$config_file" == *".bak" ]]; then
    continue
  fi

  # 5. Extract the configuration name and prepare directories
  CONFIG=$(echo "$config_file" | sed "s|$CONFIG_DIR/BUILD.gn.||")
  CURRENT_OUT_DIR="$OUT_DIR/chrome-$CONFIG"
  log "Starting work on configuration: $CONFIG"
  log "Creating output directory: $CURRENT_OUT_DIR"
  mkdir -p "$CURRENT_OUT_DIR"

  # 6. Copy the correct args.gn and BUILD.gn files
  log "Copying args.gn for $CONFIG"
  cp "$ARGS_GN_TEMPLATE_DIR/args.gn.tsan" "$CURRENT_OUT_DIR/args.gn"

  log "Copying $config_file to $BUILD_GN_PATH"
  cp "$config_file" "$BUILD_GN_PATH"
  
  # Rename tsan dir before build
  rename_dir_with_suffix "$TSAN_DIR" "__tsan__old"

  # 7. Run the build and measure the time
  log "Running autoninja for chrome-$CONFIG"
  SECONDS=0
  start_time=$SECONDS
  autoninja -C "$CURRENT_OUT_DIR" chrome
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
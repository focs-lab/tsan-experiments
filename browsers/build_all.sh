#!/bin/bash

# Make sure the script exits on error
set -e

# --- Variables ---
CONFIG_DIR="build/config/sanitizers"
BUILD_GN_PATH="$CONFIG_DIR/BUILD.gn"
RESULTS_DIR="__results__"
RESULTS_FILE="$RESULTS_DIR/compilation_time.txt"
OUT_DIR="out"

# --- Functions ---

# Function for printing log messages
log() {
  echo "==> $1"
}

# --- Main Script ---

# 1. Create the results directory and clear the results file
log "Creating results directory: $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
echo "Compilation time (in seconds):" > "$RESULTS_FILE"
log "Results file '$RESULTS_FILE' has been cleared."
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
start_time=$SECONDS
autoninja -C "$OUT_DIR/chrome-orig" chrome
duration=$(( SECONDS - start_time ))
log "Finished in $duration seconds."
echo "orig: $duration" >> "$RESULTS_FILE"
log "Result for 'orig' saved to $RESULTS_FILE"
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
  log "Running autoninja for chrome-$CONFIG"
  start_time=$SECONDS
  autoninja -C "$OUT_DIR/chrome-$CONFIG" chrome
  duration=$(( SECONDS - start_time ))
  log "Finished in $duration seconds."

  # 8. Write the result to the file
  echo "$CONFIG: $duration" >> "$RESULTS_FILE"
  log "Result for '$CONFIG' saved to $RESULTS_FILE"
  echo ""
done

# 9. Restore the original BUILD.gn
if [ -f "$BUILD_GN_PATH.bak" ]; then
  log "Restoring original $BUILD_GN_PATH from backup"
  mv "$BUILD_GN_PATH.bak" "$BUILD_GN_PATH"
fi

log "Script finished successfully. All results are in $RESULTS_FILE."

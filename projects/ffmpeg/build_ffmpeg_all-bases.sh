#!/bin/bash

set -e

# --- Variables ---
RESULTS_DIR="results_ffmpeg"
RESULTS_FILE="$RESULTS_DIR/compilation_time.txt"
STATS_FILE="$RESULTS_DIR/instr_count.log"
TSAN_TMP_DIR="/tmp/__tsan__"

# --- Functions ---

# Function for printing log messages
log() {
  echo "==> $1"
}

# Function to rename a directory if it exists by adding a numeric suffix if needed
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
    log "Directory '$dir_to_rename' not found, skipping."
  fi
}

# --- Main Script ---

# 1. Source the configuration definitions
source ./config_definitions.sh || exit $?

# Check if CONFIG_DETAILS were loaded
if [ ${#CONFIG_DETAILS[@]} -eq 0 ]; then
    log "Error: Failed to load configuration definitions from config_definitions.sh"
    exit 1
fi

# List of configurations to build
BUILDTYPELIST="orig tsan tsan-dom tsan-ea tsan-lo tsan-st tsan-swmr tsan-dom-ea-lo-st-swmr"
BUILDTYPELIST="$(echo $BUILDTYPELIST | xargs)"

# 2. Create results directory and clear/create the results files
log "Creating results directory: $RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
echo "Compilation time (in seconds):" > "$RESULTS_FILE"
log "Results file '$RESULTS_FILE' has been cleared."
echo "Instrumented instruction count:" > "$STATS_FILE"
log "Stats file '$STATS_FILE' has been cleared."

log "Starting FFmpeg build for all configurations..."

# 3. Iterate over all configurations
for config_name in $BUILDTYPELIST; do
	log "===== Building configuration: $config_name ====="

	if [ -d "ffmpeg-$config_name" ]; then
		log "Skipping $config_name, directory already exists."
		continue
	fi

	# Rename the temporary TSan directory before the build
	rename_dir_with_suffix "$TSAN_TMP_DIR" "${TSAN_TMP_DIR}_ffmpeg_old"
	mkdir -p "$TSAN_TMP_DIR"

	# 4. Run the build and measure the time
	start_time=$SECONDS
	if ! ./build_ffmpeg.sh "$config_name"; then
		log "Error building configuration: $config_name"
		exit 1
	fi
	duration=$(( SECONDS - start_time ))
	log "Finished building '$config_name' in $duration seconds."

	# 5. Write the compilation time to the file
	echo "$config_name: $duration" >> "$RESULTS_FILE"
	log "Result for '$config_name' saved to $RESULTS_FILE"

	# 6. Summarize and save instruction stats
	log "Summarizing instruction statistics for $config_name"
	instr_count=$(summarize_instr_stats.py)
	log "Instrumented instructions: $instr_count"
	echo "$config_name: $instr_count" >> "$STATS_FILE"
	log "Result for '$config_name' saved to $STATS_FILE"
	log "----------------------------------------"
done

log "Building all FFmpeg configurations completed. All results are in $RESULTS_DIR."
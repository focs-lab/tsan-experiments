#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Variables ---
SQLITE_SRC_DIR="sqlite-src-3500200"
CONFIG_DEFINITIONS_FILE="../../config_definitions.sh"
# --- End of Variables ---

# Source the configuration definitions
if [ -f "$CONFIG_DEFINITIONS_FILE" ]; then
    source "$CONFIG_DEFINITIONS_FILE"
else
    echo "Error: Configuration definitions file '$CONFIG_DEFINITIONS_FILE' not found."
    exit 1
fi

# Function to print available configurations
print_available_configs() {
  echo "Available atomic configurations (from $CONFIG_DEFINITIONS_FILE):"
  for key in "${!CONFIG_DETAILS[@]}"; do
    echo "  - $key"
  done
}

# --- Main Script Logic ---
CONFIG_TYPE=$1

if [ -z "$CONFIG_TYPE" ]; then
  echo "Usage: $0 <config_type>"
  echo "Example: $0 tsan-lo"
  print_available_configs
  exit 1
fi

# Check for required files
if [ ! -f "build/sqlite3.c" ] || [ ! -d "$SQLITE_SRC_DIR" ]; then
    echo "Error: Required build files not found."
    echo "Ensure that 'build/sqlite3.c' and the '$SQLITE_SRC_DIR' directory exist."
    echo "You might need to run 'download_and_compile_sqlite.sh' first."
    exit 1
fi

# Determine compiler and flags
FLAGS_COMMON_BASE_VAL="-g -O2"
FLAGS_TSAN_COMMON_VAL="-fsanitize=thread"
FINAL_CFLAGS=""
TARGET_CC=""

if [ -n "$LLVM_ROOT_PATH" ] && [ -x "$LLVM_ROOT_PATH/bin/clang" ]; then
    TARGET_CC="$LLVM_ROOT_PATH/bin/clang"
else
    TARGET_CC="clang"
    echo "INFO: LLVM_ROOT_PATH is not set or clang was not found there. Using system clang."
fi

if [[ "$CONFIG_TYPE" == "orig" ]]; then
    FINAL_CFLAGS="$FLAGS_COMMON_BASE_VAL"
elif [[ "$CONFIG_TYPE" == tsan* ]]; then
    BASE_TSAN_FLAGS="$FLAGS_TSAN_COMMON_VAL $FLAGS_COMMON_BASE_VAL"
    COMBINED_EXTRA_FLAGS=""

    IFS='-' read -r -a parts <<< "$CONFIG_TYPE"
    if [ ${#parts[@]} -gt 1 ]; then
      for i in $(seq 1 $((${#parts[@]} - 1))); do
          suffix="${parts[$i]}"
          atomic_config_key="tsan-${suffix}"
          if [[ -v CONFIG_DETAILS["$atomic_config_key"] ]]; then
              COMBINED_EXTRA_FLAGS+=" ${CONFIG_DETAILS[$atomic_config_key]}"
          else
              echo "Error: Unknown configuration suffix '-$suffix' in '$CONFIG_TYPE'."
              exit 1
          fi
      done
    fi
    FINAL_CFLAGS="$BASE_TSAN_FLAGS$COMBINED_EXTRA_FLAGS"
else
    echo "Error: Unknown config type '$CONFIG_TYPE'."
    print_available_configs
    exit 1
fi

# Remove leading/trailing spaces
FINAL_CFLAGS=$(echo "$FINAL_CFLAGS" | xargs)
BUILD_SUBDIR="build/test-${CONFIG_TYPE}"

echo "--- Preparing to build test: $CONFIG_TYPE ---"
echo "Build directory: $BUILD_SUBDIR"
echo "Compiler: $TARGET_CC"
echo "Final CFLAGS: $FINAL_CFLAGS"

# Create the directory for this configuration
mkdir -p "$BUILD_SUBDIR"

# Compile the test
$TARGET_CC $FINAL_CFLAGS -DSQLITE_THREADSAFE=1 \
    ./threadtest3.c \
    build/sqlite3.c \
    "$SQLITE_SRC_DIR/src/test_multiplex.c" \
    -I "$SQLITE_SRC_DIR/test/" \
    -I "$SQLITE_SRC_DIR/src/" \
    -ldl -lpthread -lm \
    -o "$BUILD_SUBDIR/threadtest3"

echo "--- Build for $CONFIG_TYPE completed successfully ---"
echo "Executable is at: $BUILD_SUBDIR/threadtest3"

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
FLAGS_COMMON_BASE_VAL="-g -O2 -fno-omit-frame-pointer"
# TSAN_EXTRA_MLLVM: campaign-wide -mllvm additions tied to the COMPILER rather than to a configuration name.
# Unset by default, so an unset environment reproduces every earlier build exactly. Used for
# -tsan-ea-report-abandoned, which exists only in compilers carrying the EA compile-time series: baking it into
# config_definitions.sh would kill every build on a compiler that lacks it, with "Unknown command line argument".
FLAGS_TSAN_COMMON_VAL="-fsanitize=thread ${TSAN_EXTRA_MLLVM:-}"
FINAL_CFLAGS=""
TARGET_CC=""

# tools/tsan_compiler.sh sets TSAN_CC (honours LLVM_TSAN_ROOT, verifies LLVM_ROOT_PATH).
source ../../tools/tsan_compiler.sh
source ../../tools/write_build_info.sh   # (moved up: build_stamp_of/compiler_stamp_of are used by the archive rule)
TARGET_CC="$TSAN_CC"

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
# BUILD_ROOT lets A/B builds with another compiler (LLVM_TSAN_ROOT) live next to the default ones.
# BUILD_TAG (e.g. -wp) is appended to the directory name only (run_sqlite_test.sh <cfg><tag> finds it).
BUILD_SUBDIR="${BUILD_ROOT:-build}/test-${CONFIG_TYPE}${BUILD_TAG:-}"

# Whole-program summaries (sound interface): USE_SUMMARIES=1 SUMMARIES_DIR=<dir from gen_summaries.sh>.
SUMMARY_NOTE="summaries: none"
if [[ "${USE_SUMMARIES:-0}" == "1" && "$CONFIG_TYPE" != "orig" && "$CONFIG_TYPE" != "tsan" ]]; then
    for f in st lo ea; do [ -s "$SUMMARIES_DIR/${f}_summary.txt" ] || { echo "Error: USE_SUMMARIES=1 but $SUMMARIES_DIR/${f}_summary.txt is missing or empty."; exit 1; }; done
    SUMMARY_ID=$(sed -n 's/^# tsan-summary-id: *//p' "$SUMMARIES_DIR/st_summary.txt" | head -1)
    [ -n "$SUMMARY_ID" ] || { echo "Error: $SUMMARIES_DIR/st_summary.txt has no '# tsan-summary-id:' header."; exit 1; }
    SUMMARIES_ABS=$(readlink -f "$SUMMARIES_DIR")
    FINAL_CFLAGS="$FINAL_CFLAGS -mllvm -tsan-use-analysis-summaries -mllvm -tsan-summary-dir=$SUMMARIES_ABS -mllvm -tsan-summary-id=$SUMMARY_ID"
    SUMMARY_NOTE="summaries: $SUMMARIES_DIR id=$SUMMARY_ID ($(md5sum "$SUMMARIES_DIR"/{st,lo,ea}_summary.txt | awk '{print $1}' | cut -c1-8 | tr '\n' ' '))"
    echo "Using whole-program summaries from $SUMMARIES_DIR/ (id $SUMMARY_ID)."
fi

echo "--- Preparing to build test: $CONFIG_TYPE ---"
echo "Build directory: $BUILD_SUBDIR"
echo "Compiler: $TARGET_CC"
echo "Final CFLAGS: $FINAL_CFLAGS"

# Create the directory for this configuration.  A binary without build_info.txt predates
# this script version (paper-era, March 2026): keep it under build/old-builds/ for provenance.
if [ -f "$BUILD_SUBDIR/threadtest3" ] && [ ! -f "$BUILD_SUBDIR/build_info.txt" ]; then
    OLD_STAMP=$(date -r "$BUILD_SUBDIR/threadtest3" +%Y%m%d)
    OLD_DIR="${BUILD_ROOT:-build}/old-builds"
    mkdir -p "$OLD_DIR"
    echo "Archiving paper-era build $BUILD_SUBDIR -> $OLD_DIR/test-${CONFIG_TYPE}${BUILD_TAG:-}.$OLD_STAMP"
    rm -rf "$OLD_DIR/test-${CONFIG_TYPE}${BUILD_TAG:-}.$OLD_STAMP"
    mv "$BUILD_SUBDIR" "$OLD_DIR/test-${CONFIG_TYPE}${BUILD_TAG:-}.$OLD_STAMP"
elif [ -f "$BUILD_SUBDIR/build_info.txt" ]; then
    # A build of another compiler is archived by its stamp, never overwritten in place (lab rule); a build of
    # the same compiler is simply rebuilt.
    OLD_STAMP=$(build_stamp_of "$BUILD_SUBDIR"); CUR_STAMP=$(compiler_stamp_of "$TARGET_CC")
    if [ -n "$OLD_STAMP" ] && [ "$OLD_STAMP" != "$CUR_STAMP" ]; then
        OLD_DIR="${BUILD_ROOT:-build}/old-builds"; mkdir -p "$OLD_DIR"
        echo "Archiving build of another compiler $BUILD_SUBDIR -> $OLD_DIR/test-${CONFIG_TYPE}${BUILD_TAG:-}.$OLD_STAMP"
        rm -rf "$OLD_DIR/test-${CONFIG_TYPE}${BUILD_TAG:-}.$OLD_STAMP"; mv "$BUILD_SUBDIR" "$OLD_DIR/test-${CONFIG_TYPE}${BUILD_TAG:-}.$OLD_STAMP"
    fi
fi
mkdir -p "$BUILD_SUBDIR"

# Compile the test.
# -I build/ COMES FIRST AND IS NOT OPTIONAL. threadtest3.c includes <sqlite3.h> with angle brackets, so it
# is found only through an -I path. The amalgamation writes sqlite3.h into build/ beside sqlite3.c, and
# without that -I the compile falls through to whatever /usr/include holds: on this host that is the
# distribution's sqlite3.h at 3.45.1, compiled against the 3.50.2 amalgamation we actually link, and in a
# container with no libsqlite3-dev it is nothing at all and the build fails (rehearsal of 2026-09-17).
# Putting build/ first also means the header and the implementation are the same SQLite version everywhere,
# which is what the pinned archive in tools/source_archives.sha256 is supposed to guarantee.
$TARGET_CC $FINAL_CFLAGS -DSQLITE_THREADSAFE=1 \
    ./threadtest3.c \
    build/sqlite3.c \
    "$SQLITE_SRC_DIR/src/test_multiplex.c" \
    -I build/ \
    -I "$SQLITE_SRC_DIR/test/" \
    -I "$SQLITE_SRC_DIR/src/" \
    -ldl -lpthread -lm \
    -o "$BUILD_SUBDIR/threadtest3"

# Record compiler/tree/flags next to the binary (picked up by tools/preservation/run_preservation.py).
write_build_info "$BUILD_SUBDIR" "$TARGET_CC" "$FINAL_CFLAGS" "config: $CONFIG_TYPE" "$SUMMARY_NOTE"

echo "--- Build for $CONFIG_TYPE completed successfully ---"
echo "Executable is at: $BUILD_SUBDIR/threadtest3"

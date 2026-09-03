#!/bin/bash

#set -e # Exit immediately if a command exits with a non-zero status.

# --- Configurable Variables ---
FFMPEG_ARCHIVE="FFmpeg-n4.3.9.tar.gz"
CONFIG_DEFINITIONS_FILE="config_definitions.sh"
# --- End of Configurable Variables ---

# Source the configuration definitions
if [ -f "$CONFIG_DEFINITIONS_FILE" ]; then
    # shellcheck source=config_definitions.sh
    source "$CONFIG_DEFINITIONS_FILE"
else
    echo "Error: Configuration definitions file '$CONFIG_DEFINITIONS_FILE' not found."
    exit 1
fi

# Function to print available configuration types
print_available_configs() {
  echo "Available atomic config types (defined in $CONFIG_DEFINITIONS_FILE):"
  for key in "${!CONFIG_DETAILS[@]}"; do
    echo "  - $key"
  done
  echo
  echo "TSan configurations (e.g., tsan-own, tsan-st) can be combined."
  echo "For example: tsan-own-st will apply both 'own' and 'st' TSan optimizations."
  echo "The base 'tsan' configuration cannot be part of a suffix combination string itself"
  echo "and 'orig' cannot be combined."
}

# --- Main Script Logic ---
CONFIG_TYPE=$1

if [ -z "$CONFIG_TYPE" ]; then
  echo "Usage: $0 <config_type>"
  echo "Example: $0 tsan-own-st"
  print_available_configs
  exit 1
fi

# Validate archive
if [ ! -f "$FFMPEG_ARCHIVE" ]; then
    echo "Error: FFmpeg archive '$FFMPEG_ARCHIVE' not found."
    exit 1
fi

# Determine compiler and base flags
FLAGS_COMMON_BASE_VAL="-g -O2"
FLAGS_TSAN_COMMON_VAL="-fsanitize=thread"
FINAL_CFLAGS=""
TARGET_CC=""

if [[ "$CONFIG_TYPE" == "orig" ]]; then
    IS_TSAN_BUILD=false
    FINAL_CFLAGS="$FLAGS_COMMON_BASE_VAL"
    # For 'orig', try to use LLVM_ROOT_PATH/bin/gcc, then system gcc, then LLVM_ROOT_PATH/bin/clang, then system clang
    # However, your previous edit hardcoded LLVM_ROOT_PATH/bin/clang.
    # Let's stick to your version's compiler logic for now, which means 'orig' also uses LLVM clang.
    # If you want 'orig' to use GCC, this section needs adjustment.
    # Same compiler as the TSan builds (tools/tsan_compiler.sh: hardened prototype in
    # ~/dev/llvm-project-focs-lab unless LLVM_TSAN_ROOT is set; $LLVM_ROOT_PATH is only
    # honoured if it really is that tree).
    source "$(dirname "$0")/../../tools/tsan_compiler.sh" || exit 1
    TARGET_CC="$TSAN_CC"

elif [[ "$CONFIG_TYPE" == tsan* ]]; then
    IS_TSAN_BUILD=true
    # TSan builds MUST use the prototype clang (see the 'orig' branch for the selection rule).
    source "$(dirname "$0")/../../tools/tsan_compiler.sh" || exit 1
    TARGET_CC="$TSAN_CC"

    BASE_TSAN_FLAGS="$FLAGS_TSAN_COMMON_VAL $FLAGS_COMMON_BASE_VAL"
    COMBINED_EXTRA_FLAGS=""

    # Split the config type, e.g., "tsan-own-st" -> "tsan" "own" "st"
    IFS='-' read -r -a parts <<< "$CONFIG_TYPE"

    if [[ "${parts[0]}" != "tsan" ]]; then
        echo "Error: Invalid TSan configuration format. Must start with 'tsan'. Found: '$CONFIG_TYPE'"
        exit 1
    fi

    # If it's just "tsan", parts array will have one element "tsan". Loop for suffixes won't run.
    # parts[0] is "tsan". Iterate from parts[1] for suffixes.
    for i in $(seq 1 $((${#parts[@]} - 1))); do
        suffix="${parts[$i]}"
        if [ -z "$suffix" ]; then # Handles cases like "tsan-own-"
            echo "Error: Empty suffix component in TSan configuration '$CONFIG_TYPE'."
            exit 1
        fi

        # The key in CONFIG_DETAILS is like "tsan-own", "tsan-st"
        atomic_config_key="tsan-${suffix}"

        if [[ -v CONFIG_DETAILS["$atomic_config_key"] ]]; then
            detail_value="${CONFIG_DETAILS[$atomic_config_key]}"
            # Ensure we are not adding marker strings as flags
            if [[ "$detail_value" != "FLAGS_TSAN_BASE" ]] && \
               [[ "$detail_value" != "FLAGS_COMMON_BASE" ]]; then
                COMBINED_EXTRA_FLAGS+=" $detail_value"
            elif [[ "$atomic_config_key" == "tsan" && ${#parts[@]} -gt 1 ]]; then
                # This case handles if "tsan" itself (which has FLAGS_TSAN_BASE) is tried to be used as a combinable part
                # e.g. "tsan-tsan-own" - this is probably an error by user or misconfiguration
                echo "Warning: Atomic 'tsan' configuration used as a combinable part in '$CONFIG_TYPE'. This is unusual."
            fi
        else
            echo "Error: Unknown TSan option suffix '-$suffix' (derived from '$atomic_config_key') in '$CONFIG_TYPE'."
            echo "Please ensure 'tsan-$suffix' is defined in '$CONFIG_DEFINITIONS_FILE'."
            exit 1
        fi
    done
    FINAL_CFLAGS="$BASE_TSAN_FLAGS$COMBINED_EXTRA_FLAGS" # Note: COMBINED_EXTRA_FLAGS starts with a space if not empty

else
    echo "Error: Unknown config type '$CONFIG_TYPE'. Must be 'orig' or start with 'tsan'."
    print_available_configs
    exit 1
fi

# Remove leading/trailing/extra spaces
FINAL_CFLAGS=$(echo "$FINAL_CFLAGS" | xargs)

# Whole-program analysis summaries (hardened compiler: opt-in, read from <compile cwd>/tsan-logs/,
# here the FFmpeg build directory).  USE_SUMMARIES=1 requires $SUMMARIES_DIR/{st,lo,ea}_summary.txt.
USE_SUMMARIES="${USE_SUMMARIES:-0}"
SUMMARIES_DIR="${SUMMARIES_DIR:-$(pwd)/summaries}"
SUMMARY_NOTE="summaries: n/a"
if [ "$IS_TSAN_BUILD" = true ] && [ "$CONFIG_TYPE" != "tsan" ]; then
    SUMMARY_NOTE="summaries: none (per-TU analyses only)"
    if [ "$USE_SUMMARIES" = 1 ]; then
        for f in st lo ea; do
            [ -s "$SUMMARIES_DIR/${f}_summary.txt" ] || { echo "Error: USE_SUMMARIES=1 but $SUMMARIES_DIR/${f}_summary.txt is missing or empty"; exit 1; }
        done
        FINAL_CFLAGS="$FINAL_CFLAGS -mllvm -tsan-use-analysis-summaries"
        SUMMARY_NOTE="summaries: $SUMMARIES_DIR ($(for f in st lo ea; do printf '%s %s ' $f "$(md5sum "$SUMMARIES_DIR/${f}_summary.txt" | cut -c1-8)"; done))"
    fi
fi


# Directory for this specific build
BUILD_DIR_NAME="/dev/shm/ffmpeg-${CONFIG_TYPE}"
#BUILD_DIR_NAME="ffmpeg-build-${CONFIG_TYPE}"
RESULT_DIR_NAME="$(pwd)/ffmpeg-${CONFIG_TYPE}"


# Configuration script file name inside the build directory (as per your edit)
#CONFIG_SH_NAME="config_${CONFIG_TYPE}.sh"

echo "--- Preparing build for: $CONFIG_TYPE ---"
echo "Target build directory: $BUILD_DIR_NAME"
echo "Compiler: $TARGET_CC"
echo "Final CFLAGS: $FINAL_CFLAGS"
echo

# Clean up
if [ -d "$BUILD_DIR_NAME" ]; then
  echo "Removing existing directory: $BUILD_DIR_NAME"
  rm -rf "$BUILD_DIR_NAME"
fi
# An install prefix without build_info.txt predates this script version (paper-era, March 2026):
# keep it under old-builds/ (a symlink to /extra, ~1 GB per prefix) instead of overwriting it in place.
if [ -f "$RESULT_DIR_NAME/bin/ffmpeg" ] && [ ! -f "$RESULT_DIR_NAME/build_info.txt" ]; then
  OLD_STAMP=$(date -r "$RESULT_DIR_NAME/bin/ffmpeg" +%Y%m%d)
  mkdir -p old-builds
  echo "Archiving paper-era build $RESULT_DIR_NAME -> old-builds/ffmpeg-${CONFIG_TYPE}.$OLD_STAMP"
  rm -rf "old-builds/ffmpeg-${CONFIG_TYPE}.$OLD_STAMP"
  mv "$RESULT_DIR_NAME" "old-builds/ffmpeg-${CONFIG_TYPE}.$OLD_STAMP"
fi
mkdir -p "$BUILD_DIR_NAME"

echo "Extracting $FFMPEG_ARCHIVE into $BUILD_DIR_NAME..."
tar -xzf "$FFMPEG_ARCHIVE" -C "$BUILD_DIR_NAME" --strip-components=1
if [ $? -ne 0 ]; then
    echo "Error: Failed to extract $FFMPEG_ARCHIVE."
    exit 1
fi

# Provokes several errors...
#sed -i "s/check_cc\sintrinsics_neon\sarm_neon\.h/: ' check_cc intrinsics_neon arm_neon\.h/1" "$BUILD_DIR_NAME/configure"
#sed -i "s=check_type\s\"vdpau/vdpau\.h\"\s\"VdpPictureInfoVP9\"=check_type \"vdpau/vdpau\.h\" \"VdpPictureInfoVP9\" '=1" "$BUILD_DIR_NAME/configure"
ORIGPWD="$(pwd)"
source "$ORIGPWD/../../tools/write_build_info.sh"

if [ "$USE_SUMMARIES" = 1 ] && [ "$IS_TSAN_BUILD" = true ] && [ "$CONFIG_TYPE" != "tsan" ]; then
    # Read-only: the EA pass rewrites ea_summary.txt per module otherwise (the failed open is
    # non-fatal, so the whole-program file survives the build).
    mkdir -p "$BUILD_DIR_NAME/tsan-logs"
    cp "$SUMMARIES_DIR"/{st,lo,ea}_summary.txt "$BUILD_DIR_NAME/tsan-logs/"
    chmod 444 "$BUILD_DIR_NAME"/tsan-logs/*_summary.txt
fi


cd "$BUILD_DIR_NAME"


echo "--- Configuring FFmpeg ($CONFIG_TYPE) ---"

CC="$TARGET_CC"
CXX="$TSAN_CXX"

[ ! -x "$CC" -o ! -x "$CXX" ] && echo "No \$CC ($CC) or \$CXX ($CXX)!" && exit 4



./configure \
	--prefix="$RESULT_DIR_NAME" \
	--extra-libs="-lpthread -lm" \
	--cc="$CC" \
	--cxx="$CXX" \
	--extra-cflags="$FINAL_CFLAGS" \
	--extra-cxxflags="$FINAL_CFLAGS" \
	--extra-ldflags="$FINAL_CFLAGS" \
	--disable-doc \
	--enable-gpl \
	--enable-gnutls \
	--enable-libx264 \
	--enable-libx265 \
	--enable-debug=3 \
	--enable-shared \
	--disable-optimizations \
	--disable-stripping \
	|| BUILD_ERRORCODE="$?"

if [ -n "$BUILD_ERRORCODE" ]; then
    echo "Error: Configuration failed for $CONFIG_TYPE (errorcode $BUILD_ERRORCODE)."
    cd "$ORIGPWD"
    exit $BUILD_ERRORCODE
fi


echo "--- Building FFmpeg ($CONFIG_TYPE) ---"

NUM_JOBS=${NPROC:-$(($(nproc) * 7 / 8))}
echo "Using $NUM_JOBS jobs for make."

make -j${NUM_JOBS} 2> make.stderr.log || BUILD_ERRORCODE="$?"

if [ -n "$BUILD_ERRORCODE" ]; then
    echo "Error: 'make' failed for $CONFIG_TYPE (errorcode $BUILD_ERRORCODE)."
    cd "$ORIGPWD"
    exit $BUILD_ERRORCODE
fi

make install || BUILD_ERRORCODE="$?"

if [ -n "$BUILD_ERRORCODE" ]; then
    echo "Error: 'make install' failed for $CONFIG_TYPE (errorcode $BUILD_ERRORCODE)."
    cd "$ORIGPWD"
    exit $BUILD_ERRORCODE
fi

if [ "$USE_SUMMARIES" = 1 ] && [ "$IS_TSAN_BUILD" = true ] && [ "$CONFIG_TYPE" != "tsan" ]; then
    for f in st lo ea; do
        cmp -s "$SUMMARIES_DIR/${f}_summary.txt" "tsan-logs/${f}_summary.txt" || {
            echo "Error: tsan-logs/${f}_summary.txt was modified during the build of $CONFIG_TYPE"; cd "$ORIGPWD"; exit 1; }
    done
fi
# Provenance next to the installed binaries (cwd is still the build dir, so the tsan-logs
# listing refers to the summaries the compiler could see).
write_build_info "$RESULT_DIR_NAME" "$TARGET_CC" "$FINAL_CFLAGS" "config: $CONFIG_TYPE" "$SUMMARY_NOTE"


cd "$ORIGPWD"
echo "\$ORIGPWD: $ORIGPWD"


if [ ! -f "$RESULT_DIR_NAME/bin/ffmpeg" ]; then
    echo "Error: ffmpeg executable not found in $RESULT_DIR_NAME/bin/ffmpeg after 'make'."
    cd "$ORIGPWD"
    exit 2
fi


[ -d "$BUILD_DIR_NAME" ] && mv "$BUILD_DIR_NAME" "$RESULT_DIR_NAME/builddir"


echo "--- Build for $CONFIG_TYPE completed successfully ---"
echo "FFmpeg executable is at: $RESULT_DIR_NAME/bin/ffmpeg"

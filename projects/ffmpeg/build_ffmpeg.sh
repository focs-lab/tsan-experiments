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
    if [ -n "$LLVM_ROOT_PATH" ] && [ -x "$LLVM_ROOT_PATH/bin/clang" ]; then
        TARGET_CC="$LLVM_ROOT_PATH/bin/clang"
    elif command -v clang &> /dev/null; then
        TARGET_CC="clang"
        echo "INFO: LLVM_ROOT_PATH not set or clang not found there. Using system clang for 'orig'."
    else
        echo "Error: No suitable compiler (clang or gcc) found for 'orig' build."
        exit 1
    fi

elif [[ "$CONFIG_TYPE" == tsan* ]]; then
    IS_TSAN_BUILD=true
    # TSan builds MUST use clang
    if [ -n "$LLVM_ROOT_PATH" ] && [ -x "$LLVM_ROOT_PATH/bin/clang" ]; then
        TARGET_CC="$LLVM_ROOT_PATH/bin/clang"
    elif command -v clang &> /dev/null; then
        TARGET_CC="clang"
        echo "INFO: LLVM_ROOT_PATH not set or clang not found there. Using system clang for TSan build."
    else
        echo "Error: Clang compiler not found. Set LLVM_ROOT_PATH or ensure 'clang' is in PATH for TSan builds."
        exit 1
    fi

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


cd "$BUILD_DIR_NAME"


echo "--- Configuring FFmpeg ($CONFIG_TYPE) ---"

[ -z "$LLVM_ROOT_PATH" ] && echo "No \$LLVM_ROOT_PATH!" && exit 4

CC="$LLVM_ROOT_PATH/bin/clang"
CXX="$LLVM_ROOT_PATH/bin/clang++"

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

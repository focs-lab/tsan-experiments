#!/bin/bash

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configurable Variables ---
# Name of the memcached source archive. Ensure it's in the same directory as this script
# or provide the full/relative path to it.
MEMCACHED_ARCHIVE="memcached-1.6.29.tar.gz"

# Configuration definitions file
CONFIG_DEFINITIONS_FILE="config_definitions.sh"

# --- End of Configurable Variables ---

# Source the configuration definitions
if [ -f "$CONFIG_DEFINITIONS_FILE" ]; then
    # shellcheck source=config_definitions.sh
    source "$CONFIG_DEFINITIONS_FILE"
else
    echo "Error: Configuration definitions file '$CONFIG_DEFINITIONS_FILE' not found."
    echo "Please create it or ensure it's in the correct path."
    exit 1
fi

# Function to print available configuration types (now uses the sourced array)
print_available_configs() {
  echo "Available config types (defined in $CONFIG_DEFINITIONS_FILE):"
  for key in "${!CONFIG_DETAILS[@]}"; do
    echo "  - $key"
  done
}

# --- Main Script Logic ---
CONFIG_TYPE=$1

if [ -z "$CONFIG_TYPE" ]; then
  echo "Usage: ./build_memcached.sh <config_type>"
  print_available_configs
  exit 1
fi

# Check if the provided CONFIG_TYPE is valid
valid_config=false
for key in "${!CONFIG_DETAILS[@]}"; do
  if [[ "$key" == "$CONFIG_TYPE" ]]; then
    valid_config=true
    break
  fi
done

if ! $valid_config; then
  echo "Error: Unknown config type '$CONFIG_TYPE'"
  print_available_configs
  exit 1
fi


if [ ! -f "$MEMCACHED_ARCHIVE" ]; then
    echo "Error: Memcached archive '$MEMCACHED_ARCHIVE' not found."
    echo "Please place it in the current directory or update the MEMCACHED_ARCHIVE variable in the script."
    exit 1
fi


TARGET_CC="$LLVM_ROOT_PATH/bin/clang"
if [ ! -x "$TARGET_CC" ]; then
    echo "Error: Clang not found at $TARGET_CC. Check LLVM_ROOT_PATH."
    exit 1
fi

IS_TSAN_BUILD=false
[[ "$CONFIG_TYPE" == tsan* ]] && IS_TSAN_BUILD=true

# Form the flags
FLAGS_COMMON_BASE_VAL="-g -O2"
FLAGS_TSAN_COMMON_VAL="-fsanitize=thread" # Only the TSan flag, without -g -O2

CURRENT_CFLAGS=""
CURRENT_FLAGS_EXTRA=""

if $IS_TSAN_BUILD; then
    CURRENT_CFLAGS="$FLAGS_TSAN_COMMON_VAL $FLAGS_COMMON_BASE_VAL" # TSan flag + common flags
    # Additional TSan flags if they exist for this CONFIG_TYPE
    if [[ "${CONFIG_DETAILS[$CONFIG_TYPE]}" != "FLAGS_TSAN_BASE" ]] && \
       [[ "${CONFIG_DETAILS[$CONFIG_TYPE]}" != "FLAGS_COMMON_BASE" ]]; then # Avoid adding marker as a flag
        CURRENT_FLAGS_EXTRA="${CONFIG_DETAILS[$CONFIG_TYPE]}"
    fi
else # This is 'orig'
    CURRENT_CFLAGS="$FLAGS_COMMON_BASE_VAL"
fi

# Combine CFLAGS and EXTRA_FLAGS
FINAL_CFLAGS="$CURRENT_CFLAGS $CURRENT_FLAGS_EXTRA"
# Remove leading/trailing/extra spaces if CURRENT_FLAGS_EXTRA was empty
FINAL_CFLAGS=$(echo "$FINAL_CFLAGS" | xargs)


# Directory for this specific build
BUILD_DIR_NAME="memcached-${CONFIG_TYPE}"
# Configuration script file name inside the build directory
CONFIG_SH_NAME="config_${CONFIG_TYPE}.sh"

echo "--- Preparing build for: $CONFIG_TYPE ---"
echo "Target build directory: $BUILD_DIR_NAME"
echo "Compiler: $TARGET_CC"
echo "Final CFLAGS: $FINAL_CFLAGS"

# Clean up previous build directory and create a new one
if [ -d "$BUILD_DIR_NAME" ]; then
  echo "Removing existing directory: $BUILD_DIR_NAME"
  rm -rf "$BUILD_DIR_NAME"
fi
mkdir -p "$BUILD_DIR_NAME"

echo "Extracting $MEMCACHED_ARCHIVE into $BUILD_DIR_NAME..."
tar -xzf "$MEMCACHED_ARCHIVE" -C "$BUILD_DIR_NAME" --strip-components=1
if [ $? -ne 0 ]; then
    echo "Error: Failed to extract $MEMCACHED_ARCHIVE."
    echo "Make sure it's a valid tar.gz file and contains a single top-level directory (like memcached-X.Y.Z/)"
    exit 1
fi

# Change to the build directory
cd "$BUILD_DIR_NAME"

# Create config_build.sh inside the build directory
echo "Creating $CONFIG_SH_NAME..."
cat <<EOF > "$CONFIG_SH_NAME"
#!/bin/bash
set -e
export FLAGS="$FINAL_CFLAGS"
export CFLAGS="\$FLAGS"
export CXXFLAGS="\$FLAGS"
export CPPFLAGS="\$FLAGS"
export CC="$TARGET_CC"

echo "Running ./configure with:"
echo "  CC=\$CC"
echo "  CFLAGS=\$CFLAGS"
./configure --prefix=\`pwd\`
EOF
chmod +x "$CONFIG_SH_NAME"

echo "--- Configuring Memcached ($CONFIG_TYPE) ---"
if ! "./$CONFIG_SH_NAME"; then
    echo "Error: Configuration script $CONFIG_SH_NAME failed for $CONFIG_TYPE."
    cd .. # Return from the build directory
    exit 1
fi

echo "--- Building Memcached ($CONFIG_TYPE) ---"
NUM_JOBS=${NPROC:-$(nproc)}
echo "Using $NUM_JOBS jobs for make."
if ! make -j$NUM_JOBS; then
    echo "Error: 'make' failed for $CONFIG_TYPE."
    cd .. # Return from the build directory
    exit 1
fi

if [ ! -f "memcached" ]; then
    echo "Error: memcached executable not found in $(pwd) after 'make'."
    cd .. # Return from the build directory
    exit 1
fi

cd .. # Return to the original directory
echo "--- Build for $CONFIG_TYPE completed successfully ---"
echo "Memcached executable is at: $BUILD_DIR_NAME/memcached"
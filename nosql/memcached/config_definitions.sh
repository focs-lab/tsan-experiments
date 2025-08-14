# config_definitions.sh

# This file defines the available memcached build configurations and their specific compiler flags.
# It is intended to be sourced by other scripts.

# List of available configuration types.
# Key is the configuration name, value is additional -mllvm flags (if any).
# For 'orig' and 'tsan' (basic TSan), the value is a special marker.
declare -A CONFIG_DETAILS
CONFIG_DETAILS["orig"]="FLAGS_COMMON_BASE" # Special marker for regular flags
CONFIG_DETAILS["tsan"]="FLAGS_TSAN_BASE"  # Special marker for basic TSan flags
CONFIG_DETAILS["tsan-lo"]="-mllvm -tsan-use-lock-ownership"
#CONFIG_DETAILS["tsan-loub"]="-mllvm -tsan-use-lock-ownership-upperbound"
CONFIG_DETAILS["tsan-st"]="-mllvm -tsan-use-single-threaded"
CONFIG_DETAILS["tsan-swmr"]="-mllvm -tsan-use-swmr"
CONFIG_DETAILS["tsan-ea"]="-mllvm -tsan-use-escape-analysis-global"
CONFIG_DETAILS["tsan-dom"]="-mllvm -tsan-use-dominance-analysis"
CONFIG_DETAILS["tsan-all"]="-mllvm -tsan-use-dominance-analysis \
                            -mllvm -tsan-use-lock-ownership \
                            -mllvm -tsan-use-single-threaded \
                            -mllvm -tsan-use-swmr \
                            -mllvm -tsan-use-escape-analysis-global"

# You can add more configurations here following the same pattern.
# Example:
# CONFIG_DETAILS["tsan-new-opt"]="-mllvm -tsan-new-optimization-flag"
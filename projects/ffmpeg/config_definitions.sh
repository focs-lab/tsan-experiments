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
CONFIG_DETAILS["tsan-loub"]="-mllvm -tsan-use-lock-ownership-upperbound"
CONFIG_DETAILS["tsan-st"]="-mllvm -tsan-use-single-threaded"
CONFIG_DETAILS["tsan-stmt"]="-mllvm -tsan-use-active-thread-count"
CONFIG_DETAILS["tsan-swmr"]="-mllvm -tsan-use-swmr"
CONFIG_DETAILS["tsan-ea"]="-mllvm -tsan-use-escape-analysis-global"
CONFIG_DETAILS["tsan-dom"]="-mllvm -tsan-use-dominance-analysis"
CONFIG_DETAILS["tsan-dom_peeling"]="-mllvm -tsan-use-dominance-analysis -mllvm -tsan-use-loop-peeling=true"

# Rebuttal (plan P2/P3): the four sound analyses only (EA+LO+STC+SWMR), i.e. AllOpt without
# dominance elimination.  Same name in every app so that results are comparable.
CONFIG_DETAILS["tsan-sound"]="-mllvm -tsan-use-escape-analysis-global \
                              -mllvm -tsan-use-lock-ownership \
                              -mllvm -tsan-use-single-threaded \
                              -mllvm -tsan-use-swmr"

# You can add more configurations here following the same pattern.
# Example:
# CONFIG_DETAILS["tsan-new-opt"]="-mllvm -tsan-new-optimization-flag"
# tsan-yoff: turn the yield copy's seven changes off inside the same compiler
# (/extra/alexey/builds/tsan-yield-d98873cda906, where all six switches default to on). A "-yoff" row is the
# A/B partner of the same configuration without the suffix: same compiler, same binary layout, only the yield
# changes differ, so the pair isolates them from the stage-b2 changes underneath.
CONFIG_DETAILS["tsan-yoff"]="-mllvm -tsan-dynstc-runs-across-thread-free-calls=false \
                             -mllvm -tsan-de-atomics-by-ordering=false \
                             -mllvm -tsan-de-cover-containment=false \
                             -mllvm -tsan-swmr-readonly-call-args=false \
                             -mllvm -tsan-ea-later-escape-uses-summaries=false \
                             -mllvm -tsan-intercepted-call-table=false"

#!/bin/bash
# gen_args_gn.sh <cfg> <clang_base_path> [out_dir] — args.gn for out/chrome-<cfg> from config_definitions.sh.
# The TSan -mllvm flags are composed like the other build scripts (split the name on '-', look up tsan-<token>);
# orig -> is_tsan=false. Prints the file; writes it when out_dir is given.
set -euo pipefail
CFG=${1:?cfg}; CLANG=${2:?clang_base_path}; OUT=${3:-}
source "$(dirname "$0")/../config_definitions.sh"
if [ "$CFG" = orig ]; then IS_TSAN=false; FLAGS=""; else
  IS_TSAN=true; FLAGS=""
  if [ "$CFG" != tsan ]; then
    IFS='-' read -r -a parts <<< "$CFG"
    for i in $(seq 1 $((${#parts[@]} - 1))); do k="tsan-${parts[$i]}"
      [[ -v CONFIG_DETAILS["$k"] ]] || { echo "unknown token '${parts[$i]}' in $CFG" >&2; exit 1; }
      FLAGS="$FLAGS ${CONFIG_DETAILS[$k]}"; done
  fi
fi
# "-mllvm -x -mllvm -y" -> GN list
LIST=$(for w in $FLAGS; do printf '"%s", ' "$w"; done); LIST="[ ${LIST%, } ]"; [ "$FLAGS" ] || LIST="[]"
ARGS="is_tsan = $IS_TSAN
tsan_extra_cflags = $LIST
clang_base_path = \"$CLANG\"
clang_use_chrome_plugins = false
treat_warnings_as_errors = false
is_component_build = true
enable_nacl = false
is_debug = false
symbol_level = 2"
if [ -n "$OUT" ]; then mkdir -p "$OUT"; printf '%s\n' "$ARGS" > "$OUT/args.gn"; fi
printf '%s\n' "$ARGS"

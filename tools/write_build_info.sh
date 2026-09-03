#!/bin/bash
# write_build_info.sh — record how a binary was built, next to it.
#
# Usage (source it, then call):
#   source "$(dirname "$0")/../../tools/write_build_info.sh"
#   write_build_info <out_dir> <compiler> "<flags>" ["extra line" ...]
#
# Writes <out_dir>/build_info.txt with the compiler path + version, the git
# branch/HEAD/dirty state of the compiler's source tree (derived from the path
# <tree>/llvm/build/bin/clang), the flags, the working directory and the
# summary files present in $PWD/tsan-logs (the hardened compiler's summary
# location).  run_preservation.py copies this file into its manifest.
write_build_info() {
  local out_dir="$1" cc="$2" flags="$3"; shift 3
  mkdir -p "$out_dir"
  local ccpath; ccpath=$(readlink -f "$cc" 2>/dev/null || echo "$cc")
  # Source tree of the compiler: walk up from the (resolved) binary until a .git is found
  # (llvm/build may be a symlink to another build dir, so do not rely on the path shape).
  local tree; tree=$(dirname "$ccpath")
  while [ "$tree" != "/" ] && [ ! -e "$tree/.git" ]; do tree=$(dirname "$tree"); done
  {
    echo "date: $(date -Iseconds)"
    echo "host: $(hostname)"
    echo "compiler: $ccpath"
    echo "compiler_version: $("$cc" --version 2>/dev/null | head -1)"
    echo "compiler_mtime: $(date -Iseconds -r "$ccpath" 2>/dev/null)"
    if [ -d "$tree/.git" ]; then
      echo "compiler_tree: $tree"
      echo "compiler_branch: $(git -C "$tree" branch --show-current 2>/dev/null)"
      echo "compiler_head: $(git -C "$tree" rev-parse HEAD 2>/dev/null)"
      echo "compiler_dirty_files: $(git -C "$tree" status --porcelain --untracked-files=no 2>/dev/null | wc -l)"
    fi
    echo "flags: $flags"
    echo "cwd: $PWD"
    if [ -d "$PWD/tsan-logs" ]; then
      echo "tsan-logs: $(ls -l "$PWD/tsan-logs" 2>/dev/null | tail -n +2 | awk '{print $1, $5, $9}' | tr '\n' ';')"
    else
      echo "tsan-logs: <none>"
    fi
    for line in "$@"; do echo "$line"; done
  } > "$out_dir/build_info.txt"
}

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
    local root; root=$(dirname "$(dirname "$ccpath")")
    if [ -f "$root/TSAN_AUDIT_HASH" ]; then
      # frozen per-hash copy (/extra/alexey/builds/<lane>-<hash>/): no git tree, the stamp files are the provenance
      echo "compiler_tree: $root (frozen copy)"
      echo "compiler_head: $(head -1 "$root/TSAN_AUDIT_HASH" | grep -oE '[0-9a-f]{12,40}' | head -1)"
      [ -f "$root/CONSOLIDATED_HASH" ] && echo "compiler_consolidated: $(head -1 "$root/CONSOLIDATED_HASH")"
    elif [ -d "$tree/.git" ]; then
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

# build_stamp_of <dir>: 12-hex compiler stamp recorded in <dir>/build_info.txt ("" if none / paper-era).
build_stamp_of() {
  [ -f "$1/build_info.txt" ] && grep -m1 "^compiler_version:" "$1/build_info.txt" | grep -oE '[0-9a-f]{40}' | cut -c1-12
}

# retire_build_dir <dir> <old_builds_dir> <name> <current_stamp>: move an existing build out of the way
# before rebuilding — archived as <old_builds_dir>/<name>.<stamp|date> when it was built by another
# compiler (or is paper-era, no build_info.txt), deleted when it carries the current stamp (same content).
retire_build_dir() {
  local dir="$1" old="$2" name="$3" cur="$4" stamp
  [ -e "$dir" ] || return 0
  stamp=$(build_stamp_of "$dir")
  if [ -n "$stamp" ] && [ "$stamp" = "$cur" ]; then
    echo "Removing previous build of the same compiler ($stamp): $dir"; rm -rf "$dir"; return 0
  fi
  [ -n "$stamp" ] || stamp=$(date -r "$dir" +%Y%m%d)
  mkdir -p "$old"; rm -rf "$old/$name.$stamp"
  echo "Archiving previous build $dir -> $old/$name.$stamp"; mv "$dir" "$old/$name.$stamp"
}

# compiler_stamp_of <clang>: the 12-hex stamp of a compiler binary's version string.
compiler_stamp_of() { "$1" --version 2>/dev/null | head -1 | grep -oE '[0-9a-f]{40}' | cut -c1-12; }

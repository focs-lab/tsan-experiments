#!/bin/bash
# probe.sh — how many stores the Dominance Elimination leaves in each function of de_probe.c.
# Usage: ./probe.sh [clang ...]   (default: the three compilers compared in README.md)
# Each function has two stores; a sound DE must keep both in every function except f_same
# (same location, no sync in between) and f_lock (lock acquisition cannot release the store).
set -euo pipefail
cd "$(dirname "$0")"
CLANGS=("$@")
[ ${#CLANGS[@]} -gt 0 ] || CLANGS=(/extra/alexey/llvm-project-paper/llvm/build/bin/clang
                                   /extra/alexey/llvm-project-paper-mustalias/llvm/build/bin/clang
                                   /home/alexey/dev/llvm-project-focs-lab/llvm/build/bin/clang)
for C in "${CLANGS[@]}"; do
  echo "== $C ($("$C" --version | head -1 | sed 's/.*(//;s/)//' | cut -c1-60))"
  "$C" -O1 -fsanitize=thread -mllvm -tsan-use-dominance-analysis-dom -S -o - de_probe.c 2>/dev/null \
    | awk '/^f_[a-z]+:/{f=$1} /call.*__tsan_write4/{c[f]++} END{for(k in c) printf "  %-9s %d\n", k, c[k]}' | sort
done

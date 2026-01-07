#!/usr/bin/env bash
set -euo pipefail

# === CONFIGURATION ===
# Check for environment variables to set LLVM_BUILD
DEFAULT_LLVM_ROOT="$HOME/dev/llvm-project-tsan"
BUILD_DIR="cmake-build-for-test"

# Use N% of CPUs for builds (default: 75)
CPU_PERCENT="${CPU_PERCENT:-50}"

C_COMPILER="/usr/bin/clang"
CXX_COMPILER="/usr/bin/clang++"

LLVM_ROOT="${LLVM_TSAN_SOURCE:+$LLVM_TSAN_SOURCE}"
LLVM_ROOT="${LLVM_ROOT:-$DEFAULT_LLVM_ROOT}"
LLVM_BUILD="$LLVM_ROOT/llvm/$BUILD_DIR"

[[ ! -d "$LLVM_BUILD" ]] && mkdir -p "$LLVM_BUILD"
echo "LLVM Build directory: $LLVM_BUILD"
LLVM_TEST_DIR="$LLVM_ROOT/llvm/test/Instrumentation/ThreadSanitizer"

C_COMPILER="/usr/bin/clang"
CXX_COMPILER="/usr/bin/clang++"

if [[ ! -x "${C_COMPILER}" || ! -x "${CXX_COMPILER}" ]]; then
  echo "❌ clang/clang++ compiler not executable" >&2
  exit 1
fi

# Prefer llvm-lit from the current build if present
resolve_lit_bin() {
  local lit="$LLVM_BUILD/bin/llvm-lit"
  if [[ -x "$lit" ]]; then
    echo "$lit"
    return 0
  fi
  lit="$(command -v llvm-lit || true)"
  if [[ -n "$lit" && -x "$lit" ]]; then
    echo "$lit"
    return 0
  fi
  return 1
}

_total_cpus() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  else
    getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
  fi
}

jobs() {
  local total pct j
  total="$(_total_cpus)"
  pct="${CPU_PERCENT}"

  if ! [[ "$pct" =~ ^[0-9]+$ ]]; then
    pct=75
  fi
  if (( pct < 1 )); then pct=1; fi
  if (( pct > 100 )); then pct=100; fi

  j=$(( (total * pct + 99) / 100 ))
  if (( j < 1 )); then j=1; fi
  echo "$j"
}

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

RUN_CHECK_ALL=false
SKIP_GIT=false

# Parse arguments (robust)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-all)
      RUN_CHECK_ALL=true
      shift
      ;;
    --skip-git)
      SKIP_GIT=true
      shift
      ;;
    -*)
      echo "❌ Unknown option: $1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

# === FUNCTIONS ===

# Track & restore the original git state so the script doesn't leave the repo detached.
START_PWD="$(pwd)"
GIT_STATE_CHANGED=false
START_GIT_COMMIT=""
START_GIT_BRANCH=""
START_GIT_DETACHED=false

snapshot_git_state() {
  cd "$LLVM_ROOT" 2>/dev/null || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  START_GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"
  START_GIT_BRANCH="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [[ -z "$START_GIT_BRANCH" ]]; then
    START_GIT_DETACHED=true
  fi
}

ensure_clean_worktree_or_exit() {
  # User-requested behavior: if there are any uncommitted changes, abort immediately.
  cd "$LLVM_ROOT" 2>/dev/null || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  if ! git diff --quiet --ignore-submodules -- 2>/dev/null || ! git diff --quiet --ignore-submodules --cached -- 2>/dev/null; then
    echo -e "${RED}❌ Uncommitted changes detected in $LLVM_ROOT; aborting.${NC}" >&2
    echo "   Please commit/stash changes (or run the script in a clean worktree) and retry." >&2
    exit 1
  fi
}

restore_git_state() {
  # Always try to restore the original branch/commit, but only if we changed it.
  # Never hard-reset or stash automatically.
  local exit_code=$?

  cd "$START_PWD" 2>/dev/null || true

  if [[ "$GIT_STATE_CHANGED" != "true" ]]; then
    return "$exit_code"
  fi

  cd "$LLVM_ROOT" 2>/dev/null || return "$exit_code"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return "$exit_code"

  # If the working tree is dirty, don't risk surprising behavior; still attempt a switch.
  if ! git diff --quiet --ignore-submodules -- 2>/dev/null || ! git diff --quiet --ignore-submodules --cached -- 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Working tree has uncommitted changes; restoring branch/commit without cleaning.${NC}" >&2
  fi

  if [[ "$START_GIT_DETACHED" == "true" ]]; then
    if [[ -n "$START_GIT_COMMIT" ]]; then
      git switch --detach "$START_GIT_COMMIT" >/dev/null 2>&1 || true
    fi
  else
    if [[ -n "$START_GIT_BRANCH" ]]; then
      git switch "$START_GIT_BRANCH" >/dev/null 2>&1 || true
    fi
  fi

  cd "$START_PWD" 2>/dev/null || true
  return "$exit_code"
}

snapshot_git_state

# Before we start switching branches, require a clean worktree.
if [[ "$SKIP_GIT" = false ]]; then
  ensure_clean_worktree_or_exit
fi

trap restore_git_state EXIT INT TERM

configure_if_needed() {
  if [[ -x ./cmake.sh ]]; then
    echo "⚙️  Using local cmake.sh"
    ./cmake.sh
  else
    echo "⚙️  Configuring build directory manually..."
    cmake .. -G Ninja \
      -DCMAKE_C_COMPILER="$C_COMPILER" \
      -DCMAKE_CXX_COMPILER="$CXX_COMPILER" \
      -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld -Wl,--gdb-index" \
      -DCMAKE_BUILD_TYPE=Debug \
      -DBUILD_SHARED_LIBS=ON \
      -DLLVM_TARGETS_TO_BUILD=X86 \
      -DLLVM_ENABLE_PROJECTS="clang;compiler-rt" \
      -DLLVM_ENABLE_ASSERTIONS=ON \
      -DLLVM_OPTIMIZED_TABLEGEN=ON \
      -DLLVM_USE_LINKER=lld \
      -DLLVM_USE_SPLIT_DWARF=ON \
      -DCMAKE_LINKER=lld \
      -DLLVM_PARALLEL_LINK_JOBS=4 \
      -DLLVM_INCLUDE_TESTS=ON
  fi
}

parse_lit_summary() {
  local logfile=$1
  grep -E 'Total Discovered Tests|Passed|Unsupported|Failed|Expectedly Failed' "$logfile" || true
}

run_branch_tests() {
  local branch=$1
  local testfile=$2
  local target=$3
  local LOG_DIR="$(pwd)"

  echo "=============================="
  echo "🧩 Testing branch: $branch"
  echo "=============================="

  cd "$LLVM_ROOT"
  if [ "$SKIP_GIT" = false ]; then
    # Guard in case the build system generated/modified files in the worktree.
    ensure_clean_worktree_or_exit

    git fetch --prune origin
    git switch --detach "origin/$branch"
    GIT_STATE_CHANGED=true
  else
    echo "⏩ Skipping git fetch (using local repository)"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      git switch "$branch"
      GIT_STATE_CHANGED=true
    else
      echo "❌ Branch not found locally: $branch" >&2
      return 1
    fi
  fi

  echo "⚙️  Building LLVM ($branch)..."
  cd "$LLVM_BUILD"
  local BUILD_LOG="$LOG_DIR/${branch}-build.log"
  {
    configure_if_needed
    echo cmake --build . -j"$(jobs)"
    cmake --build . -j"$(jobs)"
  } &>"$BUILD_LOG" || {
    echo -e "${RED}❌ Build failed for $branch${NC}"
    echo "  See log: $BUILD_LOG"
    return 1
  }
  echo -e "${GREEN}✅ Build completed for $branch${NC}"

  if [[ -n "$testfile" ]]; then
    echo "🧪 Running local .ll test: $testfile"
    cd "$LLVM_TEST_DIR"
    local LIT_BIN
    if ! LIT_BIN="$(resolve_lit_bin)"; then
      echo "❌ llvm-lit not found (expected at $LLVM_BUILD/bin/llvm-lit or in PATH)" >&2
      return 1
    fi
    local LIT_LOG="$LOG_DIR/${branch}-lit.log"
    if "$LIT_BIN" -v "$testfile" &>"$LIT_LOG"; then
      echo -e "${GREEN}✅ .ll test passed${NC}"
    else
      echo -e "${RED}❌ .ll test failed${NC}"
    fi
    parse_lit_summary "$LIT_LOG"
  else
    echo "🧪 Skipping local .ll test (no test file specified)"
  fi

  echo "🏗  Running full check target: $target"
  cd "$LLVM_BUILD"
  local CHECK_LOG="$LOG_DIR/${branch}-check.log"
  echo cmake --build . --target "$target" -j"$(jobs)"
  if cmake --build . --target "$target" -j"$(jobs)" &>"$CHECK_LOG"; then
    echo -e "${GREEN}✅ Check target succeeded${NC}"
  else
    echo -e "${YELLOW}⚠️  Check target finished with errors${NC}"
  fi
  parse_lit_summary "$CHECK_LOG"

  if [ "$RUN_CHECK_ALL" = true ]; then
    echo "🏗  Running check-all target..."
    local CHECK_ALL_LOG="$LOG_DIR/${branch}-check-all.log"
    echo cmake --build . --target check-all -j"$(jobs)"
    if cmake --build . --target check-all -j"$(jobs)" &>"$CHECK_ALL_LOG"; then
      echo -e "${GREEN}✅ check-all succeeded${NC}"
    else
      echo -e "${YELLOW}⚠️  check-all finished with errors${NC}"
    fi
    parse_lit_summary "$CHECK_ALL_LOG"
  fi

  echo
}

# === MAIN ===

start_time=$(date +%s)

run_branch_tests "tsan-dominance-based" "dominance-elimination.ll" "check-tsan-dominance-analysis"
run_branch_tests "tsan-escape-analysis" "escape-analysis.ll" "check-tsan-escape-analysis"
run_branch_tests "main" "" "check-tsan"

end_time=$(date +%s)
runtime=$((end_time - start_time))

echo "===================================="
echo "🎯 All tests finished in ${runtime}s"
echo "Logs are saved in the current directory with the pattern:"
echo "  <branch>-build.log"
echo "  <branch>-lit.log (if a test file was specified)"
echo "  <branch>-check.log"
echo "  <branch>-check-all.log (if --check-all was used)"
echo "===================================="

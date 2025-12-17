#!/usr/bin/env bash
set -euo pipefail

# === CONFIGURATION ===
# Check for environment variables to set LLVM_BUILD
if [[ -n "${LLVM_PATH:-}" ]]; then
    LLVM_BUILD="$LLVM_PATH"
elif [[ -n "${LLVM_HOME:-}" ]]; then
    LLVM_BUILD="$LLVM_HOME"
elif [[ -n "${LLVM_ROOT_PATH:-}" ]]; then
    LLVM_BUILD="$LLVM_ROOT_PATH"
elif [[ -n "${LLVM_ROOT:-}" ]]; then
    LLVM_BUILD="$LLVM_ROOT"
else
    LLVM_BUILD="$HOME/dev/llvm-project-tsan/llvm/build"
fi

LLVM_ROOT=$(cd "$LLVM_BUILD/../.." && pwd)  # derive project root from build dir
LLVM_TEST_DIR="$LLVM_ROOT/llvm/test/Instrumentation/ThreadSanitizer"

C_COMPILER="/usr/bin/clang"
CXX_COMPILER="/usr/bin/clang++"

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

RUN_CHECK_ALL=false
SKIP_GIT=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --check-all)
        RUN_CHECK_ALL=true
        shift
        ;;
        --skip-git)
        SKIP_GIT=true
        shift
        ;;
    esac
done

# === FUNCTIONS ===

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
          -DLLVM_ENABLE_PROJECTS="clang;lld;compiler-rt" \
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
    local LOG_DIR=$(pwd)

    echo "=============================="
    echo "🧩 Testing branch: $branch"
    echo "=============================="

    cd "$LLVM_ROOT"
    if [ "$SKIP_GIT" = false ]; then
        git fetch origin
        git checkout "origin/$branch"
    else
        echo "⏩ Skipping git fetch (using local repository)"
        git checkout "$branch"
    fi

    echo "⚙️  Building LLVM ($branch)..."
    cd "$LLVM_BUILD"
    BUILD_LOG="$LOG_DIR/${branch}-build.log"
    {
        configure_if_needed
        cmake --build . -j"$(nproc)"
    } &> "$BUILD_LOG" || {
        echo -e "${RED}❌ Build failed for $branch${NC}"
        echo "  See log: $BUILD_LOG"
        return 1
    }
    echo -e "${GREEN}✅ Build completed for $branch${NC}"

    if [[ -n "$testfile" ]]; then
        echo "🧪 Running local .ll test: $testfile"
        cd "$LLVM_TEST_DIR"
        LIT_LOG="$LOG_DIR/${branch}-lit.log"
        if llvm-lit -v "$testfile" &> "$LIT_LOG"; then
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
    CHECK_LOG="$LOG_DIR/${branch}-check.log"
    if cmake --build . --target "$target" -j"$(nproc)" &> "$CHECK_LOG"; then
        echo -e "${GREEN}✅ Check target succeeded${NC}"
    else
        echo -e "${YELLOW}⚠️  Check target finished with errors${NC}"
    fi
    parse_lit_summary "$CHECK_LOG"

    if [ "$RUN_CHECK_ALL" = true ]; then
        echo "🏗  Running check-all target..."
        CHECK_ALL_LOG="$LOG_DIR/${branch}-check-all.log"
        if cmake --build . --target check-all -j"$(nproc)" &> "$CHECK_ALL_LOG"; then
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
run_branch_tests "tsan-escape-analysis"  "escape-analysis.ll"      "check-tsan-escape-analysis"
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

PREFIX=`pwd`-install

FLAGS_COMMON="-fsanitize=thread -g -O2"
FLAGS_EXTRA="-mllvm -tsan-use-escape-analysis-global -mllvm -tsan-use-single-threaded"

export CFLAGS="$FLAGS_COMMON $FLAGS_EXTRA"
export CXXFLAGS="$FLAGS_COMMON $FLAGS_EXTRA"
export CPPFLAGS="$FLAGS_COMMON $FLAGS_EXTRA"
export CC="$LLVM_ROOT_PATH/bin/clang"

./configure --prefix=$PREFIX

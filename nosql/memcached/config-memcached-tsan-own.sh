PREFIX=`pwd`-install

FLAGS_COMMON="-fsanitize=thread -g -O2"
FLAGS_EXTRA="-mllvm -tsan-use-lock-ownership"

export CFLAGS="$FLAGS_COMMON $FLAGS_EXTRA"
export CXXFLAGS="$FLAGS_COMMON $FLAGS_EXTRA"
export CPPFLAGS="$FLAGS_COMMON $FLAGS_EXTRA"
export CC="$LLVM_ROOT_PATH/bin/clang"

./configure --prefix=$PREFIX

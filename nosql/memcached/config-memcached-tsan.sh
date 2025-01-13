PREFIX=`pwd`-install
FLAGS="-fsanitize=thread \
       -mllvm -stats -mllvm -debug-only=tsan-ea -g"
export CFLAGS="$FLAGS"
export CXXFLAGS="$FLAGS"
export CPPFLAGS="$FLAGS"
export CC=clang

./configure --prefix=$PREFIX

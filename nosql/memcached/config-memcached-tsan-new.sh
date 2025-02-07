PREFIX=`pwd`-install
FLAGS="-fsanitize=thread -mllvm -tsan-use-escape-analysis-global \
       -mllvm -debug-only=tsan-ea -mllvm -stats -mllvm -debug-only=tsan-ea -g"
export CFLAGS="$FLAGS"
export CXXFLAGS="$FLAGS"
export CPPFLAGS="$FLAGS"
export CC=clang

./configure --prefix=$PREFIX

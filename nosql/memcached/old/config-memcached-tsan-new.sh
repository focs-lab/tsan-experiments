PREFIX=`pwd`-install
FLAGS="-fsanitize=thread -mllvm -tsan-use-escape-analysis-global \
       -mllvm -stats -g -O2"
export CFLAGS="$FLAGS"
export CXXFLAGS="$FLAGS"
export CPPFLAGS="$FLAGS"
export CC=clang
#       -mllvm -debug-only=tsan-ea -mllvm -stats -mllvm -debug-only=tsan-ea -g"

./configure --prefix=$PREFIX

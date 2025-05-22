PREFIX=`pwd`-install
FLAGS="-fsanitize=thread \
       -mllvm -stats -g -O2"
export CFLAGS="$FLAGS"
export CXXFLAGS="$FLAGS"
export CPPFLAGS="$FLAGS"
export CC=clang

./configure --prefix=$PREFIX

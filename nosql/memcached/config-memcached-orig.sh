PREFIX=`pwd`-install
FLAGS="-g -O2"
export CFLAGS="$FLAGS"
export CXXFLAGS="$FLAGS"
export CPPFLAGS="$FLAGS"

./configure --prefix=$PREFIX

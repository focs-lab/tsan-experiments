PREFIX=`pwd`-install
FLAGS="-fsanitize=thread -mllvm -tsan-use-dominance-analysis \
       -mllvm -stats -g -O2"
export CFLAGS="$FLAGS"
export CXXFLAGS="$FLAGS"
export CPPFLAGS="$FLAGS"
export CC=clang
# FLAGS="-fsanitize=thread -mllvm -tsan-use-escape-analysis-global \
#        -mllvm -debug-only=tsan-ea -mllvm -stats -mllvm -debug-only=tsan-ea,ea-escaping-callees -g -O2"

./configure --prefix=$PREFIX

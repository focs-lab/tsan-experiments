opt -S -disable-output -passes='print<lock-ownership>' -debug-only=lock-ownership memcached.ll 2>&1
opt -S -disable-output -passes='print<single-threaded>' -debug-only=single-threaded memcached.ll 2>&1
opt -S -disable-output -passes='print<escape-analysis-global>' -debug-only=ea-escaping-callees memcached.ll 2>&1
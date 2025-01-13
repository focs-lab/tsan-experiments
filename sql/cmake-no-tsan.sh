cmake -S . -B build-no-tsan \
      -DCMAKE_INSTALL_PREFIX=dist-no-tsan \
      -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_C_FLAGS="-O0 -g" -DCMAKE_CXX_FLAGS="-O0 -g" \
      -DDOWNLOAD_BOOST=1 -DWITH_BOOST=downloads \
      -DWITH_UNIT_TESTS=OFF -DINSTALL_MYSQLTESTDIR=

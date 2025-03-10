cmake -S . -B build-tsan-new \
      -DCMAKE_INSTALL_PREFIX=dist-tsan-new \
      -DWITH_TSAN=ON \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_C_FLAGS="-O0 -g" \
      -DCMAKE_CXX_FLAGS="-O0 -g" \
      -DDOWNLOAD_BOOST=1 \
      -DWITH_BOOST=downloads \
      -DWITH_UNIT_TESTS=OFF \
      -DINSTALL_MYSQLTESTDIR=

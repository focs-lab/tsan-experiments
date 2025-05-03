source cmake-export-main-vars.sh "orig" || exit $?

mkdir -p "$BUILD_DIR"

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
      -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_C_FLAGS="-O0 -g" \
      -DCMAKE_CXX_FLAGS="-O0 -g" \
      -DDOWNLOAD_BOOST=1 -DWITH_BOOST=downloads \
      -DWITH_UNIT_TESTS=OFF -DINSTALL_MYSQLTESTDIR=

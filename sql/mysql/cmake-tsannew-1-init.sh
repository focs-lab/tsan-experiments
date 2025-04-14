source cmake-export-main-vars.sh "tsannew"

mkdir -p "$BUILD_DIR"

[ -z "$FLAGS_TSAN" ] && FLAGS_TSAN="-mllvm -tsan-use-escape-analysis-global"
#[ -z "$FLAGS_TSAN" ] && FLAGS_TSAN="-fsanitize=thread"	# Implements automatically in "-DWITH_TSAN".


# Original CMake line: https://hackmd.io/@tsaninternals/Hy9L3J8KA/%2FXx9CdNCUSC6YokIXumJcwA#MySQL

cmake -S . -B build-tsan-new \
      -DCMAKE_INSTALL_PREFIX=dist-tsannew \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_C_FLAGS="-O0 -g $FLAGS_TSAN" \
      -DCMAKE_CXX_FLAGS="-O0 -g $FLAGS_TSAN" \
      -DDOWNLOAD_BOOST=1 \
      -DWITH_BOOST=downloads \
      -DWITH_UNIT_TESTS=OFF \
      -DINSTALL_MYSQLTESTDIR= \
      -DWITH_TSAN=ON \

cmake -S . -B "$BUILD_DIR" \
      -DCMAKE_INSTALL_PREFIX=dist-tsannew \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_C_FLAGS="-O0 -g $FLAGS_TSAN" \
      -DCMAKE_CXX_FLAGS="-O0 -g $FLAGS_TSAN" \
      -DDOWNLOAD_BOOST=1 \
      -DWITH_BOOST=downloads \
      -DWITH_UNIT_TESTS=OFF \
      -DINSTALL_MYSQLTESTDIR= \
      -DWITH_TSAN=ON \
      -DCMAKE_PREFIX_PATH=$(pwd)/downloads/usr \
      -DCMAKE_C_FLAGS="-I$(pwd)/downloads/usr/include" -DCMAKE_CXX_FLAGS="-I$(pwd)/downloads/usr/include" \

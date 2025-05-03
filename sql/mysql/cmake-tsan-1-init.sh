source cmake-export-main-vars.sh "tsan" || exit $?

mkdir -p "$BUILD_DIR"

[ -z "$FLAGS_TSAN" ] && FLAGS_TSAN="-mllvm -tsan-use-escape-analysis-global"

#[ -z "$FLAGS_MLLVM_STAT" ] && FLAGS_MLLVM_STAT=""
[ -z "$FLAGS_MLLVM_STAT" ] && FLAGS_MLLVM_STAT="-mllvm -stats "


# Original CMake line: https://hackmd.io/@tsaninternals/Hy9L3J8KA/%2FXx9CdNCUSC6YokIXumJcwA#MySQL

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
      -DCMAKE_INSTALL_PREFIX=dist-tsan \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_C_FLAGS="-O0 -g $FLAGS_TSAN $FLAGS_MLLVM_STAT" \
      -DCMAKE_CXX_FLAGS="-O0 -g $FLAGS_TSAN $FLAGS_MLLVM_STAT" \
      -DDOWNLOAD_BOOST=1 \
      -DWITH_BOOST=downloads \
      -DWITH_UNIT_TESTS=OFF \
      -DINSTALL_MYSQLTESTDIR= \
      -DWITH_TSAN=ON \
      -DCMAKE_PREFIX_PATH=$(pwd)/downloads/usr \
      #-DOPTIMIZE_SANITIZER_BUILDS=ON

[ "$?" -eq 0 ] && \
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
      -DCMAKE_INSTALL_PREFIX=dist-tsan \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_C_FLAGS="-O0 -g $FLAGS_TSAN $FLAGS_MLLVM_STAT" \
      -DCMAKE_CXX_FLAGS="-O0 -g $FLAGS_TSAN $FLAGS_MLLVM_STAT" \
      -DDOWNLOAD_BOOST=1 \
      -DWITH_BOOST=downloads \
      -DWITH_UNIT_TESTS=OFF \
      -DINSTALL_MYSQLTESTDIR= \
      -DWITH_TSAN=ON \
      -DCMAKE_PREFIX_PATH=$(pwd)/downloads/usr \
      -DCMAKE_C_FLAGS="-I$(pwd)/downloads/usr/include" -DCMAKE_CXX_FLAGS="-I$(pwd)/downloads/usr/include" \

#-DCMAKE_C_FLAGS="-I$(pwd)/downloads/usr/include -L$(pwd)/downloads/usr/lib -L$(pwd)/downloads/usr/lib64" -DCMAKE_CXX_FLAGS="-I$(pwd)/downloads/usr/include -L$(pwd)/downloads/usr/lib -L$(pwd)/downloads/usr/lib64" \

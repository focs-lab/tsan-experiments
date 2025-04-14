source cmake-export-main-vars.sh "tsan"

cmake --build "$BUILD_DIR" -j $BUILD_NPROC

source cmake-export-main-vars.sh "orig" || exit $?

cmake --build "$BUILD_DIR" -j $BUILD_NPROC

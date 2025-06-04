source cmake-export-main-vars.sh "tsan" || exit $?

#cmake --build "$BUILD_DIR" -- -n
cmake --build "$BUILD_DIR" -j $BUILD_NPROC 

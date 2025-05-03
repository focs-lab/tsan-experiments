source cmake-export-main-vars.sh "tsan" || exit $?

cmake --install "$BUILD_DIR" --prefix "$INSTALL_PREFIX"

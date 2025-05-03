source cmake-export-main-vars.sh "orig" || exit $?

cmake --install "$BUILD_DIR" --prefix "$INSTALL_PREFIX"

#!/bin/bash

[ -z "$LLVM_ROOT_PATH" ] && echo "No \$LLVM_ROOT_PATH!" && exit 1

CC="$LLVM_ROOT_PATH/bin/clang"
CXX="$LLVM_ROOT_PATH/bin/clang++"

TSAN_FLAGS="-g -fsanitize=thread -mllvm -tsan-use-escape-analysis-global -mllvm -debug-only=ea-escaping-callees"
#TSAN_FLAGS="-g -fsanitize=thread"

PREFIX_DIR="/dev/shm/ffmpeg"
BUILD_DIR="$PREFIX_DIR/build"

[ -d "$PREFIX_DIR" ] && rm -r "$PREFIX_DIR"/*
[ -d "$BUILD_DIR" ] && rm -r "$BUILD_DIR"
mkdir -p "$PREFIX_DIR"
mkdir -p "$BUILD_DIR"

echo -e "Configuring... \n\$BUILD_DIR: $BUILD_DIR\n       \$CC: $CC\n      \$CXX: $CXX"


# https://gist.github.com/omegdadi/6904512c0a948225c81114b1c5acb875
# https://github.com/FFmpeg/FFmpeg/blob/master/INSTALL.md

[ -f "Makefile" ] && make clean

./configure \
	--prefix="$BUILD_DIR" \
	--extra-libs="-lpthread -lm" \
	--cc="$CC" \
	--cxx="$CXX" \
	--extra-cflags="$TSAN_FLAGS" \
	--extra-cxxflags="$TSAN_FLAGS" \
	--extra-ldflags="$TSAN_FLAGS" \
	--enable-gpl \
	--enable-gnutls \
	--enable-libx264 \
	--enable-libx265 \
	--enable-debug=3 \
	--disable-optimizations \
	--enable-shared \
	--disable-stripping \
	|| exit 1


# Build and install:
make -j 12 > make.stdout.log 2> make.stderr.log || exit 2

make install || exit 3


: '
	--toolchain="clang-tsan" \
	--enable-libaom \
	--enable-libass \
	--enable-libfdk-aac \
	--enable-libfreetype \
	--enable-libmp3lame \
	--enable-libopus \
	--enable-libsvtav1 \
	--enable-libdav1d \
	--enable-libvorbis \
	--enable-libvpx \
	--enable-nonfree
'

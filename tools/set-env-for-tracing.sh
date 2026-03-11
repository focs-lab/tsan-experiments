#!/bin/bash

export LLVM_SOURCE="/extra/alexey/llvm-project-for-oracle"
export LLVM_PATH="$LLVM_SOURCE/llvm/build"
export LLVM_HOME="$LLVM_PATH"
export LLVM_ROOT_PATH="$LLVM_PATH"
export LLVM_BUILD_DIR="$LLVM_PATH"
export PATH=${LLVM_PATH}/bin:$PATH
export CC="${LLVM_PATH}/bin/clang"
export CXX="${LLVM_PATH}/bin/clang++"
export LLVM_ROOT_PATH=$LLVM_PATH
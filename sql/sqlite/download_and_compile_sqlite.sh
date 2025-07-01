#!/bin/bash

# Enable command echoing and exit on error for easier debugging
set -ex

# 1. Download and unpack SQLite
# Check if the archive already exists to avoid re-downloading
if [ ! -f "sqlite-src-3500200.zip" ]; then
    wget https://sqlite.org/2025/sqlite-src-3500200.zip
fi
# Check if the source directory exists to avoid re-unpacking
if [ ! -d "sqlite-src-3500200" ]; then
    unzip sqlite-src-3500200.zip
fi

# Create the build directory, removing the old one if it exists
rm -rf build
mkdir -p build
cd build

# 2. Compile SQLite into a single file (amalgamation)
# Run configure to prepare the build
#../sqlite-src-3500200/configure --enable-all --enable-debug "CFLAGS=-O0 -g"
../sqlite-src-3500200/configure --enable-all "CFLAGS=-O2 -g"
# Create the sqlite3.c file
make sqlite3.c

echo "SQLite build completed successfully. The output is in 'build/sqlite3.c'."
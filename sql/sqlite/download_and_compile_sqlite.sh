#!/bin/bash

# Enable command echoing and exit on error for easier debugging
set -ex

# 1. Fetch and unpack SQLite, THROUGH THE COMMON HELPER like the other four applications.
# This script used to call wget directly and verify afterwards, which made SQLite the only application
# outside fetch_archive.sh: no bounded retry, no shared error path, and a bare wget failure as the whole
# diagnosis. On 2026-09-18 one transient "Unable to establish SSL connection" to sqlite.org spent 901 s
# failing and killed a leg by taking out its BASELINE configuration, so no ratio was computable at all.
# fetch_archive.sh fetches if absent and always verifies against the pinned sha256 before returning.
if [ ! -d "sqlite-src-3500200" ]; then
    FETCH="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/../../tools/fetch_archive.sh"
    "$FETCH" sqlite-src-3500200.zip || exit 1
    unzip sqlite-src-3500200.zip
fi

# Copy local threadtest.c to SQLite test folder
cp threadtest3.c sqlite-src-3500200/test/threadtest3.c

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

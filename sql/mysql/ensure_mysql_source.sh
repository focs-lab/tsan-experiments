#!/bin/bash
# ensure_mysql_source.sh — the MySQL source tree must exist before build_mysql.sh runs.
#
# The source is not vendored: the artifact's SOURCES.md states that the harness fetches each application
# at build time and verifies it against a pinned sha256 before unpacking. build_mysql.sh did neither -- it
# tested for the directory and exited 6 with "No project dir mysql-server-mysql-8.0.39!", which tells an
# evaluator that something is missing and not how to get it. On the evaluator path all four configurations
# failed in under a second (rehearsal of 2026-09-17), the same shape as SQLite's missing source.
#
# Same three steps as memcached's build_memtier.sh and ffmpeg's ensure_input_clip.sh: present -> nothing to
# do; absent -> fetch by the pinned URL, verify the sha256, unpack. A fetch is ALWAYS verified, so a moved
# or changed upstream file is a stop rather than a silently different build.
set -uo pipefail
cd "$(dirname "$0")"
SRC="mysql-server-mysql-8.0.39"        # must match build_mysql.sh's PROJECT_SRC_DIR
ARCHIVE="mysql-8.0.39.tar.gz"          # pinned in tools/source_archives.sha256

[ -f "$SRC/CMakeLists.txt" ] && exit 0

# The directory can exist without being usable -- an interrupted unpack leaves a partial tree, and
# build_mysql.sh's own second check (no CMakeLists) would then fail one step later with a different
# message. Unpack again over it rather than trusting the name.
"$(cd ../../tools && pwd)/fetch_archive.sh" "$ARCHIVE" || exit 1

echo "ensure_mysql_source: unpacking $ARCHIVE (about 1.5 GB unpacked)"
tar xzf "$ARCHIVE" || exit 1
[ -f "$SRC/CMakeLists.txt" ] || { echo "ensure_mysql_source: $ARCHIVE did not produce $SRC/CMakeLists.txt" >&2; exit 1; }
echo "ensure_mysql_source: $SRC ready"

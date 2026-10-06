#!/bin/bash
# verify_archive.sh <archive-path> — refuse to unpack anything whose sha256 is not the pinned one.
# Usage from a build script, immediately before tar/unzip:
#     "$(dirname "$0")/../../tools/verify_archive.sh" "$ARCHIVE" || exit 1
#
# Fails closed three ways, each a real failure mode rather than a hypothetical:
#   archive missing        -> a build that silently used a different tree left over from earlier work
#   archive not pinned     -> a new dependency nobody recorded; refusing is how it gets recorded
#   sha256 mismatch        -> upstream moved or the file changed; every number here is attributed to a
#                             specific source tree, so this is a stop
set -uo pipefail
LIST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/source_archives.sha256"
A=${1:?usage: verify_archive.sh <archive>}
B=$(basename "$A")
[ -f "$A" ] || { echo "verify_archive: $A does not exist" >&2; exit 1; }
[ -f "$LIST" ] || { echo "verify_archive: no pinned list at $LIST" >&2; exit 1; }
WANT=$(awk -v b="$B" '!/^#/ && $2==b {print $1}' "$LIST" | head -1)
if [ -z "$WANT" ]; then
  echo "verify_archive: $B is not in $LIST." >&2
  echo "  An archive nobody pinned cannot be verified, and a build from it cannot be attributed." >&2
  echo "  Add its sha256 to that file (and to the artifact's third-party/SOURCES.md) before building." >&2
  exit 1
fi
GOT=$(sha256sum "$A" | cut -d' ' -f1)
if [ "$GOT" != "$WANT" ]; then
  echo "verify_archive: SHA256 MISMATCH for $B — refusing to unpack." >&2
  echo "  pinned $WANT" >&2
  echo "  actual $GOT" >&2
  echo "  The upstream file has changed or this is a different archive. Everything built from it would be" >&2
  echo "  attributed to a source tree that is not this one. Fetch the pinned archive or update the pin" >&2
  echo "  deliberately, with the artifact's SOURCES.md, rather than building past this." >&2
  exit 1
fi
echo "verify_archive: $B sha256 ok"

#!/bin/bash
# fetch_archive.sh <archive-path> — ensure the archive is present and correct, fetching it if it is not.
#
# The artifact promises that "the harness fetches them at build time and must verify each archive against
# the sha256 before unpacking". Three build scripts did fetch; two errored out and told the reader to go
# and find the file themselves, which is no use to an evaluator. This makes all five behave the same way,
# and — the part that matters — a fetch is ALWAYS followed by the same verification a local file gets, so
# a moved or changed upstream file is a stop rather than a silently different build.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="$HERE/source_archives.sha256"
A=${1:?usage: fetch_archive.sh <archive>}
B=$(basename "$A")
# THE SHIPPED COPY FIRST. The artifact ships every application archive but MySQL's under
# <artifact>/third-party/sources/ (32 MB; the same files, verified below against the same pins), so that a
# build needs no network: on 20 Sep 2026 an evaluator's machine could not reach download.redis.io, every
# Redis build died in a second, and the tier stopped at its first application. The artifact root is derived
# from ART_ROOT, which the artifact's scripts export (inside the container it is /artifact), because the
# harness runs from a WORKING COPY under build/harness, where a path relative to this file resolves to
# nothing (the first version did that and fetched from the network on the real path while passing a
# test that ran the file from harness/ directly); without ART_ROOT, this file's own location (harness/tools/
# -> the root). In the lab source tree neither exists and the fetch below is what runs.
SHIPPED="${ART_ROOT:-$HERE/../..}/third-party/sources/$B"
if [ ! -f "$A" ] && [ -f "$SHIPPED" ]; then
  echo "fetch_archive: $B absent; using the shipped copy $SHIPPED"
  cp "$SHIPPED" "$A.part" && mv "$A.part" "$A"
fi
if [ ! -f "$A" ]; then
  URL=$(awk -v b="$B" '!/^#/ && $2==b {print $3}' "$LIST" | head -1)
  [ -n "$URL" ] || { echo "fetch_archive: $B is absent and has no URL in $LIST" >&2; exit 1; }
  command -v wget >/dev/null || { echo "fetch_archive: $B is absent and wget is not installed" >&2; exit 1; }
  echo "fetch_archive: $B absent; fetching from $URL"
  # to a temporary name, so an interrupted download never looks like a complete archive on the next run
  # BOUNDED. wget's default is 20 tries with a long timeout, which on 2026-09-18 spent 901 seconds failing
  # to reach sqlite.org over TLS before giving up -- fifteen minutes in which the leg was already lost and
  # nobody watching could tell whether it was hung. Three tries, 30 s each, 5 s apart: about two minutes to
  # a clear answer, and the message names the limit so the reader knows it was bounded and not abandoned.
  wget -q --tries=3 --timeout=30 --waitretry=5 -O "$A.part" "$URL" \
    || { rm -f "$A.part"; SUM=$(awk -v b="$B" '!/^#/ && $2==b {print $1}' "$LIST" | head -1)
         echo "fetch_archive: download failed for $URL (3 tries, 30 s each). Obtain the file elsewhere and place it at" >&2
         echo "fetch_archive:   $A   (sha256 $SUM); it is verified before use." >&2; exit 1; }
  mv "$A.part" "$A"
fi
exec "$HERE/verify_archive.sh" "$A"

#!/bin/bash

set -e

#BUILDTYPELIST="tsan   tsan-dom-ea-lo-st-swmr   tsan-dom   tsan-ea   tsan-st   tsan-swmr   tsan-lo"
BUILDTYPELIST="tsan   tsan-swmr   tsan-lo"

BUILDTYPELIST="$(echo $BUILDTYPELIST | xargs)"

for i in $BUILDTYPELIST; do
	./build_ffmpeg.sh $i
done

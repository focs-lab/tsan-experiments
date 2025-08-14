#!/bin/bash

set -e

source ./config_definitions.sh || exit $?

#BUILDTYPELIST="${!CONFIG_DETAILS[@]}"
#BUILDTYPELIST="tsan-dom-ea-lo-st-swmr"
#BUILDTYPELIST="orig tsan tsan-dom tsan-ea tsan-dom-ea tsan-lo tsan-dom-lo tsan-ea-lo tsan-dom-ea-lo tsan-loub tsan-dom-loub tsan-ea-loub tsan-dom-ea-loub tsan-lo-loub tsan-dom-lo-loub tsan-ea-lo-loub tsan-dom-ea-lo-loub tsan-st tsan-dom-st tsan-ea-st tsan-dom-ea-st tsan-lo-st tsan-dom-lo-st tsan-ea-lo-st tsan-dom-ea-lo-st tsan-loub-st tsan-dom-loub-st tsan-ea-loub-st tsan-dom-ea-loub-st tsan-lo-loub-st tsan-dom-lo-loub-st tsan-ea-lo-loub-st tsan-dom-ea-lo-loub-st tsan-swmr tsan-dom-swmr tsan-ea-swmr tsan-dom-ea-swmr tsan-lo-swmr tsan-dom-lo-swmr tsan-ea-lo-swmr tsan-dom-ea-lo-swmr tsan-loub-swmr tsan-dom-loub-swmr tsan-ea-loub-swmr tsan-dom-ea-loub-swmr tsan-lo-loub-swmr tsan-dom-lo-loub-swmr tsan-ea-lo-loub-swmr tsan-dom-ea-lo-loub-swmr tsan-st-swmr tsan-dom-st-swmr tsan-ea-st-swmr tsan-dom-ea-st-swmr tsan-lo-st-swmr tsan-dom-lo-st-swmr tsan-ea-lo-st-swmr tsan-dom-ea-lo-st-swmr tsan-loub-st-swmr tsan-dom-loub-st-swmr tsan-ea-loub-st-swmr tsan-dom-ea-loub-st-swmr tsan-lo-loub-st-swmr tsan-dom-lo-loub-st-swmr tsan-ea-lo-loub-st-swmr tsan-dom-ea-lo-loub-st-swmr"
BUILDTYPELIST="orig tsan tsan-dom tsan-ea tsan-lo tsan-st tsan-swmr tsan-dom-ea-lo-st-swmr"

BUILDTYPELIST="$(echo $BUILDTYPELIST | xargs)"

for i in $BUILDTYPELIST; do
	echo -e "\n\e[94m ===== $i =====\e[0m\n"

	[ -d "ffmpeg-$i" ] && echo -e "\n\e[94mSkipping $i, exists already...\e[0m\n" && sleep 3 && continue

	./build_ffmpeg.sh $i
done

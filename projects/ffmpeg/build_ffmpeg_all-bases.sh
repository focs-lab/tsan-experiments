#!/bin/bash

set -e

source ./config_definitions.sh || exit $?

#BUILDTYPELIST="tsan   tsan-dom-ea-lo-st-swmr   tsan-dom   tsan-ea   tsan-st   tsan-swmr   tsan-lo"
#BUILDTYPELIST="tsan   tsan-swmr   tsan-lo"
#BUILDTYPELIST="$(echo $BUILDTYPELIST | xargs)"

for i in ${!CONFIG_DETAILS[@]}; do
	echo -e "\n\e[94m ===== $i =====\e[0m\n"

	[ -d "ffmpeg-$i" ] && echo -e "\n\e[94mSkipping $i, exists already...\e[0m\n" && sleep 3 && continue

	./build_ffmpeg.sh $i
done

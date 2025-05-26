#!/bin/bash

FFBUILDLIST=$(ls -d ffmpeg-tsan* | xargs | sed "s/\s/,/g")
echo -e "$FFBUILDLIST\n"

#FFBUILDLIST="build-main-tsan-dflt, build-tsan-ea-pathes-to-underl-objs_ac06afd320, build-tsan-ea-whitelist-DEBUG-enable-disable_34dff3204b, build-tsan-with-ea-IPA_8a2198773e"
#FFBUILDLIST="build_tsan-with-ea-IPA_574e8d6cbd_tsan-dflt, build_tsan-with-ea-IPA_574e8d6cbd_ea, build_tsan-with-ea-IPA_574e8d6cbd_own, build_tsan-with-ea-IPA_574e8d6cbd_st"
FFTESTVIDEO="/home/mcm-remote/Downloads/WatchingEyeTexture.mkv"


#FFEXEC="bin/ffmpeg -hide_banner -i \"$FFTESTVIDEO\" -threads $(nproc) -y -c:v h264 /dev/shm/out.mp4"
FFEXEC="bin/ffmpeg -hide_banner -i \"$FFTESTVIDEO\" -threads $(nproc) -y -f mjpeg /dev/shm/out.mp4"
#FFEXEC="bin/ffmpeg -hide_banner -i \"$FFTESTVIDEO\" -threads $(nproc) -y -c:v libx265 -vtag hvc1 /dev/shm/out.mp4"

# Non-working:
#FFEXEC="bin/ffmpeg -hide_banner -i \"$FFTESTVIDEO\" -threads $(nproc) -y -c:v huffyuv /dev/shm/out.mp4"
#FFEXEC="bin/ffmpeg -hide_banner -i \"$FFTESTVIDEO\" -threads $(nproc) -y -vf scale=426:240 -c:v libx264 -preset ultrafast -b:v 400k /dev/shm/out.mp4"

#-f png -pixel_format rgb4 
#-pixel_format yuv420p


FFBUILDLIST=$(echo $FFBUILDLIST | sed "s/\s/,/g" | sed "s/,,\+/,/g")

hyperfine \
	--parameter-list FFBUILD "$FFBUILDLIST" \
	--min-runs 5 \
	--export-csv=ffcompare.csv \
	"LD_LIBRARY_PATH=\"{FFBUILD}/lib/\" {FFBUILD}/$FFEXEC"
#	--show-output \

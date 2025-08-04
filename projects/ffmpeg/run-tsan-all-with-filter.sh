#!/bin/sh

export TSAN_OPTIONS="enable_filter=1"
export LD_LIBRARY_PATH=ffmpeg-tsan-dom-ea-lo-st-swmr/lib:$LD_LIBRARY_PATH

ffmpeg-tsan-dom-ea-lo-st-swmr/bin/ffmpeg -hide_banner -i "./input/WatchingEyeTexture.mkv" -threads 8 -y -c:v libx264 -preset medium -crf 23  -loglevel error /tmp/output.mkv

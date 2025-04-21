#!/bin/bash

set -e

function normalexit {
	[ -n "$1" ] && echo "$1"

	echo "Launch script \"./ffmpeg-build.sh\" in directory \"FFmpeg-n4.3.9/\"."
	exit 0
}


FFMPEG_TAR_FILENAME="FFmpeg-n4.3.9.tar.gz"

# Get source code:
[ ! -f "$FFMPEG_TAR_FILENAME" ] \
	&& wget https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n4.3.9.tar.gz \
	&& mv n4.3.9.tar.gz "$FFMPEG_TAR_FILENAME"

[ -d "FFmpeg-n4.3.9" ] && normalexit "Unpacked FFmpeg directory already exist."


# Unpack:
tar -xzf "$FFMPEG_TAR_FILENAME"

# Copy special dummy empty file to prevent some strange errors:
cp ea-func-whitelist.dummy.txt FFmpeg-n4.3.9/ea-func-whitelist.txt

# Copy the build script file:
cp ffmpeg-build.sh FFmpeg-n4.3.9/ffmpeg-build.sh
chmod +x FFmpeg-n4.3.9/ffmpeg-build.sh


normalexit "Ready."

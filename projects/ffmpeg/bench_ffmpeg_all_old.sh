#!/bin/bash

set -e

# --- Configuration ---

# Video file:
FFTESTVIDEO="/home/mcm-remote/Downloads/WatchingEyeTexture.mkv"
[ ! -f "$FFTESTVIDEO" ] && echo "No video $FFTESTVIDEO" && exit 1

# What to benchmark:
FFBUILDLIST=$(ls -d ffmpeg-tsan* 2>/dev/null | xargs | sed "s/\s/,/g")
[ -z "$FFBUILDLIST" ] && echo "No FFmpeg builds (\"ffmpeg-*\")." && exit 2


# Hyperfine minimal runs number (results deviating automatically increases the value):
HYPERFINE_MIN_RUNS=3

# Splitting and reconstructing with commas:
FFBUILDLIST=$(echo "$FFBUILDLIST" | tr -s ',')

if ! command -v jq > /dev/null 2>&1; then
	echo "No 'jq' program found for results processing."
	exit 3
fi



#HYPERFINE_EXTRA_PARAMS="--show-output"

# Определения кодеков и их параметров для FFmpeg.
# Формат: "название_кодека": "параметры_FFmpeg::расширение_выходного_файла"
# Примечания по кодекам:
# - libx264/libx265: современные, высокоэффективные, хорошо параллелизуются. -preset medium обеспечивает баланс.
# - mjpeg: покадровый JPEG, средняя параллелизация.
# - msvideo1: очень старый, без внутренней параллелизации.
# - prores_ks: качественный кодек для редактирования, хорошая параллелизация.
# - libvpx-vp9: кодек Google, хорошо параллелизуется.
# - copy_passthrough: для базовой оценки накладных расходов FFmpeg без перекодирования.
declare -A CODECS
#CODECS[h264_libx264]="-c:v libx264 -preset medium -crf 23 ::mp4"
CODECS[h265_libx265]="-c:v libx265 -preset medium -crf 28 -tag:v hvc1 ::mp4"
#CODECS[mjpeg]="-c:v mjpeg -pix_fmt yuvj420p -q:v 2 ::avi"
#CODECS[copy_passthrough]="-c:v copy -c:a copy ::mkv"

# Too slow or broken:
#CODECS[prores_ks]="-c:v prores_ks -profile:v 3 ::mov"
#CODECS[msvideo1]="-c:v msvideo1 -vf \"scale=trunc(iw/4)*4:trunc(ih/4)*4\" ::avi"
#CODECS[vp9_libvpx]="-c:v libvpx-vp9 -b:v 1M ::webm" # Bitrate-based for VP9


# --- FFmpeg benchmark start ---

echo "--- FFmpeg benchmark start ---"
echo "Builds: $FFBUILDLIST"
echo "Video file: $FFTESTVIDEO"
echo ""

mkdir -p results

SUMMARY_CSV="summary_ffmpeg_benchmark.csv"
echo "Codec,FFBUILD,mean,stddev,median,user,system,min,max,max_mem_kb,command" > "$SUMMARY_CSV"


for codec_key in "${!CODECS[@]}"; do
    echo "--- Benchmark: $codec_key ---"
    codec_info="${CODECS[$codec_key]}"

    # Выделение параметров FFmpeg и выходного расширения:
    encoding_params="${codec_info%%::*}"
    output_ext="${codec_info##*::}"
    #IFS='::' read -r encoding_params output_ext <<< "$codec_info"
    #echo $encoding_params
    #echo $output_ext
    #continue

    # An exec command:
    FFEXEC_CMD="bin/ffmpeg -hide_banner -i \"$FFTESTVIDEO\" -threads $(nproc) -y $encoding_params -loglevel info /dev/shm/out.$output_ext"

    HYPERFINE_JSON="results/${codec_key}.json"
    HYPERFINE_CSV="results/${codec_key}.csv"

    echo "hyperfine for $codec_key:"
    echo -e "\tLD_LIBRARY_PATH=\"{FFBUILD}/lib/\" {FFBUILD}/$FFEXEC_CMD"

    # Launching hyperfine:
    hyperfine \
        --parameter-list FFBUILD "$FFBUILDLIST" \
        --min-runs "$HYPERFINE_MIN_RUNS" \
        --export-json="$HYPERFINE_JSON" \
        --export-csv="$HYPERFINE_CSV" \
        $HYPERFINE_EXTRA_PARAMS \
        --ignore-failure \
        "LD_LIBRARY_PATH=\"{FFBUILD}/lib/\" {FFBUILD}/$FFEXEC_CMD" || {
	        echo "Error when processing $codec_key."
	        echo "-------------------------------------"
	        echo ""
	        exit 4
	        continue
    }


    echo "--- Results for $codec_key: ---"
    if [ -f "$HYPERFINE_JSON" ]; then
        jq -r --arg codec_name "$codec_key" '
          .results[] |
          "\(.parameters.FFBUILD): \(.mean | tostring)s (mean), \(.stddev | tostring)s (stddev), min=\(.min | tostring)s, max=\(.max | tostring)s"
        ' "$HYPERFINE_JSON" | column -t
        echo ""

        # Append to the general CSV file.
        jq -r --arg codec_name "$codec_key" '
          .results[] |
          [
            $codec_name,
            .parameters.FFBUILD,
            .mean,
            .stddev,
            .median,
            .user,
            .system,
            .min,
            .max,
            .command
          ] | @csv
        ' "$HYPERFINE_JSON" >> "$SUMMARY_CSV"
    else
        echo "No JSON general results file \"$HYPERFINE_JSON\" found."
    fi

	rm "/dev/shm/out.$output_ext"
    echo "-------------------------------------"
    echo ""
done


set +e

echo -e "\n----- Ready! -----\n"

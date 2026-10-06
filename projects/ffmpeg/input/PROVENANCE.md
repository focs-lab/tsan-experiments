# FFmpeg benchmark input

`TearsOfSteel-1366x768-100s.mkv` — sha256 `43b0fba97eb05a0e44d7518fe9d6993c140680531a17a240ea6d53582fbe9985`

## Source

*Tears of Steel* (2012), Blender Foundation, **CC-BY 3.0** — https://mango.blender.org/
Downloaded from `https://download.blender.org/demo/movies/ToS/tears_of_steel_1080p.mov.zip`
(557 MB, sha256 `d87a41de040d3814dbde143e9ab85ef122caf22265f660b0bebf476cd8b357a5`).
The source is redistributable under CC-BY; this repository ships the command rather than the file.

## Producing command

```
ffmpeg -hide_banner -loglevel error -ss 360 -t 100 -i tears_of_steel_1080p.mov -vf crop=1422:800\,scale=1366:768\,fps=30 -c:v libx264 -preset medium -b:v 6400k -pix_fmt yuv420p -c:a libvorbis -ar 48000 -ac 2 -y TearsOfSteel-1366x768-100s.mkv 
```

Segment: 100 s from 06:00. `-b:v 6400k` targets the retired clip's bit rate rather than a quality level, so
the encoders see a comparable amount of data per second.

## Two deviations from the stated specification, both deliberate

1. **The source is 1920x800 (2.40:1), not 16:9.** Scaling it directly to 1366x768 would distort, and padding
   to 16:9 would fill a seventh of every frame with black — which encodes almost free and would understate the
   encoder work the benchmark is there to measure. The clip is therefore **cropped to 1422x800 (16:9) and then
   scaled**, so every pixel carries real content.
2. **The source is 24 fps and the output is 30 fps**, as specified, so `fps=30` duplicates **one output frame
   in five** — 600 of the 3 000 output frames, since 24 source frames become 30. Duplicated frames are cheap to encode, so 100 s here is slightly less encoder work than 100 s
   of native 30 fps material. This does not bias the TSan-vs-native ratio — both arms encode the same frames —
   but it makes absolute times a little lower than the frame count suggests.

## Comparability

| | retired clip | this clip |
|---|---|---|
| resolution / fps / pixel format | 1366x768, 30, yuv420p | 1366x768, 30, yuv420p |
| duration | 100.56 s | 100.00 s |
| video bit rate | 6.41 Mbit/s | 6.52 Mbit/s |
| audio | vorbis 48 kHz stereo | vorbis 48 kHz stereo |

Shape matches, **content does not**. No FFmpeg measurement taken on `WatchingEyeTexture.mkv` is comparable
with one taken on this file, including the concurrency sweep's FFmpeg arm and every FFmpeg row in
`tools/perf/RESULTS.md` predating 2026-09-15.

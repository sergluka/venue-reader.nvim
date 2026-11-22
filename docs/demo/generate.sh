#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
scratch=$(mktemp -d "$PWD/.recording.XXXXXX")
trap 'rm -r -- "$scratch"' EXIT

vhs --output "$scratch/recording.mp4" demo.tape
test -s "$scratch/recording.mp4"

caption_filter="subtitles=demo.srt:force_style='FontName=DejaVu Sans,FontSize=16.578,PrimaryColour=&H00FFFFFF,Outline=0,Shadow=0,Alignment=6,MarginV=1'"
ffmpeg -hide_banner -loglevel error -i "$scratch/recording.mp4" \
  -vf "pad=iw:ih+48:0:48:color=0x222b42,$caption_filter" \
  -c:v libx264 -crf 17 -pix_fmt yuv420p -movflags +faststart \
  "$scratch/venue-reader.mp4"

mv -- "$scratch/venue-reader.mp4" venue-reader.mp4
printf 'Created %s/venue-reader.mp4\n' "$PWD"

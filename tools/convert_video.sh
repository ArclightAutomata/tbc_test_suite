#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Convert any video into the TBC Test Suite raw clip format:
# RGB565 little-endian, 724x480, 29.97 fps, no container.
# Load via OSD: "Load Video". The clip loops during playback.
# Size budget: the core stores the clip in a 248 MB DDR region,
# which is ~12 seconds — the default duration caps at 10 s.
set -e
IN="${1:?usage: convert_video.sh <input-video> <output.bin> [seconds] [safe]}"
OUT="${2:?usage: convert_video.sh <input-video> <output.bin> [seconds] [safe]}"
DUR="${3:-10}"
# "safe": letterbox into the inner ~90% so CRT overscan doesn't hide edges
if [ "${4:-}" = "safe" ]; then
  VF="fps=30000/1001,scale=652:432:flags=lanczos,pad=724:480:36:24,setsar=1"
else
  VF="fps=30000/1001,scale=724:480:flags=lanczos,setsar=1"
fi
ffmpeg -y -i "$IN" -t "$DUR" \
  -vf "$VF" \
  -pix_fmt rgb565le -f rawvideo "$OUT"
echo "$(du -h "$OUT" | cut -f1) written. Copy to the MiSTer SD card and load via OSD."

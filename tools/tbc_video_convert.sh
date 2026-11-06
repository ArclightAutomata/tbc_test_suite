#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# TBC Test Suite - on-device video converter (runs ON the MiSTer).
#
# Install: copy to /media/fat/Scripts/tbc_video_convert.sh
# Use:     drop .mp4/.mkv/.avi/.mov/.mpg/.webm/.m4v files into
#          /media/fat/games/TBC_TEST_SUITE/ then run this from the
#          MiSTer Scripts menu. Each video becomes <name>.bin next to
#          it (raw RGB565 724x480 29.97 fps, first $MAXSEC seconds,
#          letterboxed into the CRT-safe area). In the TBC Test Suite
#          OSD select Pattern -> Custom Video, then pick the .bin from
#          the Load Video row that appears.
#
# ffmpeg: uses /media/fat/linux/ffmpeg (static armhf build); offers to
# download it automatically if missing.

VIDDIR="${VIDDIR:-/media/fat/games/TBC_TEST_SUITE}"
FFMPEG="${FFMPEG:-/media/fat/linux/ffmpeg}"
MAXSEC="${MAXSEC:-10}"     # DDR clip region fits ~12 s (ignored in stream mode)
SAFE="${SAFE:-1}"          # 1 = letterbox into CRT-safe area, 0 = full frame
STREAM="${STREAM:-0}"      # 1 = full-length 360x480 .sbin for tbc_stream.sh
FFURL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-armhf-static.tar.xz"

mkdir -p "$VIDDIR"

if [ ! -x "$FFMPEG" ]; then
	echo "ffmpeg not found at $FFMPEG"
	echo "Downloading static build (~16 MB)..."
	TMP=/tmp/ffmpeg-dl
	rm -rf "$TMP"; mkdir -p "$TMP"
	if wget -q -O "$TMP/ff.tar.xz" "$FFURL" && \
	   tar -xJf "$TMP/ff.tar.xz" -C "$TMP" --wildcards "*/ffmpeg"; then
		mkdir -p /media/fat/linux
		mv "$TMP"/*/ffmpeg "$FFMPEG"
		chmod +x "$FFMPEG"
		rm -rf "$TMP"
		echo "Installed $FFMPEG"
	else
		echo "Download failed. Get ffmpeg-release-armhf-static.tar.xz from"
		echo "johnvansickle.com/ffmpeg and place the ffmpeg binary at $FFMPEG"
		exit 1
	fi
fi

if [ "$STREAM" = "1" ]; then
	# streaming format: 360x480 half-width (10.4 MB/s from SD), no cap
	if [ "$SAFE" = "1" ]; then
		VF="fps=30000/1001,scale=324:432:flags=lanczos,pad=360:480:18:24,setsar=1"
	else
		VF="fps=30000/1001,scale=360:480:flags=lanczos,setsar=1"
	fi
	EXT="sbin"; TFLAG=""
elif [ "$SAFE" = "1" ]; then
	VF="fps=30000/1001,scale=652:432:flags=lanczos,pad=724:480:36:24,setsar=1"
	EXT="bin"; TFLAG="-t $MAXSEC"
else
	VF="fps=30000/1001,scale=724:480:flags=lanczos,setsar=1"
	EXT="bin"; TFLAG="-t $MAXSEC"
fi

le64() { # le64 <value> -> 8 little-endian bytes on stdout
	local b="" i
	for i in 0 1 2 3 4 5 6 7; do
		b="$b\\x$(printf '%02x' $(( ($1 >> (8*i)) & 255 )))"
	done
	printf "$b"
}

sbin_header() { # sbin_header <outfile> <total_frames>
	# w0 magic 0x5442435300000001, w1 width=360, w2 total, w3 ring=256 (LE)
	{ le64 $((0x5442435300000001)); le64 360; le64 "$2"; le64 256; } > "$1"
	dd if=/dev/zero bs=1 count=$((4608 - 32)) >> "$1" 2>/dev/null
}

sbin_set_frames() { # sbin_set_frames <file> <total_frames>: patch w2 in place
	le64 "$2" | dd of="$1" bs=1 seek=16 conv=notrunc 2>/dev/null
}

found=0
converted=0
for f in "$VIDDIR"/*.mp4 "$VIDDIR"/*.mkv "$VIDDIR"/*.avi "$VIDDIR"/*.mov "$VIDDIR"/*.mpg "$VIDDIR"/*.webm "$VIDDIR"/*.m4v; do
	[ -e "$f" ] || continue
	found=1
	out="${f%.*}.$EXT"
	if [ -e "$out" ] && [ ! "$f" -nt "$out" ]; then
		echo "skip (up to date): $(basename "$f")"
		continue
	fi
	# a .failed marker stops the auto-convert watcher from retrying a
	# broken file every poll; delete the marker (or update the source)
	# to retry
	if [ -e "$out.failed" ] && [ ! "$f" -nt "$out.failed" ]; then
		echo "skip (previous failure, delete $(basename "$out").failed to retry): $(basename "$f")"
		continue
	fi
	if [ "$STREAM" = "1" ]; then
		echo "converting for streaming: $(basename "$f") -> $(basename "$out") (full length)"
		# write to .part and rename at the end so the core's file browser
		# never sees a half-written output. ffmpeg streams straight in
		# after the header (frame count patched in afterwards), so the
		# conversion never needs room for a second full-size copy - a
		# half-hour tape is ~19 GB.
		sbin_header "$out.part" 0
		if "$FFMPEG" -loglevel warning -stats -i "$f" \
		     -vf "$VF" -pix_fmt rgb565le -f rawvideo - >> "$out.part"; then
			frames=$(( ($(stat -c %s "$out.part") - 4608) / 345600 ))
			sbin_set_frames "$out.part" "$frames"
			mv "$out.part" "$out"
			rm -f "$out.failed"
			converted=$((converted+1))
			echo "done: $(basename "$out") ($frames frames, $(du -h "$out" | cut -f1))"
		else
			echo "FAILED: $(basename "$f")"
			rm -f "$out" "$out.part"
			touch "$out.failed"
		fi
	else
		echo "converting: $(basename "$f") -> $(basename "$out") (first ${MAXSEC}s)"
		# .part + rename: the OSD browser never sees a half-written .bin
		if "$FFMPEG" -y -loglevel warning -stats -i "$f" $TFLAG \
		     -vf "$VF" -pix_fmt rgb565le -f rawvideo "$out.part"; then
			mv "$out.part" "$out"
			rm -f "$out.failed"
			converted=$((converted+1))
			echo "done: $(basename "$out") ($(du -h "$out" | cut -f1))"
		else
			echo "FAILED: $(basename "$f")"
			rm -f "$out" "$out.part"
			touch "$out.failed"
		fi
	fi
done

if [ "$found" = "0" ]; then
	echo "No video files found in $VIDDIR"
	echo "Copy .mp4/.mkv/.avi/.mov/.mpg/.webm/.m4v files there and run again."
else
	echo ""
	echo "$converted file(s) converted. In the TBC Test Suite core:"
	echo "  OSD -> Pattern -> Custom Video, then Load Video -> pick the .bin"
fi

#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# TBC Test Suite - SD video streaming launcher (runs ON the MiSTer).
#
# Streams a pre-converted .sbin (tbc_video_convert.sh with STREAM=1)
# from the SD card into the core's DDR ring buffer for unlimited-length
# playback. The heavy lifting is done by tbc_streamd (a small mmap-based
# daemon: the core-DDR region rejects read()/write() syscalls, so shell
# tools like dd cannot write it).
#
# Install: copy this to /media/fat/Scripts/tbc_stream.sh and tbc_streamd
#          to /media/fat/linux/tbc_streamd
# Use:     run from the Scripts menu (streams the first .sbin found in
#          /media/fat/games/TBC_TEST_SUITE), or via ssh:
#            tbc_stream.sh /path/to/clip.sbin   # start
#            tbc_stream.sh stop                 # stop
# Then select the Custom Video pattern in the core.

VIDDIR="/media/fat/games/TBC_TEST_SUITE"
DAEMON="/media/fat/linux/tbc_streamd"
PIDFILE="/tmp/tbc_stream.pid"
LOG="/tmp/tbc_stream.log"

if [ "$1" = "stop" ]; then
	[ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null && rm -f "$PIDFILE"
	echo "stream stopped"
	exit 0
fi

if [ ! -x "$DAEMON" ]; then
	echo "missing $DAEMON - copy tools/tbc_streamd there"
	exit 1
fi

FILE="$1"
[ -z "$FILE" ] && FILE=$(ls "$VIDDIR"/*.sbin 2>/dev/null | head -1)
if [ ! -f "$FILE" ]; then
	echo "No .sbin found. Convert one with: STREAM=1 tbc_video_convert.sh"
	exit 1
fi

# stop any previous instance
[ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null && rm -f "$PIDFILE"

"$DAEMON" "$FILE" > "$LOG" 2>&1 &
echo $! > "$PIDFILE"
sleep 2
head -2 "$LOG"
echo "daemon pid $(cat "$PIDFILE"); stop with: tbc_stream.sh stop"

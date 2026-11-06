#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# TBC Test Suite - background auto-converter (runs ON the MiSTer).
#
# Watches /media/fat/games/TBC_TEST_SUITE/ and automatically converts
# any new or updated video file (via tbc_video_convert.sh), so the .bin
# is already waiting in the core's Load Video browser by the time you
# copy a video onto the SD card (scp / SMB / USB).
#
# Install: copy to /media/fat/Scripts/tbc_autoconvert.sh
#          (alongside tbc_video_convert.sh, which it calls)
# Use:     run from the MiSTer Scripts menu to TOGGLE the watcher on or
#          off, or via ssh:  tbc_autoconvert.sh start|stop|status
# Log:     /tmp/tbc_autoconvert.log
#
# STREAM=1 converts to full-length .sbin (for tbc_stream.sh) instead of
# 10 s .bin clips. MIND THE OUTPUT SIZE: raw video is enormous - a .bin
# clip is ~21 MB per second (~208 MB for the 10 s default) and a
# streaming .sbin is ~10.4 MB per second, i.e. ~3 GB for 5 minutes.
#
# Make it the DEFAULT (opt-out):  tbc_autoconvert.sh install
#   - starts the watcher now and adds an autostart line to
#     /media/fat/linux/user-startup.sh so it runs from every boot.
# Revert to opt-in:                tbc_autoconvert.sh uninstall

VIDDIR="/media/fat/games/TBC_TEST_SUITE"
CONVERT="/media/fat/Scripts/tbc_video_convert.sh"
PIDFILE="/tmp/tbc_autoconvert.pid"
LOG="/tmp/tbc_autoconvert.log"
STREAM="${STREAM:-0}"
INTERVAL=10

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

watch_loop() {
	[ "$STREAM" = "1" ] && EXT=sbin || EXT=bin
	echo "$(date '+%H:%M:%S') watcher started (output .$EXT, poll ${INTERVAL}s)" >> "$LOG"
	while :; do
		# anything to do?
		work=0
		for f in "$VIDDIR"/*.mp4 "$VIDDIR"/*.mkv "$VIDDIR"/*.avi \
		         "$VIDDIR"/*.mov "$VIDDIR"/*.mpg "$VIDDIR"/*.webm "$VIDDIR"/*.m4v; do
			[ -e "$f" ] || continue
			out="${f%.*}.$EXT"
			if [ ! -e "$out" ] || [ "$f" -nt "$out" ]; then work=1; break; fi
		done
		if [ "$work" = "1" ]; then
			# quiescence check: skip this pass while a copy is still in
			# flight (any source file still growing)
			s1=$(ls -l "$VIDDIR" 2>/dev/null | md5sum)
			sleep 5
			s2=$(ls -l "$VIDDIR" 2>/dev/null | md5sum)
			if [ "$s1" = "$s2" ]; then
				STREAM=$STREAM bash "$CONVERT" >> "$LOG" 2>&1
			fi
		fi
		# keep the log from growing without bound
		if [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
			tail -c 65536 "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"
		fi
		sleep "$INTERVAL"
	done
}

start() {
	if is_running; then echo "already running (pid $(cat "$PIDFILE"))"; return; fi
	mkdir -p "$VIDDIR"
	STREAM=$STREAM watch_loop </dev/null >>"$LOG" 2>&1 &
	echo $! > "$PIDFILE"
	echo "auto-convert watcher STARTED (pid $!)"
	echo "drop videos into $VIDDIR - .bin appears automatically"
	echo "log: $LOG"
}

stop() {
	if is_running; then
		kill "$(cat "$PIDFILE")" 2>/dev/null
		rm -f "$PIDFILE"
		echo "auto-convert watcher STOPPED"
	else
		rm -f "$PIDFILE"
		echo "not running"
	fi
}

STARTUP=/media/fat/linux/user-startup.sh
STARTLINE="/media/fat/Scripts/tbc_autoconvert.sh start"

install_boot() {
	if [ -f "$STARTUP" ] && grep -qF "$STARTLINE" "$STARTUP"; then
		echo "autostart already installed in $STARTUP"
	else
		[ -f "$STARTUP" ] || printf '#!/bin/sh\n' > "$STARTUP"
		chmod +x "$STARTUP"
		echo "$STARTLINE" >> "$STARTUP"
		echo "autostart installed in $STARTUP"
	fi
	start
}

uninstall_boot() {
	if [ -f "$STARTUP" ]; then
		grep -vF "$STARTLINE" "$STARTUP" > "$STARTUP.t" && mv "$STARTUP.t" "$STARTUP"
		chmod +x "$STARTUP"
		echo "autostart removed from $STARTUP"
	fi
	stop
}

case "${1:-toggle}" in
	start)     start ;;
	stop)      stop ;;
	install)   install_boot ;;
	uninstall) uninstall_boot ;;
	status)    if is_running; then echo "running (pid $(cat "$PIDFILE"))"; tail -5 "$LOG" 2>/dev/null; else echo "not running"; fi ;;
	*)         if is_running; then stop; else start; fi ;;
esac

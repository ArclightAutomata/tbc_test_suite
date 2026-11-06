#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# osd.sh <raw_seq string> — drive the MiSTer OSD remotely, then snapshot HDMI
#
# Uses MiSTer_Batch_Control (mbc) on the MiSTer over ssh.
#
# Environment (defaults in brackets):
#   MISTER_HOST  ssh host for the MiSTer         [mister]
#   MBC          path to mbc on the MiSTer       [/media/fat/mbc]
#   HDMI_DEV     HDMI capture device             [/dev/video11]
#   CAPTURE_DIR  where the snapshot is written   [/tmp/tbc_captures]
#
# raw_seq key characters:
#   M = F12 (toggle OSD)      O = Enter (cycles an option's value)
#   U/D/L/R = arrows          E = Esc (closes the OSD ENTIRELY, even from a submenu)
#   :0e = Backspace (go back one menu level)
#   !s = wait 1 second
#
# Quirks learned the hard way:
# - A leading !s is prepended: the first keys are lost while MiSTer
#   registers mbc's virtual keyboard.
# - Right/Left do NOT cycle option values; only Enter does.
# - Reopening the OSD returns to the remembered submenu, but the cursor
#   resets to that submenu's FIRST item.
# - Loading a core: echo "load_core /media/fat/_Utility/TBC_Test_Suite.rbf" > /dev/MiSTer_cmd
set -e
SEQ="${1:?usage: osd.sh <seq>}"
MISTER_HOST="${MISTER_HOST:-mister}"
MBC="${MBC:-/media/fat/mbc}"
HDMI_DEV="${HDMI_DEV:-/dev/video11}"
DIR="${CAPTURE_DIR:-/tmp/tbc_captures}"
mkdir -p "$DIR"
ssh "$MISTER_HOST" "$MBC raw_seq '!s${SEQ}'"
sleep 1
ffmpeg -y -loglevel error -f v4l2 -i "$HDMI_DEV" -frames:v 1 "$DIR/osd_state.jpg"
echo "$DIR/osd_state.jpg"

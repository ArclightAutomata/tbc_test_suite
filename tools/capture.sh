#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# capture.sh <label> — grab 1 HDMI frame + 8 CRT frames over ~2.7s
#
# Needs two V4L2 capture devices on the dev machine: one on the MiSTer's
# HDMI output, and a camera pointed at a CRT on the analog output (a
# camera, not a capture card, so no digitizer quietly corrects the
# timing). Rolling on the CRT shows up as the image sitting at different
# vertical positions (or a visible blanking bar) across the frames.
#
# Environment (defaults in brackets):
#   HDMI_DEV     HDMI capture device            [/dev/video11]
#   CRT_DEV      camera on the CRT              [/dev/video10]
#   CAPTURE_DIR  where captures are written     [/tmp/tbc_captures]
set -e
LABEL="${1:?usage: capture.sh <label>}"
HDMI_DEV="${HDMI_DEV:-/dev/video11}"
CRT_DEV="${CRT_DEV:-/dev/video10}"
DIR="${CAPTURE_DIR:-/tmp/tbc_captures}/$LABEL"
mkdir -p "$DIR"
ffmpeg -y -loglevel error -f v4l2 -i "$HDMI_DEV" -frames:v 1 "$DIR/hdmi.jpg" &
ffmpeg -y -loglevel error -f v4l2 -i "$CRT_DEV" -vf fps=3 -frames:v 8 "$DIR/crt_%02d.jpg"
wait
echo "$DIR"
ls "$DIR"

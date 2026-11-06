#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Test for tools/tbc_video_convert.sh STREAM=1 (.sbin) on the host.
#
# A full-length .sbin is ~10 MB per second of video, so the conversion
# must not need room for two copies of it. This runs the converter with
# a fake ffmpeg that emits FRAMES frames of known bytes, and a wrapper
# around `rm` that records the directory's total size whenever the
# script deletes something (the moment a temporary full copy would be
# cleaned up). Checks:
#   1  the .sbin is valid: magic, width 360, frame count, size, and the
#      frame bytes exactly as ffmpeg produced them
#   2  peak disk use stays within 5% of the final file (no second copy)
# Exit code 0 = all checks passed, 1 = a check failed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CONV="$HERE/../../tools/tbc_video_convert.sh"
FRAMES=50
FRAME=345600
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/vid" "$T/bin"
printf 'not really a video' > "$T/vid/clip.mp4"
: > "$T/peak"

# fake ffmpeg: FRAMES frames of a counting byte pattern to the last
# argument ("-" = stdout), like -f rawvideo would
cat > "$T/bin/ffmpeg" <<EOF
#!/bin/bash
out="\${@: -1}"
gen() { python3 -c "import sys; [sys.stdout.buffer.write(bytes([k % 251]) * $FRAME) for k in range($FRAMES)]"; }
if [ "\$out" = "-" ]; then gen; else gen > "\$out"; fi
EOF
chmod +x "$T/bin/ffmpeg"

# rm wrapper: log the directory size before every delete
cat > "$T/bin/rm" <<EOF
#!/bin/bash
du -sb "$T/vid" | cut -f1 >> "$T/peak"
exec /bin/rm "\$@"
EOF
chmod +x "$T/bin/rm"

PATH="$T/bin:$PATH" VIDDIR="$T/vid" FFMPEG="$T/bin/ffmpeg" STREAM=1 bash "$CONV" > "$T/log" 2>&1
sed 's/^/  | /' "$T/log"

fail=0
check() { if [ "$1" = 0 ]; then echo "  [PASS] $2"; else echo "  [FAIL] $2"; fail=1; fi; }

out="$T/vid/clip.sbin"
want=$((4608 + FRAMES * FRAME))
size=$(stat -c %s "$out" 2>/dev/null || echo 0)
python3 - "$out" "$FRAMES" "$FRAME" <<'PY'
import struct, sys
p, n, fb = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    d = open(p, 'rb').read()
except OSError:
    sys.exit(1)
magic, width, total, ring = struct.unpack('<4Q', d[:32])
ok = magic == 0x5442435300000001 and width == 360 and total == n and ring == 256
ok = ok and len(d) == 4608 + n * fb
ok = ok and all(d[4608 + k * fb:4608 + (k + 1) * fb] == bytes([k % 251]) * fb for k in range(n))
print(f"  header: magic {magic:#x}, width {width}, frames {total}, ring {ring}; {len(d)} bytes")
sys.exit(0 if ok else 1)
PY
check $? "1: valid .sbin with every frame intact"

peak=$(sort -n "$T/peak" | tail -1); peak=${peak:-0}
[ "$size" -gt "$peak" ] && peak=$size
echo "  final $size bytes, peak directory use $peak bytes ($((peak * 100 / (want > 0 ? want : 1)))% of the final file)"
[ "$peak" -le $((want * 105 / 100)) ]
check $? "2: no second full-size copy during conversion"

echo; [ $fail = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $fail

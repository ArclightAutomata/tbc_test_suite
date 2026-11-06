#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Tests for tools/tbc_analyze.py on synthetic captures with known answers.

Each case renders the Analysis pattern at its documented geometry (see
the tbc_analyze.py docstring) as woven 724x480 frames - border, barcode
carrying a running field count, rulers, color strip - writes it
losslessly (FFV1) and checks what analyze() reports:

  A  long capture: 400 frames (800 fields) in order -> all 800 counted
  B  bottom-field-first weave -> still all in order (and reported)
  C  5 black frames before the pattern -> geometry from the pattern
  D  picture shifts 24 px right / 4 rows down mid-capture -> no fields lost
  E  rulers jittered uniformly by -2..+2 px per line -> RMS ~1.41 px
  F  one frame with its two fields genuinely swapped -> reported, not hidden

Run: python3 sim/analyze/test_analyze.py   (needs numpy + ffmpeg)
Exit code 0 = all checks passed, 1 = a check failed.
"""
import importlib.util, os, subprocess, sys, tempfile
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "tbc_analyze", os.path.join(HERE, "..", "..", "tools", "tbc_analyze.py"))
ta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ta)

W, H = 724, 480
RULERS = (180, 362, 544)


def field_image(count, polarity, jitter_rng=None):
    """One 724x240 field of the Analysis pattern (uint8 RGB)."""
    f = np.full((240, W, 3), 128, np.uint8)
    f[18:223, 44:681] = 128
    f[18:20, 44:681] = 255; f[221:223, 44:681] = 255     # top/bottom walls
    f[18:223, 44:46] = 255; f[18:223, 679:681] = 255     # left/right walls
    bits = [(count >> (15 - i)) & 1 for i in range(16)]
    blocks = [1, 0] + bits + [sum(bits) % 2, polarity]
    for i, v in enumerate(blocks):
        x = 64 + 28 * i
        f[28:45, x:x + 28] = 255 if v else 0
    for rx in RULERS:
        f[56:201, rx - 12:rx + 14] = 0
        for y in range(56, 201):
            d = 0 if jitter_rng is None else int(jitter_rng.integers(-2, 3))
            f[y, rx + d:rx + d + 2] = 255
    for i, c in enumerate(ta.BAR_RGB75):
        x0 = 64 + (676 - 64) * i // 7
        x1 = 64 + (676 - 64) * (i + 1) // 7
        f[204:219, x0:x1] = c
    return f


def weave(first, second, bottom_first=False):
    """Woven frame: `first` is the earlier field in time."""
    fr = np.empty((H, W, 3), np.uint8)
    even, odd = (second, first) if bottom_first else (first, second)
    fr[0::2] = even
    fr[1::2] = odd
    return fr


def shift(fr, dx, dy):
    out = np.zeros_like(fr)
    out[dy:, dx:] = fr[:H - dy, :W - dx]
    return out


def write(path, frames):
    p = subprocess.Popen(['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
                          '-s', f'{W}x{H}', '-r', '30000/1001', '-i', '-',
                          '-c:v', 'ffv1', '-pix_fmt', 'bgr0', path], stdin=subprocess.PIPE)
    for fr in frames:
        p.stdin.write(fr.tobytes())
    p.stdin.close()
    assert p.wait() == 0


def capture(n_frames, bottom_first=False, black_lead=0, shift_at=None, jitter=False, swap_frame=None):
    rng = np.random.default_rng(1) if jitter else None
    cache = {}
    def fld(k):
        if jitter:
            return field_image(k & 0xFFFF, k & 1, rng)
        if k not in cache:
            cache[k] = field_image(k & 0xFFFF, k & 1)
        return cache[k]
    for _ in range(black_lead):
        yield np.zeros((H, W, 3), np.uint8)
    for n in range(n_frames):
        a, b = fld(2 * n), fld(2 * n + 1)
        if n == swap_frame:
            a, b = b, a
        fr = weave(a, b, bottom_first)
        if shift_at is not None and n >= shift_at:
            fr = shift(fr, 24, 4)
        yield fr
        if not jitter:
            cache.pop(2 * n, None); cache.pop(2 * n + 1, None)


fail = False
def check(ok, what):
    global fail
    print(f"  [{'PASS' if ok else 'FAIL'}] {what}")
    if not ok:
        fail = True


def run(name, tmp, **kw):
    path = os.path.join(tmp, name + '.mkv')
    write(path, capture(**kw))
    r = ta.analyze(path)
    print(f"{name}: fields {r['fields']}" + (f", jitter rms {r['jitter']['rms_px']:.2f} px" if r['jitter'] else ''))
    return r


with tempfile.TemporaryDirectory() as tmp:
    f = run('A_long', tmp, n_frames=400)['fields']
    check(f['total'] == 800 and f['in_order'] == 799, "A: a 400-frame capture is analyzed in full (800 fields)")

    f = run('B_bff', tmp, n_frames=60, bottom_first=True)['fields']
    check(f['total'] == 120 and f['in_order'] == 119 and f['resync_jumps'] == 0 and f['dropped'] == 0,
          "B: a bottom-field-first capture reads in order")
    check(f.get('order') == 'bottom-first', "B: the field order is detected and reported")

    f = run('C_leadin', tmp, n_frames=55, black_lead=5)['fields']
    check(f['total'] == 110 and f['in_order'] == 109, "C: black lead-in frames do not set the geometry")

    f = run('D_shift', tmp, n_frames=60, shift_at=30)['fields']
    check(f['total'] == 120 and f['in_order'] == 119, "D: a mid-capture picture shift loses no fields")

    r = run('E_jitter', tmp, n_frames=40, jitter=True)
    check(r['jitter'] is not None and 1.30 <= r['jitter']['rms_px'] <= 1.55,
          "E: known +/-2 px ruler jitter measures ~1.41 px RMS")
    check(r['jitter'] is not None and 1.9 <= r['jitter']['p99_px'] <= 2.1 and 1.9 <= r['jitter']['max_px'] <= 2.1,
          "E: its p99 and max read 2 px")

    f = run('F_swap', tmp, n_frames=60, swap_frame=30)['fields']
    check(f['resync_jumps'] >= 1 and f['in_order'] < 119, "F: a genuinely swapped frame is reported")

print("\nRESULT: " + ("FAIL" if fail else "PASS"))
sys.exit(1 if fail else 0)

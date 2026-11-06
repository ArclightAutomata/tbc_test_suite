#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
TBC Test Suite - capture analysis tool.

Analyzes a capture of the DUT's output while the core displays the
"Analysis" test pattern, and reports quantitative TBC/frame-sync
behavior:

  * field sequence   - dropped / repeated / blended fields and their
                       cadence, from the per-field binary ID barcode
  * residual jitter  - per-line horizontal displacement statistics from
                       the vertical ruler lines (what per-line error the
                       DUT failed to remove)
  * color accuracy   - hue/saturation error of the 75% bar strip
  * levels           - white / gray / black levels from known regions

Usage:
    tbc_analyze.py capture.mkv [--json out.json] [--fields woven|progressive]
                               [--order auto|top|bottom] [--max-frames N]

The whole capture is analyzed (--max-frames limits it). Geometry is
found per frame, so a black lead-in or a picture shift mid-capture
does not throw the measurements off; frames with no recognizable
pattern are skipped and counted. For woven captures the field order
(which line parity carries the earlier field) is detected from the
barcode counts by majority over the capture, or forced with --order;
a frame whose fields really are swapped still shows up as an error.

Requires: python3, numpy, ffmpeg on PATH.
The capture should be an unscaled (or minimally processed) digitization
of the DUT output. Use the SAME capture device for every DUT you
compare: its input stage cancels out of relative results.

Pattern geometry (724x240 per field, defined in rtl/pattern_gen.sv):
  border      white rectangle x=[44,680] y=[18,222], 2px walls
  barcode     y=[28,44]: 20 blocks of 28px from x=64:
              [marker=1][marker=0][16-bit field count MSB first]
              [even parity][field polarity]
  rulers      2px white verticals on black at x=180,362,544, y=[56,200]
  color strip y=[204,218]: 7 bars of 75% colors, x=[64,676]
  background  50% gray
"""

import argparse, json, subprocess, sys
import numpy as np

REF_X = 724.0   # pattern coordinate space
REF_Y = 240.0
BAR_RGB75 = [   # white yellow cyan green magenta red blue at 75%
    (191,191,191),(191,191,0),(0,191,191),(0,191,0),
    (191,0,191),(191,0,0),(0,0,191)]

def read_video(path):
    """Yield RGB frames as HxWx3 uint8 arrays."""
    probe = subprocess.run(
        ['ffprobe','-v','error','-select_streams','v:0',
         '-show_entries','stream=width,height','-of','csv=p=0', path],
        capture_output=True, text=True).stdout.strip().split(',')
    w, h = int(probe[0]), int(probe[1])
    proc = subprocess.Popen(
        ['ffmpeg','-v','error','-i',path,'-f','rawvideo','-pix_fmt','rgb24','-'],
        stdout=subprocess.PIPE)
    frame_bytes = w*h*3
    while True:
        buf = proc.stdout.read(frame_bytes)
        if len(buf) < frame_bytes:
            break
        yield np.frombuffer(buf, np.uint8).reshape(h, w, 3)

def plausible(gray, geom):
    """Does this look like the Analysis pattern's border at all?
    (Rejects black/blank frames, where every pixel passes the
    relative brightness threshold, and tiny or partial detections.)"""
    h, w = gray.shape
    x0, y0, x1, y1 = geom
    if gray.max() - gray.min() < 80:
        return False
    if (gray > gray.max() * 0.85).mean() > 0.3:
        return False
    return (x1 - x0) >= 0.5 * w and (y1 - y0) >= 0.5 * h

def find_border(gray):
    """Locate the white pattern border; return (x0,y0,x1,y1) in capture px.

    Keys on near-full-white only (the border is 100% white) so the 75%
    patches and gray field cannot skew the geometry."""
    bright = gray > gray.max() * 0.85
    cols = bright.sum(0); rows = bright.sum(1)
    def edges(v, mincount):
        idx = np.where(v >= mincount)[0]
        return (idx[0], idx[-1]) if len(idx) else (0, len(v)-1)
    # border walls run the full height/width; interior white elements do
    # not reach the extremes, so outermost qualifying lines are the border
    x0, x1 = edges(cols, max(3, int(gray.shape[0]*0.3)))
    y0, y1 = edges(rows, max(3, int(gray.shape[1]*0.05)))
    return x0, y0, x1, y1

def px(geom, rx, ry):
    """Map pattern coords -> capture coords."""
    x0, y0, x1, y1 = geom
    return (x0 + (rx-44)/ (680-44) * (x1-x0),
            y0 + (ry-18)/ (222-18) * (y1-y0))

def read_barcode(gray, geom, rows):
    """Read the 20-block barcode from the given capture rows."""
    lo = gray.min(); hi = gray.max()
    thr_lo, thr_hi = lo + (hi-lo)*0.35, lo + (hi-lo)*0.65
    vals, conf = [], True
    for blk in range(20):
        cx = 64 + blk*28 + 14
        xs, _ = px(geom, cx, 0)
        m = np.median([gray[r, int(round(xs))] for r in rows])
        if m > thr_hi: vals.append(1)
        elif m < thr_lo: vals.append(0)
        else: vals.append(1 if m > (lo+hi)/2 else 0); conf = False
    if vals[0] != 1 or vals[1] != 0:
        return None, False, None
    bits = vals[2:18]
    count = 0
    for b in bits: count = (count<<1) | b
    parity_ok = (sum(bits) % 2) == vals[18]
    return count, conf and parity_ok, vals[19]

def ruler_positions(gray, geom):
    """Per-row subpixel x of each ruler line; returns dict ruler->list[(row,x)]."""
    out = {}
    # trim the band edges: transition rows corrupt the centroid
    _, yt = px(geom, 0, 62); _, yb = px(geom, 0, 194)
    for rx in (180, 362, 544):
        xs, _ = px(geom, rx, 0)
        xi = int(round(xs)); half = max(4, int((geom[2]-geom[0])*0.012))
        pos = []
        for r in range(int(yt), int(yb)):
            seg = gray[r, xi-half:xi+half+1].astype(float)
            if seg.max() - seg.min() < 60:   # no confident line here
                continue
            seg = seg - seg.min()
            s = seg.sum()
            if s < 30: continue
            c = (seg * np.arange(len(seg))).sum() / s
            pos.append((r, xi-half + c))
        out[rx] = pos
    return out

class Stats:
    """Running per-line jitter statistics (constant memory for any
    capture length): RMS, max, and a 0.01 px histogram for the p99."""
    BIN = 0.01
    def __init__(self):
        self.n = 0; self.sq = 0.0; self.mx = 0.0
        self.hist = np.zeros(10000, np.int64)        # up to 100 px
    def add(self, v):
        a = np.abs(v)
        self.n += len(a); self.sq += float((a * a).sum()); self.mx = max(self.mx, float(a.max()))
        np.add.at(self.hist, np.minimum((a / self.BIN).astype(int), len(self.hist) - 1), 1)
    def p99(self):
        c = np.cumsum(self.hist)
        return float(np.searchsorted(c, 0.99 * self.n) * self.BIN)

def analyze(path, weave='woven', order='auto', max_frames=0):
    frames_ids = []                 # per frame: (even-row field, odd-row field) or (field,)
    jit = Stats()
    col_sum = np.zeros((7, 3)); col_n = np.zeros(7)
    frames = no_pattern = 0
    for n, frame in enumerate(read_video(path)):
        if max_frames and n >= max_frames:
            break
        frames += 1
        gray = frame.mean(2)
        # geometry per frame: the DUT may blank, settle or shift the
        # picture; a frame without the pattern is skipped, not trusted
        geom = find_border(gray)
        if not plausible(gray, geom):
            no_pattern += 1
            continue
        # barcode rows for the two fields of a woven frame
        _, ybar0 = px(geom, 0, 28); _, ybar1 = px(geom, 0, 44)
        rows = range(int(ybar0)+1, int(ybar1))
        if weave == 'woven':
            frames_ids.append((read_barcode(gray, geom, [r for r in rows if r % 2 == 0]),
                               read_barcode(gray, geom, [r for r in rows if r % 2 == 1])))
        else:
            frames_ids.append((read_barcode(gray, geom, list(rows)),))
        # jitter from rulers (whole frame), in pattern px
        scale = (680-44) / (geom[2]-geom[0])
        for rx, pos in ruler_positions(gray, geom).items():
            if len(pos) > 20:
                xs = np.array([p[1] for p in pos])
                jit.add((xs - np.median(xs)) * scale)
        # color strip
        _, yc0 = px(geom, 0, 206); _, yc1 = px(geom, 0, 216)
        for i in range(7):
            cx = 64 + (676-64)*(2*i+1)/14
            xs, _ = px(geom, cx, 0)
            patch = frame[int(yc0):int(yc1), int(xs)-3:int(xs)+4].reshape(-1,3).mean(0)
            col_sum[i] += patch; col_n[i] += 1

    # ---- field order (woven): which line parity carries the earlier
    # field. Decided once for the whole capture by majority, so a DUT
    # that swaps the fields of individual frames is still reported. ----
    def fid(f): return f[0] if f and f[0] is not None else None
    detected = None
    if weave == 'woven':
        top = bot = 0
        for e, o in frames_ids:
            a, b = fid(e), fid(o)
            if a is None or b is None: continue
            if (b - a) & 0xFFFF == 1: top += 1
            elif (a - b) & 0xFFFF == 1: bot += 1
        detected = 'bottom-first' if bot > top else 'top-first'
        use = {'top': 'top-first', 'bottom': 'bottom-first'}.get(order, detected)
        field_seq = []
        for e, o in frames_ids:
            field_seq += [o, e] if use == 'bottom-first' else [e, o]
    else:
        use = 'progressive'
        field_seq = [f[0] for f in frames_ids]

    # ---- field sequence analysis ----
    ids = [f[0] for f in field_seq if f and f[0] is not None]
    drops = repeats = ok = bad = 0
    for a, b in zip(ids, ids[1:]):
        d = (b - a) & 0xFFFF
        if d == 1: ok += 1
        elif d == 0: repeats += 1
        elif d < 16: drops += d - 1; ok += 1
        else: bad += 1
    blends = sum(1 for f in field_seq if f and f[0] is not None and not f[1])

    # ---- jitter stats ----
    jit_out = (dict(rms_px=float(np.sqrt(jit.sq / jit.n)), p99_px=jit.p99(), max_px=jit.mx)
               if jit.n else None)

    # ---- color ----
    col = []
    for i in range(7):
        if not col_n[i]: continue
        got = col_sum[i] / col_n[i]; ref = np.array(BAR_RGB75[i], float)
        def huesat(c):
            r,g,b = c; mx,mn = max(c), min(c)
            sat = 0 if mx == 0 else (mx-mn)/mx
            if mx == mn: return 0, sat
            if mx == r: h = (g-b)/(mx-mn) % 6
            elif mx == g: h = (b-r)/(mx-mn) + 2
            else: h = (r-g)/(mx-mn) + 4
            return h*60, sat
        h1,s1 = huesat(got); h2,s2 = huesat(ref)
        if s2 < 0.05:   # achromatic reference (white bar): hue undefined
            col.append(dict(bar=i, dhue_deg=None, dsat=round(s1-s2,3)))
        else:
            dh = ((h1-h2+180) % 360) - 180
            col.append(dict(bar=i, dhue_deg=round(dh,1), dsat=round(s1-s2,3)))

    return dict(frames=dict(total=frames, no_pattern=no_pattern),
                fields=dict(total=len(ids), in_order=ok, repeats=repeats,
                            dropped=drops, resync_jumps=bad, blended=blends,
                            order=use, order_detected=detected),
                jitter=jit_out, color=col)

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('capture')
    ap.add_argument('--json')
    ap.add_argument('--fields', choices=['woven','progressive'], default='woven')
    ap.add_argument('--order', choices=['auto','top','bottom'], default='auto',
                    help='woven field order: which line parity is the earlier field')
    ap.add_argument('--max-frames', type=int, default=0, help='stop after N frames (0 = all)')
    args = ap.parse_args()
    r = analyze(args.capture, args.fields, args.order, args.max_frames)
    if args.json:
        json.dump(r, open(args.json,'w'), indent=2)
    print(json.dumps(r, indent=2))

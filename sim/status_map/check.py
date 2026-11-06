#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Status-bit map check for TBC_Test_Suite.sv.

The OSD's settings live in a 128-bit status word; each menu row in
CONF_STR claims a bit range (O[hi:lo] / O[b] / T[b] / R[b]) and the
Verilog reads those ranges back as status[...] slices. Nothing in the
toolchain checks that the two agree, so a typo or overlap would just
silently misbehave. This checks:

  1  no two menu rows claim overlapping bits (T[0]/R[0] may share bit 0)
  2  every O[] row has enough bits for its options
  3  no field crosses the 63/64 word boundary
  4  reserved headroom bits (STATUS-RESERVED comment) are claimed by no row
  5  every status[...] slice in the code - and the preset helpers'
     s[...] / apply_preset[...] / status_in_r[...] slices - matches a
     menu row's range exactly
  6  every `wire [N:0] x = status[hi:lo];` is exactly as wide as its slice

Run: python3 sim/status_map/check.py      exit 0 = pass, 1 = fail
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "TBC_Test_Suite.sv")
text = open(SRC).read()

fail = False
def check(ok, what):
    global fail
    print(f"  [{'PASS' if ok else 'FAIL'}] {what}")
    if not ok:
        fail = True

# ---- menu rows ----
conf = text[text.index("localparam CONF_STR"):]
conf = conf[:conf.index("};")]
rows = []   # (kind, lo, hi, name, n_options, line)
for m in re.finditer(r'"([^"]*)"', conf):
    s = m.group(1)
    r = re.match(r'^(?:[HhDdP]\d+)*([OTR])\[(\d+)(?::(\d+))?\],([^,;]*)(.*)$', s)
    if not r:
        continue
    kind, a, b, name, rest = r.group(1), int(r.group(2)), r.group(3), r.group(4), r.group(5)
    hi, lo = (a, int(b)) if b is not None else (a, a)
    nopt = len([o for o in rest.rstrip(';').split(',') if o != '']) if kind == 'O' else 0
    rows.append((kind, lo, hi, name, nopt, s))

print(f"{len(rows)} menu rows")

# 1 overlaps
owner = {}
overlap = []
for kind, lo, hi, name, nopt, s in rows:
    for bit in range(lo, hi + 1):
        if bit in owner and not (bit == 0 and {owner[bit][0], kind} <= {'T', 'R'}):
            overlap.append(f"bit {bit}: {owner[bit][1]} / {name}")
        owner.setdefault(bit, (kind, name))
for o in overlap:
    print("    overlap", o)
check(not overlap, "1: no overlapping menu rows")

# 2 widths
narrow = [f"{name}: {nopt} options in {hi - lo + 1} bit(s)" for kind, lo, hi, name, nopt, s in rows
          if kind == 'O' and nopt > (1 << (hi - lo + 1))]
for n in narrow:
    print("    too narrow:", n)
check(not narrow, "2: every field has room for its options")

# 3 word boundary
cross = [name for kind, lo, hi, name, nopt, s in rows if lo <= 63 < hi]
check(not cross, "3: no field crosses bit 63/64" + (f" ({', '.join(cross)})" if cross else ""))

# 4 reservations
res = set()
for m in re.finditer(r'STATUS-RESERVED:([0-9 ]+)', text):
    res |= {int(x) for x in m.group(1).split()}
taken = sorted(b for b in res if b in owner)
check(not taken, f"4: {len(res)} reserved headroom bits unclaimed" + (f" (claimed: {taken})" if taken else ""))

# 5 code slices
ranges = {(lo, hi) for kind, lo, hi, name, nopt, s in rows}
code = text.replace(conf, "")
bad = []
for m in re.finditer(r'\b(status|s|apply_preset|status_in_r)\[(\d+)(?::(\d+))?\]', code):
    a, b = int(m.group(2)), m.group(3)
    hi, lo = (a, int(b)) if b is not None else (a, a)
    if (lo, hi) not in ranges:
        line = code.count("\n", 0, m.start()) + 1
        bad.append(f"{m.group(0)} (code line ~{line})")
for x in bad:
    print("    no matching menu row:", x)
check(not bad, "5: every status slice in the code matches a menu row")

# 6 wire widths
wbad = []
for m in re.finditer(r'wire\s*\[(\d+):0\]\s*(\w+)\s*=\s*status\[(\d+):(\d+)\]\s*;', code):
    w, name, hi, lo = int(m.group(1)) + 1, m.group(2), int(m.group(3)), int(m.group(4))
    if w != hi - lo + 1:
        wbad.append(f"{name}: wire {w} bits, slice {hi - lo + 1}")
for x in wbad:
    print("    width mismatch:", x)
check(not wbad, "6: status wires are as wide as their slices")

used = len(owner)
print(f"bits claimed {used}, reserved {len(res)}, free {128 - used - len(res)} of 128")
print("\nRESULT: " + ("FAIL" if fail else "PASS"))
sys.exit(1 if fail else 0)

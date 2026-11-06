#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""VCR preset table check.

Reads CONF_STR and apply_preset() from TBC_Test_Suite.sv and resolves
each preset's stamped values to the OSD labels they show, then compares
against the intended mix below. Catches a preset pointing at the wrong
level after a row gains or reorders values. Exit 1 on any mismatch.
"""
import re, sys, pathlib

src = (pathlib.Path(__file__).resolve().parents[2] / "TBC_Test_Suite.sv").read_text()

ROWS = {  # apply_preset variable -> OSD row name
    "roll_v": "Picture Roll", "tear_v": "Tearing", "jit_v": "Jitter",
    "flag_v": "Flagwaving", "skew_v": "Skew Error", "wow_v": "Wow",
    "flut_v": "Flutter", "drop_v": "Dropouts", "hsw_v": "Head Switch",
    "head_v": "Video Heads", "doc_v": "Dropout Comp",
}
WANT = {  # rows not listed are at their first (default) value
    "Good VHS":     {"Head Switch": "Subtle", "Flutter": "Typical", "Jitter": "Faint",
                     "Dropout Comp": "On"},
    "Worn VHS":     {"Head Switch": "Typical", "Flutter": "Typical", "Jitter": "Faint",
                     "Flagwaving": "Subtle", "Dropouts": "Light", "Dropout Comp": "On"},
    "EP Rental":    {"Head Switch": "Typical", "Flutter": "Typical", "Jitter": "Faint",
                     "Flagwaving": "Subtle", "Dropouts": "Moderate", "Tearing": "Mild",
                     "Skew Error": "Bot Heavy", "Dropout Comp": "On"},
    "Failing Deck": {"Head Switch": "Typical", "Flutter": "Typical", "Jitter": "Typical",
                     "Flagwaving": "Subtle", "Dropouts": "Light", "Tearing": "Moderate",
                     "Skew Error": "Bot Heavy", "Wow": "Typical", "Dropout Comp": "On",
                     "Video Heads": "Dirty"},
    "Damaged":      {"Head Switch": "Unstable", "Flutter": "Fast", "Jitter": "Heavy",
                     "Flagwaving": "Moderate", "Dropouts": "Heavy", "Tearing": "Severe",
                     "Skew Error": "Severe", "Wow": "Deep", "Picture Roll": "Drift",
                     "Video Heads": "Dirty"},
}

labels = {}
for m in re.finditer(r'"P2O\[\d+(?::\d+)?\],([^,]+),([^;"]+);', src):
    labels[m.group(1)] = m.group(2).split(",")

body = src[src.index("function [127:0] apply_preset"):src.index("endfunction")]
cases = {int(n): dict((k, int(v)) for k, v in re.findall(r"(\w+_v)=\d+'[db](\d+)", txt))
         for n, txt in re.findall(r"3'd(\d+): begin(.*?)\n\t\t\tend", body, re.S)}

ok = True
for idx, name in enumerate(labels["VCR Preset"]):
    if idx == 0:
        continue
    got = {ROWS[k]: labels[ROWS[k]][v] for k, v in cases.get(idx, {}).items()}
    want = {r: WANT.get(name, {}).get(r, labels[r][0]) for r in ROWS.values()}
    bad = {r: (got.get(r), want[r]) for r in want if got.get(r) != want[r]}
    print(f"  [{'FAIL' if bad or name not in WANT else 'PASS'}] {name}: " +
          ", ".join(f"{r} {got[r]}" for r in ROWS.values() if got.get(r) != labels[r][0]))
    for r, (g, w) in bad.items():
        print(f"         {r}: stamps {g}, want {w}")
    ok &= not bad and name in WANT
missing = set(WANT) - set(labels["VCR Preset"])
if missing:
    print("  [FAIL] presets missing from the menu:", missing); ok = False
print("\nRESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)

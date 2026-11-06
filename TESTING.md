# How This Core Is Verified

Every change is checked two ways: by simulation tests that run the real
RTL against reference models, and on hardware, with a camera pointed at a
CRT and a capture of the clean HDMI output. Simulation proves the numbers
(rates, levels, timing, bit-exactness). The CRT proves what a real
display does with the signal, which no simulation of the core can tell
you.

## Simulation tests

`make test` (from the repo root) runs all 18 tests and exits non-zero if
any fail; GitHub Actions runs the same command on every push. See
"Running the Tests" in the README for setup. Each test's own header
explains its pass criteria in detail.

| Test | What it checks |
|---|---|
| `status_map` | OSD status-bit map: every `CONF_STR` row matches the code, no overlapping bits, headroom left |
| `levels` | Jitter and Wow level sizes (peak, RMS, rate, zero mean); every VCR preset sets the intended menu labels |
| `dropout` | Dropout rates per level, short-weighted lengths, onset fade, dark tail, hsync reach, sparkle texture, crease placement |
| `heads` | Video Heads: head flips at the head switch, per-head snow and speck rates, clogged-head snow and sync removal, seeded replay |
| `out_stage` | Analog output stage: bit-identical when no defect is active, dropout blending, head effects, Dropout Comp delay line (NTSC/PAL, S-Video/Composite) |
| `sync` | Composite sync timing against the NTSC and PAL standards |
| `skew` | Top Heavy and Bottom Heavy skew are distinct shapes |
| `headswitch` | Head-switch step and its exponential pull-in |
| `err_rng` | The timing errors draw independent random numbers |
| `enc_rng` | Encoder noise is independent of tearing |
| `repro` | The same seed gives the same errors, whenever the OSD is closed |
| `chroma_delay` | Y/C delay doesn't change hue; Composite luma/chroma split is exact |
| `modstair` | Modulated Staircase/Ramp chroma at burst phase and amplitude |
| `mandel` | Mandelbrot pattern against a fixed-point reference |
| `osd_button` | Button B reopens the OSD |
| `stream` | SD streaming: the core and the real daemon, in a closed loop |
| `convert` | `tbc_video_convert.sh STREAM=1`, run on the host |
| `analyze` | `tools/tbc_analyze.py` on synthetic captures |

A bug fix normally comes with a test that fails on the old code and
passes on the new one.

## Hardware checks

**Rig:** MiSTer Pi → MikeS11-style active Y/C adapter (S-Video and Composite) →
Pelco PMCS15A CRT monitor, filmed by a camera. The HDMI output goes to a
USB capture device. A camera is used rather than an analog capture card
because a capture card's digitizer can quietly correct the very timing
errors under test.

**Method:** after each batch of changes, the core is built with Quartus,
loaded on the MiSTer, and swept through the menu:

1. The OSD is driven remotely with `tools/osd.sh` (MiSTer_Batch_Control
   over ssh). Every menu state is read back from the HDMI capture before
   the next step, so a missed key press can't silently skew the results.
2. Each pattern, and each value of each error row, is selected on its own
   from a clean baseline. Presets are checked against the rows they
   write.
3. `tools/capture.sh` grabs one HDMI frame and eight CRT frames (~2.7 s)
   per step; moving errors also get a short video clip.
4. The frames are assembled into contact sheets and reviewed for the
   expected effect, regressions, and the TV's sync and color behavior.

Quartus timing must be met on every build (setup slack > 0 on all
clocks).

## Latest results

**Build:** v261105 (the version shown in the OSD footer), the same
logic as the first public release, 20261106. Timing met (worst setup
slack +0.44 ns). Full sweep: 214 menu steps, interlaced and
progressive, every step reached and captured.

| Area | Result |
|---|---|
| Simulation | 18 of 18 tests pass |
| All 17 patterns (interlaced and progressive) | Correct on CRT and HDMI |
| Timing errors, each level | Expected effect on the CRT; HDMI stays clean |
| Dropouts, Dropout Comp | Light to Stress step up in rate; short white streaks with dark tails; Comp reduces them to faint slivers with a brief loss of color |
| Video Heads | Dirty: sparse specks. Very Dirty: snow on alternate fields. One Clogged: the CRT loses vertical lock every other field. Both Clogged: full snow |
| VCR presets | Step up cleanly from Good VHS to Damaged; Damaged keeps some color |
| Encoding errors, Advanced page | As designed |
| OSD | Every page fits without scrolling; Factory Defaults and preset write-back cover every row |

## Known behavior (not bugs)

- **A CRT hides slow errors.** Its sync circuits follow slow, smooth
  errors (small rolls, skew), so the tube can look fine while the signal
  carries the error. The HDMI scaler often reveals what the CRT hides.
- **Errors pause while the OSD is open**, so the menu is always readable
  on HDMI.
- **Snow is faint on black in S-Video.** Black is the lowest level the
  output can produce, so only the bright half of the noise shows there.
- **Pulse Cross Enhanced with Picture Roll shows two bands.** The thin
  locked band is the painted sync marker; the rolling band is the true
  blanking interval, which travels with the picture. That separation is
  real, and the cross shows it.

## Lessons from development

- **The missing color burst.** `sys_top` forced the analog output to
  black outside the active picture, erasing the core-encoded burst. The
  HDMI path looked perfect because it taps the signal before that gate.
  Two marked one-line changes to `sys/sys_top.v` fix it (see
  `framework-mods.patch`).
- **Features narrower than a pixel vanish on HDMI.** The scaler samples
  once per pixel (4 samples), so patterns are drawn in whole-pixel units.

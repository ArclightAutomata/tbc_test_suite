# Roadmap

Planned features and open verification items, roughly ordered by value.
Completed items move to the git log.

## Features

- **CIRC — electronic circle overlay** (from the B&K 1251B / Promax
  GV-698 review): a circle insertable over any pattern for instant
  CRT geometry/aspect judgment on camera. Needs distance-from-center
  math the patterns don't currently have (multiplier or incremental
  circle algorithm).
- **Antipal (E1/E2)**: PAL-specific pattern with deliberately wrong V
  phase — exercises a PAL decoder's delay line and V-switch. Only
  meaningful once PAL DUTs are on the bench.
- **NTC-7 Composite / Combination as VITS** (from the Tektronix
  primer review): insert a one-line combination test signal in the
  vertical interval using the existing VBI machinery — enables
  in-service measurement through a DUT alongside program video.
- **Noise flutter**: real flutter has a broadband "scrape" component;
  a noise-modulated flutter mode would complement the 10/30 Hz sine
  modes (at the cost of single-frequency measurability).
- **SC-H Error option** (after SC-H calibration, see below): an
  Encoding Errors row that offsets the subcarrier-to-horizontal phase
  from the calibrated 0 deg (e.g. +45 / +90 / 180 deg, maybe a slow
  drift) on a clean signal. Tests whether frame synchronizers, TBCs and
  switchers detect color framing (NTSC 4-field / PAL 8-field) correctly:
  a wrong color-frame pick on a drop/repeat shows as a hue flash or a
  ~140 ns half-cycle H jump at the edit. Implementation is small (add a
  phase offset to the encoder's run-start SCH_INIT), but it is only
  meaningful once the absolute SC-H is measured and set to 0 deg.
- **Off-rate vertical modes**: the old constant-field-length roll
  behavior (261/263-line fields) retired by the roll rework was a
  legitimate frame-synchronizer stress (forces steady drop/repeat
  cadence); could return as extra Picture Roll values.

- ~~OSD-integrated "Convert video to .BIN"~~ — investigated 2026-07-09,
  **rejected**: core menus have no ARM-exec hook (F-rows stream file
  bytes to the FPGA; S-rows block-mount), the core never learns the
  selected filename, and there is no progress/error channel back to
  the OSD without new plumbing. `tools/tbc_autoconvert.sh` (background
  watcher) ships instead.

## Signal fidelity / correctness (queued 2026-11-03)

- **SC-H phase calibration**: the subcarrier phase now restarts at every
  run start, so SC-H is constant and reproducible, but its absolute
  value is arbitrary (SCH_INIT = 0 in yc_encoder). Measure the burst
  phase at the 50% point of the field-1 line-10 sync edge (CXADC
  capture, or a sim that models both pipelines) and set SCH_INIT for
  0 deg. The severity Sweep deliberately freezes with the OSD open and
  resumes (by design).

## Verification debt

- **CC decode end-to-end**: the line-21 waveform is verified bit-exact,
  but no decoder has read it yet. Route: a VBI-capable capture
  (`/dev/vbi0` + zvbi/ccextractor) or any consumer TV with a CC button
  downstream — the Pelco PMCS15A has no CC decoder.
- **WFM amplitude calibration**: when the hardware waveform monitor is
  on the bench, check the Mod Staircase chroma sits at 40 IRE p-p and
  the 12.5T pulse peaks at 100 IRE composite. In the digital domain
  sim/modstair confirms the staircase chroma at burst phase and burst
  amplitude (77 vs 75 codes p-p); the analog chain is unmeasured.
- **Bar-edge colored seams re-examination**: the 2026-07-07 verdict
  ("inherent to unfiltered chroma") was A/B'd against the framework
  clone, which may share the since-fixed Y/UV skew — the comparison
  was not independent. Re-check Sharp-mode seams on the WFM.

## Constraints to remember

- The OSD bit map (comment block above CONF_STR in TBC_Test_Suite.sv)
  gives each field reserved headroom directly above it; Pattern is 5 bits
  (status[7:3], 17 of 32 values used). Grow a field into its reserved
  bits, never move it, and run `make status_map` after any menu change.

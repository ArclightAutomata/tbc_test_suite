# SPDX-License-Identifier: GPL-2.0-or-later
# Verilator testbenches.
#   make test                    every test below; prints a summary, exits
#                                non-zero if any failed (also `make test`
#                                from the repo root; this is what CI runs)
#   make test JOBS=8             run tests in parallel (default: CPU count)
# Or one at a time, from this directory:
#   make dropout                 (60 s of video, seed 0)
#   make dropout ARGS="+seconds=120 +seed=7"
#   make chroma_delay            (Y/C delay must not change hue)
#   make osd_button              (Button B must reopen the OSD)
#   make enc_rng                 (encoder noise independent of tearing)
#   make stream                  (SD streaming: core + real daemon loop)
#   make repro                   (same seed -> same errors, any close time)
#   make analyze                 (tools/tbc_analyze.py on synthetic captures)
#   make skew                    (Top/Bottom Heavy skew are distinct shapes)
#   make headswitch              (head-switch step + exponential pull-in)
#   make convert                 (tbc_video_convert.sh STREAM=1, host-side)
#   make out_stage               (dropout level on the Composite scale)
#   make sync                    (composite sync vs NTSC/PAL standards)
#   make err_rng                 (timing errors draw independent randoms)
#   make modstair                (WFM pattern chroma at burst phase/amplitude)
#   make status_map              (OSD bit map: CONF_STR vs code, overlaps, headroom)
#   make mandel                  (Mandelbrot pattern vs a fixed-point reference)
#   make levels                  (Jitter/Wow level sizes; VCR presets -> intended labels)
#   make heads                   (Video Heads: dirty/clogged head snow, specks, sync removal)
#
# Builds land in sim/obj_*/ (gitignored).

RTL := ../rtl
VFLAGS := --cc --exe --build -O3 -Wno-fatal -Wno-WIDTH -Wno-UNUSED

TESTS := status_map dropout chroma_delay osd_button enc_rng stream repro analyze \
	skew headswitch convert out_stage sync err_rng modstair mandel levels heads
JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)

# Each test runs in its own make (logs in obj_logs/<test>.log); a failure
# doesn't stop the others. The summary lists PASS/FAIL per test.
test:
	@mkdir -p obj_logs; rm -f obj_logs/*.status
	@echo "running $(words $(TESTS)) tests ($(JOBS) at a time; logs in sim/obj_logs/)"
	@printf '%s\n' $(TESTS) | xargs -P $(JOBS) -I{} sh -c \
		'start=$$(date +%s); if $(MAKE) --no-print-directory {} > obj_logs/{}.log 2>&1; then r=PASS; else r=FAIL; fi; \
		 echo "$$r $$(( $$(date +%s) - start ))s" > obj_logs/{}.status; printf "  %-4s %-13s %ss\n" $$r {} $$(( $$(date +%s) - start ))'
	@fails=$$(grep -l FAIL obj_logs/*.status 2>/dev/null | sed 's|obj_logs/||; s|\.status||' | tr '\n' ' '); \
	 if [ -n "$$fails" ]; then echo "FAILED: $$fails(see sim/obj_logs/<test>.log)"; exit 1; \
	 else echo "all $(words $(TESTS)) tests passed"; fi

.PHONY: test dropout chroma_delay osd_button enc_rng stream repro analyze skew headswitch convert out_stage sync err_rng modstair status_map mandel levels heads clean

dropout:
	verilator $(VFLAGS) --top-module tb_dropout --Mdir obj_dropout \
		dropout/tb_dropout.sv $(RTL)/error_dropout.sv $(RTL)/prng.sv \
		dropout/main.cpp
	./obj_dropout/Vtb_dropout $(ARGS)

chroma_delay:
	verilator $(VFLAGS) --top-module yc_encoder --Mdir obj_chroma_delay \
		$(RTL)/yc_encoder.sv $(RTL)/sine_lut.sv $(RTL)/prng.sv chroma_delay/main.cpp
	./obj_chroma_delay/Vyc_encoder $(ARGS)

osd_button:
	verilator $(VFLAGS) --top-module osd_button --Mdir obj_osd_button \
		$(RTL)/osd_button.sv osd_button/main.cpp
	./obj_osd_button/Vosd_button $(ARGS)

enc_rng:
	verilator $(VFLAGS) --top-module tb_enc_rng --Mdir obj_enc_rng \
		enc_rng/tb_enc_rng.sv $(RTL)/yc_encoder.sv $(RTL)/error_tear.sv \
		$(RTL)/prng.sv $(RTL)/sine_lut.sv enc_rng/main.cpp
	./obj_enc_rng/Vtb_enc_rng $(ARGS)

stream:
	verilator $(VFLAGS) --top-module video_player --Mdir obj_stream \
		$(RTL)/video_player.sv stream/main.cpp
	./obj_stream/Vvideo_player $(ARGS)

REPRO_RTL := $(RTL)/ntsc_timing.sv $(RTL)/error_injector.sv $(RTL)/error_roll.sv \
	$(RTL)/error_tear.sv $(RTL)/error_flagwave.sv $(RTL)/error_skew.sv $(RTL)/error_wow.sv \
	$(RTL)/error_headswitch.sv $(RTL)/error_jitter.sv $(RTL)/error_dropout.sv \
	$(RTL)/yc_encoder.sv $(RTL)/prng.sv $(RTL)/sine_lut.sv

repro:
	verilator $(VFLAGS) --top-module tb_repro --Mdir obj_repro \
		repro/tb_repro.sv $(REPRO_RTL) repro/main.cpp
	./obj_repro/Vtb_repro $(ARGS)

skew:
	verilator $(VFLAGS) --top-module error_skew --Mdir obj_skew \
		$(RTL)/error_skew.sv skew/main.cpp
	./obj_skew/Verror_skew $(ARGS)

headswitch:
	verilator $(VFLAGS) --top-module error_headswitch --Mdir obj_headswitch \
		$(RTL)/error_headswitch.sv headswitch/main.cpp
	./obj_headswitch/Verror_headswitch $(ARGS)

out_stage:
	verilator $(VFLAGS) --top-module out_stage --Mdir obj_out_stage \
		$(RTL)/out_stage.sv out_stage/main.cpp
	./obj_out_stage/Vout_stage $(ARGS)

SYNC_SRC := sync/tb_sync.sv sync/framework_csync.v $(RTL)/ntsc_timing.sv sync/main.cpp

sync:
	verilator $(VFLAGS) --top-module tb_sync --Mdir obj_sync $(SYNC_SRC)
	./obj_sync/Vtb_sync $(ARGS)

ERR_RNG_SRC := err_rng/tb_err_rng.sv $(RTL)/error_injector.sv $(RTL)/error_roll.sv \
	$(RTL)/error_tear.sv $(RTL)/error_flagwave.sv $(RTL)/error_skew.sv $(RTL)/error_wow.sv \
	$(RTL)/error_headswitch.sv $(RTL)/error_jitter.sv $(RTL)/error_dropout.sv \
	$(RTL)/prng.sv $(RTL)/sine_lut.sv err_rng/main.cpp

err_rng:
	verilator $(VFLAGS) $(EXTRA) --top-module tb_err_rng --Mdir obj_err_rng $(ERR_RNG_SRC)
	./obj_err_rng/Vtb_err_rng $(ARGS)

modstair:
	verilator $(VFLAGS) -I$(RTL) --top-module tb_modstair --Mdir obj_modstair \
		modstair/tb_modstair.sv $(RTL)/pattern_gen.sv $(RTL)/logo_rom.sv $(RTL)/yc_encoder.sv \
		$(RTL)/prng.sv $(RTL)/sine_lut.sv modstair/main.cpp
	cd .. && sim/obj_modstair/Vtb_modstair $(ARGS)   # logo_rom loads rtl/logo_rom.mem

convert:
	bash convert/test_convert.sh

status_map:
	python3 status_map/check.py

mandel:
	verilator $(VFLAGS) --top-module mandel_gen --Mdir obj_mandel \
		$(RTL)/mandel_gen.sv $(RTL)/sine_lut.sv mandel/main.cpp
	verilator $(VFLAGS) -GSTART_U=655360 --top-module mandel_gen --Mdir obj_mandel_deep \
		$(RTL)/mandel_gen.sv $(RTL)/sine_lut.sv mandel/main.cpp
	verilator $(VFLAGS) -GSTART_U=131072 --top-module mandel_gen --Mdir obj_mandel_end \
		$(RTL)/mandel_gen.sv $(RTL)/sine_lut.sv mandel/main.cpp
	cd obj_mandel && ./Vmandel_gen
	cd obj_mandel_deep && ./Vmandel_gen +deep
	cd obj_mandel_end && ./Vmandel_gen +end

heads:
	verilator $(VFLAGS) --top-module error_head --Mdir obj_heads \
		$(RTL)/error_head.sv $(RTL)/prng.sv heads/main.cpp
	./obj_heads/Verror_head $(ARGS)

levels:
	verilator $(VFLAGS) --top-module tb_levels --Mdir obj_levels \
		levels/tb_levels.sv $(RTL)/error_jitter.sv $(RTL)/error_wow.sv $(RTL)/sine_lut.sv levels/main.cpp
	./obj_levels/Vtb_levels $(ARGS)
	python3 levels/presets.py

# first python3 on the PATH that has numpy (Homebrew's may not)
PY ?= $(shell for p in python3 /usr/bin/python3; do $$p -c 'import numpy' 2>/dev/null && echo $$p && break; done)

analyze:
	$(PY) analyze/test_analyze.py

clean:
	rm -rf obj_*

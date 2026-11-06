// SPDX-License-Identifier: GPL-2.0-or-later
// Jitter and Wow level testbench (Verilator).
//
// Every OSD level must produce its documented size (and, for Wow, rate).
// Guards the renumbering that slotted Jitter Faint below Light and Wow
// Gentle below Slow: each old level must keep its old behavior under its
// new number. 1 sample = 17.46 ns; NTSC line rate 15734 Hz.
//   Jitter  peak |offset| and RMS (uniform: RMS = peak / sqrt(3))
//   Wow     peak line-length change, cycle length in lines, and the
//           integrated timebase drift that a TBC has to absorb
// Exit code 0 = all checks passed, 1 = a check failed.
#include "Vtb_levels.h"
#include "verilated.h"
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <algorithm>

static Vtb_levels *tb;
static uint32_t lfsr = 0x12345678;
static uint32_t rnd() { lfsr ^= lfsr << 13; lfsr ^= lfsr >> 17; lfsr ^= lfsr << 5; return lfsr; }
static void tick() { tb->clk = 1; tb->eval(); tb->clk = 0; tb->eval(); }
static void line() {
	tb->rng = rnd(); tb->new_line = 1; tick();
	tb->new_line = 0; tick(); tick();
}
static void reset() {
	tb->reset = 1; for (int i = 0; i < 8; i++) tick();
	tb->reset = 0; tick();
}
static bool fail = false;
static void check(bool ok, const char *what) {
	printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
	fail |= !ok;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	tb = new Vtb_levels;
	tb->clk = 0; tb->new_line = 0; tb->jit_mode = 0; tb->wow_mode = 0; tb->rng = 0;
	reset();

	struct { const char *name; int peak; } jl[] = {{"Off", 0}, {"Faint", 4}, {"Light", 16}, {"Typical", 32}, {"Heavy", 64}};
	printf("Jitter (60000 lines per level)\n");
	for (int m = 0; m <= 4; m++) {
		tb->jit_mode = m; reset();
		int mx = 0; double sq = 0; const int N = 60000;
		for (int i = 0; i < N; i++) {
			line();
			int o = (int16_t)(tb->jit_off << 3) >> 3;
			mx = std::max(mx, std::abs(o)); sq += double(o) * o;
		}
		double rms = sqrt(sq / N), want = jl[m].peak / sqrt(3.0);
		printf("  %-8s peak %3d samples (%4.0f ns)  RMS %5.1f samples (%4.0f ns)\n",
		       jl[m].name, mx, mx * 17.46, rms, rms * 17.46);
		char msg[96];
		snprintf(msg, sizeof msg, "%s: peak %d (want %d), RMS within 10%% of %.1f", jl[m].name, mx, jl[m].peak, want);
		check(mx == jl[m].peak && fabs(rms - want) <= 0.1 * want + 0.01, msg);
	}
	tb->jit_mode = 0;

	// peak = (max - min) / 2 of the per-line change; hz from the cycle length
	struct { const char *name; double peak, hz; } wl[] = {
		{"Off", 0, 0}, {"Gentle", 2, 1.5}, {"Slow", 16, 0.5}, {"Typical", 16, 1.5}, {"Deep", 32, 0.5}};
	printf("Wow (two slow cycles per level)\n");
	for (int m = 0; m <= 4; m++) {
		tb->wow_mode = m; reset();
		const int N = 2 * 31468 + 100;
		int lo = 0, hi = 0, prev = 0, first = -1, last = -1, cycles = 0;
		double run = 0;   // per-line change summed over whole cycles
		static int v_[2 * 31468 + 100];
		for (int i = 0; i < N; i++) {
			line();
			int v = (int16_t)(tb->wow_llm << 3) >> 3;
			v_[i] = v;
			lo = std::min(lo, v); hi = std::max(hi, v);
			if (i > 0 && prev < 0 && v >= 0) { if (first < 0) first = i; else { last = i; cycles++; } }
			prev = v;
		}
		for (int i = first; cycles && i < last; i++) run += v_[i];
		double mean = cycles ? run / (last - first) : 0;
		// timebase drift: integrate over whole cycles, the mean removed
		double pos = 0, plo = 0, phi = 0;
		for (int i = first; cycles && i < last; i++) {
			pos += v_[i] - mean; plo = std::min(plo, pos); phi = std::max(phi, pos);
		}
		double peak = (hi - lo) / 2.0;
		double hz = cycles ? 15734.0 * cycles / (last - first) : 0;
		double drift_us = (phi - plo) / 2 * 17.46e-3;
		printf("  %-8s peak %4.1f samples/line (%.3f%% speed)  %.2f Hz  mean %+.3f samples/line  timebase drift +/-%.0f us\n",
		       wl[m].name, peak, 100 * peak / 3640, hz, mean, drift_us);
		check(fabs(mean) < 0.05, "  ...no net line-rate offset (|mean| < 0.05 samples/line)");
		char msg[112];
		snprintf(msg, sizeof msg, "%s: peak %.1f (want %.1f), rate %.2f Hz (want %.1f)", wl[m].name, peak, wl[m].peak, hz, wl[m].hz);
		check(peak == wl[m].peak && (wl[m].hz == 0 ? cycles == 0 : fabs(hz - wl[m].hz) < 0.05 * wl[m].hz), msg);
	}

	tb->final();
	delete tb;
	printf("\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
	return fail ? 1 : 0;
}

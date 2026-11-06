// SPDX-License-Identifier: GPL-2.0-or-later
// Mod Staircase / Mod Ramp chroma testbench (tb_modstair.sv as top).
//
// The waveform-monitor patterns carry constant chroma on every luma
// step for differential gain/phase measurement. Per NTC-7 / Tek
// practice the subcarrier sits at BURST phase (a vectorscope shows it on
// the burst vector) at burst amplitude (40 IRE p-p). This demodulates
// the encoder's C output against the same line's burst and checks, at
// several positions along the line:
//   1  chroma phase = burst phase (within 3 degrees)
//   2  chroma amplitude = burst amplitude (within 10%)
//   3  constant along the line: no step-to-step phase or gain change
//      (the encoder itself must add no differential gain/phase)
// Exit code 0 = all checks passed, 1 = a check failed.
#include "Vtb_modstair.h"
#include "verilated.h"
#include <cmath>
#include <cstdio>
#include <vector>

static Vtb_modstair *tb;
static long long t = 0;
static void tick() { tb->clk = 1; tb->eval(); tb->clk = 0; tb->eval(); t++; }

static void iq(const std::vector<int> &c, const std::vector<long long> &tt, int a, int b, double &amp, double &ph) {
	double I = 0, Q = 0;
	for (int h = a; h < b; h++) { double w = 2 * M_PI * (tt[h] % 16) / 16.0; I += c[h] * cos(w); Q += c[h] * sin(w); }
	amp = 2 * sqrt(I * I + Q * Q) / (b - a);
	ph = atan2(Q, I) * 180 / M_PI;
}
static double wrap(double d) { while (d > 180) d -= 360; while (d <= -180) d += 360; return d; }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	tb = new Vtb_modstair;
	bool fail = false;
	auto check = [&](bool ok, const char *w) { printf("  [%s] %s\n", ok ? "PASS" : "FAIL", w); if (!ok) fail = true; };
	const struct { const char *name; int pat; } pats[] = {{"Mod Staircase", 12}, {"Mod Ramp", 13}};
	for (auto &p : pats) {
		tb->pattern = p.pat; tb->reset = 1;
		for (int i = 0; i < 16; i++) tick();
		tb->reset = 0;
		std::vector<int> c(3640); std::vector<long long> tt(3640);
		for (int line = 0; line < 6; line++)
			for (int k = 0; k < 3640; k++) {
				tick();
				if (line == 5) { c[tb->h] = int(tb->c_out) - 128; tt[tb->h] = t; }
			}
		double bamp, bph; iq(c, tt, 340, 460, bamp, bph);
		printf("%s: burst %.1f codes p-p\n", p.name, 2 * bamp);
		double worst_ph = 0, amin = 1e9, amax = 0;
		// one window per staircase step (steps are 580 samples wide from 668)
		for (int s = 0; s < 5; s++) {
			int a = 668 + 580 * s + 150, b = a + 288;     // inside the step, whole cycles
			double amp, ph; iq(c, tt, a, b, amp, ph);
			double d = wrap(ph - bph);
			printf("  position %d: chroma %.1f codes p-p, phase vs burst %+.1f deg\n", s, 2 * amp, d);
			worst_ph = std::max(worst_ph, fabs(d));
			amin = std::min(amin, amp); amax = std::max(amax, amp);
		}
		char w[96];
		snprintf(w, sizeof w, "%s: 1 chroma at burst phase", p.name);      check(worst_ph <= 3, w);
		snprintf(w, sizeof w, "%s: 2 chroma at burst amplitude", p.name);  check(amin >= 0.9 * bamp && amax <= 1.1 * bamp, w);
		snprintf(w, sizeof w, "%s: 3 constant along the line", p.name);    check(amax - amin <= 0.03 * amax, w);
	}
	tb->final(); delete tb;
	printf("\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
	return fail ? 1 : 0;
}

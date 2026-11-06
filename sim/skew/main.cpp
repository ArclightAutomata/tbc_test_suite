// SPDX-License-Identifier: GPL-2.0-or-later
// Skew profile testbench (Verilator, error_skew as top).
//
// Skew Top Heavy / Bottom Heavy are meant to be two different defects:
// bending concentrated at the top of the picture vs at the bottom.
// A TV's horizontal AFC or a TBC removes any constant offset, so the
// modes must differ in SHAPE, not just by a DC shift. This records the
// per-line offset over a field (240 visible lines, then blanking) and
// checks, in samples:
//   1  Top Heavy: >= 90% of the visible bending (|offset|) sits in the
//      top third of the picture; Bottom Heavy: >= 90% in the bottom third
//   2  the two stay distinct with the per-field mean removed (as an
//      AFC/TBC would): their mean-removed profiles are not alike
//   3  peak bend 50-80 samples (~1 us), like before
//   4  smooth inside the picture: no line-to-line step > 4 samples
//      (any jump back belongs in vertical blanking)
//   5  Moderate / Severe keep their linear slants exactly
// Exit code 0 = all checks passed, 1 = a check failed.
#include "Verror_skew.h"
#include "verilated.h"
#include <cmath>
#include <cstdio>
#include <vector>

static Verror_skew *d;
static void tick() { d->clk = 1; d->eval(); d->clk = 0; d->eval(); }

static std::vector<int> profile(int mode, int lines) {
	std::vector<int> off(lines);
	d->mode = mode;
	for (int pass = 0; pass < 2; pass++)
		for (int v = 0; v < lines; v++) {
			d->v_count = v; d->new_line = 1; tick();
			d->new_line = 0; tick();
			off[v] = (int16_t)(d->h_offset << 3) >> 3;   // 13-bit signed
		}
	return off;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	d = new Verror_skew;
	d->clk = 0; d->reset = 1; d->mode = 0; d->v_count = 0; d->new_line = 0;
	for (int i = 0; i < 8; i++) tick();
	d->reset = 0;
	bool fail = false;
	auto check = [&](bool ok, const char *w) { printf("  [%s] %s\n", ok ? "PASS" : "FAIL", w); if (!ok) fail = true; };

	const int LINES = 262, VIS = 240;
	auto top = profile(1, LINES), bot = profile(2, LINES);
	auto mod = profile(3, LINES), sev = profile(4, LINES);

	auto share = [&](const std::vector<int> &p, int a, int b) {
		double in = 0, all = 0;
		for (int v = 0; v < VIS; v++) { all += std::abs(p[v]); if (v >= a && v < b) in += std::abs(p[v]); }
		return all ? in / all : 0.0;
	};
	auto peak = [&](const std::vector<int> &p) { int m = 0; for (int v = 0; v < VIS; v++) m = std::max(m, std::abs(p[v])); return m; };
	auto maxstep = [&](const std::vector<int> &p) { int m = 0; for (int v = 1; v < VIS; v++) m = std::max(m, std::abs(p[v] - p[v - 1])); return m; };
	// correlation of the mean-removed visible profiles
	auto corr = [&](const std::vector<int> &a, const std::vector<int> &b) {
		double ma = 0, mb = 0; for (int v = 0; v < VIS; v++) { ma += a[v]; mb += b[v]; } ma /= VIS; mb /= VIS;
		double sab = 0, saa = 0, sbb = 0;
		for (int v = 0; v < VIS; v++) { double x = a[v] - ma, y = b[v] - mb; sab += x * y; saa += x * x; sbb += y * y; }
		return (saa && sbb) ? sab / sqrt(saa * sbb) : 1.0;
	};

	double st = share(top, 0, 80), sb = share(bot, 160, 240), c = corr(top, bot);
	printf("Top Heavy:    line 0/40/80/160/239 = %d/%d/%d/%d/%d, %.0f%% of the bend in the top third, peak %d, max step %d\n",
	       top[0], top[40], top[80], top[160], top[239], st * 100, peak(top), maxstep(top));
	printf("Bottom Heavy: line 0/40/80/160/239 = %d/%d/%d/%d/%d, %.0f%% of the bend in the bottom third, peak %d, max step %d\n",
	       bot[0], bot[40], bot[80], bot[160], bot[239], sb * 100, peak(bot), maxstep(bot));
	printf("mean-removed correlation Top vs Bottom: %+.2f (identical shapes = +1.00)\n", c);

	check(st >= 0.90, "1: Top Heavy bends the top third of the picture");
	check(sb >= 0.90, "1: Bottom Heavy bends the bottom third of the picture");
	check(c < 0.5, "2: Top and Bottom Heavy differ in shape, not just by an offset");
	check(peak(top) >= 50 && peak(top) <= 80 && peak(bot) >= 50 && peak(bot) <= 80, "3: peak bend ~1 us");
	check(maxstep(top) <= 4 && maxstep(bot) <= 4, "4: smooth within the picture");

	bool lin = true;
	for (int v = 0; v < LINES; v++)
		if (mod[v] != ((v - 131) >> 1) || sev[v] != (v - 131) * 2) lin = false;
	check(lin, "5: Moderate and Severe keep their linear slants");

	d->final();
	delete d;
	printf("\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
	return fail ? 1 : 0;
}

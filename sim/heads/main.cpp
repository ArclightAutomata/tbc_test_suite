// SPDX-License-Identifier: GPL-2.0-or-later
// Video head condition testbench (Verilator, error_head as top).
//
// Drives NTSC line timing (3640 samples x 262 lines) and checks, per
// mode, against rtl/error_head.sv's design comments:
//   1  the head phase flips exactly at line 233 once per field, and a
//      run start (reload) restarts it on head A
//   2  snow level per head (RMS, speck samples excluded) and speck rate
//      per head; snow is band-limited (changes at most every 4 samples)
//   3  soft / chroma mute / snow / sync removal land only on the head(s)
//      each mode names
//   4  clogged snow spans 2..254 around mid-gray
//   5  the same seed replays the identical noise after a reload
//   6  Off: every output idle
// Exit code 0 = all checks passed, 1 = a check failed.
#include "Verror_head.h"
#include "verilated.h"
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <algorithm>

static Verror_head *d;
static int h = 0, v = 0;
static bool fail = false;
static void check(bool ok, const char *what) {
	printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
	fail |= !ok;
}
// one clock; new_line pulses at h == 0, v_count updates with it
static void tick() {
	d->new_line = (h == 0);
	d->v_count = v;
	d->clk = 1; d->eval(); d->clk = 0; d->eval();
	if (++h == 3640) { h = 0; if (++v == 262) v = 0; }
}
static void reload() { d->reload = 1; tick(); d->reload = 0; }

struct Stats {
	double sq[2] = {0, 0}; long n[2] = {0, 0}, specks[2] = {0, 0}, changes = 0, steady = 0;
	long soft[2] = {0, 0}, cmute[2] = {0, 0}, snow[2] = {0, 0}, nosync[2] = {0, 0}, samples[2] = {0, 0};
	long flips = 0, flips_bad = 0, lo = 999, hi = -1; double ssum = 0, ssq = 0; long sn = 0;
	uint64_t hash = 1469598103934665603ull;
};

static Stats run(int mode, int fields) {
	Stats s;
	d->mode = mode;
	// the core reloads at a frame start (line 0), so the head phase and
	// the noise stream restart in step
	while (!(v == 0 && h == 0)) tick();
	reload();
	int prev_b = d->head_b, prev_noise = 0, prev_speck = 0;
	for (long i = 0; i < 3640L * 262 * fields; i++) {
		int vv = v;
		tick();
		int b = d->head_b;
		if (b != prev_b) { s.flips++; if (vv != 233 || h != 1) s.flips_bad++; }
		prev_b = b;
		int nz = (int16_t)(d->noise << 7) >> 7;
		int speck = nz >= 48;
		s.samples[b]++;
		if (speck && !prev_speck) s.specks[b]++;
		if (!speck) { s.sq[b] += double(nz) * nz; s.n[b]++; }
		if (!speck && !prev_speck) { s.steady++; if (nz != prev_noise) s.changes++; }
		prev_noise = nz; prev_speck = speck;
		s.soft[b] += d->soften; s.cmute[b] += d->cmute; s.snow[b] += d->snow; s.nosync[b] += d->nosync;
		if (d->snow) {
			int l = d->snow_luma; s.ssum += l; s.ssq += double(l) * l; s.sn++;
			if (l < s.lo) s.lo = l; if (l > s.hi) s.hi = l;
		}
		s.hash = (s.hash ^ (uint64_t)(nz & 0x1FF) ^ ((uint64_t)d->snow_luma << 9)) * 1099511628211ull;
	}
	return s;
}

static double rms(const Stats &s, int b) { return s.n[b] ? sqrt(s.sq[b] / s.n[b]) : 0; }
static double per_field(const Stats &s, int b) { return s.samples[b] ? s.specks[b] * 953680.0 / s.samples[b] : 0; }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	d = new Verror_head;
	d->clk = 0; d->reset = 1; d->mode = 0; d->seed = 0x5A; d->reload = 0; d->new_line = 0; d->v_count = 0;
	for (int i = 0; i < 16; i++) tick();
	d->reset = 0;
	// start mid-field so the first flip is a real one
	while (!(v == 100 && h == 0)) tick();

	const char *names[] = {"Off", "Dirty", "Very Dirty", "One Clogged", "Both Clogged"};
	// snow RMS: triangular -63..63 has sigma 26.1; >>>3 ~3.3, >>>2 ~6.5, 3/4 ~19.6
	// (the floor shifts add a small negative bias, included in the RMS)
	struct Want { double rms_a, rms_b, spk_a, spk_b; } want[] = {
		{0, 0, 0, 0}, {3.4, 6.6, 14.6, 58}, {3.4, 19.7, 14.6, 460}, {0, 0, 0, 0}, {0, 0, 0, 0}};
	const int F = 60;
	char msg[200];
	for (int m = 0; m <= 4; m++) {
		Stats s = run(m, F);
		printf("\n%s (%d fields)\n", names[m], F);
		printf("  head flips %ld (at line 233: %ld off)\n", s.flips, s.flips_bad);
		printf("  head A: snow RMS %.2f, specks %.1f/field   head B: snow RMS %.2f, specks %.1f/field\n",
		       rms(s, 0), per_field(s, 0), rms(s, 1), per_field(s, 1));
		printf("  soft A/B %ld/%ld  cmute A/B %ld/%ld  snow A/B %ld/%ld  nosync A/B %ld/%ld (of %ld/%ld samples)\n",
		       s.soft[0], s.soft[1], s.cmute[0], s.cmute[1], s.snow[0], s.snow[1], s.nosync[0], s.nosync[1],
		       s.samples[0], s.samples[1]);
		if (m == 0) {
			check(s.flips == 0 && rms(s, 0) == 0 && rms(s, 1) == 0 && s.specks[0] + s.specks[1] == 0 &&
			      s.soft[0] + s.soft[1] + s.cmute[0] + s.cmute[1] + s.snow[0] + s.snow[1] == 0,
			      "6: Off leaves every output idle");
			continue;
		}
		snprintf(msg, sizeof msg, "1: head flips once per field, exactly at line 233 (%ld flips)", s.flips);
		check(s.flips >= F - 1 && s.flips <= F + 1 && s.flips_bad == 0, msg);
		bool levels = true;
		for (int b = 0; b < 2; b++) {
			double wr = b ? want[m].rms_b : want[m].rms_a, wk = b ? want[m].spk_b : want[m].spk_a;
			double r = rms(s, b), k = per_field(s, b);
			if (wr == 0 ? r != 0 : fabs(r - wr) > 0.12 * wr) levels = false;
			double tol = wk == 0 ? 0 : std::max(0.1 * wk, 3 * sqrt(wk / (F / 2.0)));
			if (fabs(k - wk) > tol) levels = false;
		}
		snprintf(msg, sizeof msg, "2: snow RMS and speck rate per head match %s's design", names[m]);
		check(levels, msg);
		if (m <= 2) {
			snprintf(msg, sizeof msg, "2: snow is band-limited (changes on %.1f%% of samples, at most 25%%)",
			         100.0 * s.changes / s.steady);
			check(s.changes * 4 <= s.steady, msg);
		}
		long a_n = s.samples[0], b_n = s.samples[1];
		bool soft_ok  = (m == 2) ? (s.soft[0] == 0 && s.soft[1] == b_n) : (s.soft[0] + s.soft[1] == 0);
		bool cmute_ok = (m == 2 || m == 3) ? (s.cmute[0] == 0 && s.cmute[1] == b_n)
		              : (m == 4) ? (s.cmute[0] == a_n && s.cmute[1] == b_n) : (s.cmute[0] + s.cmute[1] == 0);
		bool snow_ok  = (m == 3) ? (s.snow[0] == 0 && s.snow[1] == b_n && s.nosync[1] == b_n && s.nosync[0] == 0)
		              : (m == 4) ? (s.snow[0] == a_n && s.snow[1] == b_n && s.nosync[0] == a_n && s.nosync[1] == b_n)
		              : (s.snow[0] + s.snow[1] + s.nosync[0] + s.nosync[1] == 0);
		snprintf(msg, sizeof msg, "3: soft / chroma mute / snow / sync removal only on %s's head(s)", names[m]);
		check(soft_ok && cmute_ok && snow_ok, msg);
		if (m >= 3) {
			double mean = s.ssum / s.sn, sd = sqrt(s.ssq / s.sn - mean * mean);
			snprintf(msg, sizeof msg, "4: clogged snow %ld..%ld, mean %.1f, sd %.1f (want 2..254 around 128, sd ~52)",
			         s.lo, s.hi, mean, sd);
			check(s.lo >= 2 && s.hi <= 254 && s.lo < 20 && s.hi > 236 && fabs(mean - 128) < 3 && fabs(sd - 52) < 5, msg);
		}
		if (m == 2) {
			// replay: the same seed after a reload gives the identical noise
			Stats r1 = run(m, 2), r2 = run(m, 2);
			check(r1.hash == r2.hash, "5: a reload replays the identical noise");
			d->seed = 0x5B; Stats r3 = run(m, 2); d->seed = 0x5A;
			check(r3.hash != r1.hash, "5: a different seed gives different noise");
		}
	}
	// reload restarts on head A
	d->mode = 1; reload();
	check(d->head_b == 0, "1: a run start restarts on head A");

	d->final();
	delete d;
	printf("\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
	return fail ? 1 : 0;
}

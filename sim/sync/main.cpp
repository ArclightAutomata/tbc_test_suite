// SPDX-License-Identifier: GPL-2.0-or-later
// Sync waveform testbench (tb_sync.sv as top): checks the composite sync
// reaching the IO board against the NTSC / PAL standards.
//
// For NTSC interlaced, NTSC progressive and PAL interlaced it records
// several fields of the sync line and checks:
//   1  vertical interval: NTSC 6 equalizing + 6 broad (serrated) + 6
//      equalizing pulses, PAL 5 + 5 + 5, on half-line spacing
//   2  field period: 262.5 lines (NTSC interlaced), 262 (progressive),
//      312.5 (PAL) - so successive fields interleave
//   3  interleave: the picture sits half a line lower in one field than
//      the other (relative to each field's vertical sync); progressive: 0
//   4  no burst inside the vertical interval; burst on normal lines
//   5  line period: NTSC exactly 3640 clocks; PAL 3665/3666 averaging
//      exactly 64 us (15625 Hz): any 11 consecutive lines = 40320 clocks
// and, with timing errors running (per-line tearing offsets, wow-style
// line-length modulation, a rolling vsync) and separately with Pulse
// Cross on:
//   6  every sync pulse is still a well-formed H / equalizing / broad
//      pulse (no runts or merged pulses), and every field still carries
//      a complete vertical interval
// Exit code 0 = all checks passed, 1 = a check failed.
#include "Vtb_sync.h"
#include "verilated.h"
#include <cmath>
#include <cstdio>
#include <vector>
#include <cstdlib>

static Vtb_sync *tb;
static long long t = 0;
static void tick() { tb->clk = 1; tb->eval(); tb->clk = 0; tb->eval(); t++; }
static bool fail = false;
static void check(bool ok, const char *w) { printf("  [%s] %s\n", ok ? "PASS" : "FAIL", w); if (!ok) fail = true; }

struct Pulse { long long t; int w; char k; };   // k: H, E (equalizing), B (broad), ? other

static void run(const char *name, int pal, int inter) {
	printf("\n%s\n", name);
	tb->pal = pal; tb->interlace_en = inter; tb->reset = 1;
	for (int i = 0; i < 64; i++) tick();
	tb->reset = 0;
	const long long FIELD = pal ? 3666LL * 313 : 3640LL * 263;
	for (long long i = 0; i < 2 * FIELD; i++) tick();           // settle

	std::vector<Pulse> P;
	std::vector<long long> act, bur;
	int ps = tb->sync, pa = tb->active, pb = tb->burst;
	long long st = 0;
	for (long long i = 0; i < 6 * FIELD; i++) {
		tick();
		int s = tb->sync, a = tb->active, b = tb->burst;
		if (s && !ps) st = t;
		if (!s && ps) {
			int w = int(t - st);
			char k = (w >= 250 && w <= 290) ? 'H' : (w >= 110 && w <= 160) ? 'E' : (w >= 1400 && w <= 1700) ? 'B' : '?';
			P.push_back({st, w, k});
		}
		if (a && !pa) act.push_back(t);
		if (b && !pb) bur.push_back(t);
		ps = s; pa = a; pb = b;
	}

	// vertical intervals: runs of non-H pulses
	struct Iv { size_t a, b; };
	std::vector<Iv> iv;
	for (size_t i = 0; i < P.size();) {
		if (P[i].k == 'H') { i++; continue; }
		size_t j = i; while (j < P.size() && P[j].k != 'H') j++;
		if (j - i >= 3 && i > 0 && j < P.size()) iv.push_back({i, j});
		i = j;
	}
	const int half_lo = pal ? 1832 : 1820, half_hi = pal ? 1833 : 1820;
	const int want_n = pal ? 5 : 6;
	int good_iv = 0;
	std::vector<long long> tb_first;           // first broad pulse of each interval
	std::vector<long long> iv_end;
	for (auto &v : iv) {
		std::string seq; bool sp = true;
		for (size_t i = v.a; i < v.b; i++) {
			seq += P[i].k;
			if (i > v.a) { long long d = P[i].t - P[i - 1].t; if (d < half_lo - 1 || d > half_hi + 1) sp = false; }
		}
		std::string want = std::string(want_n, 'E') + std::string(want_n, 'B') + std::string(want_n, 'E');
		if (seq == want && sp) good_iv++;
		long long fb = -1;
		for (size_t i = v.a; i < v.b && fb < 0; i++) if (P[i].k == 'B') fb = P[i].t;
		tb_first.push_back(fb < 0 ? P[v.a].t : fb);
		iv_end.push_back(P[v.b - 1].t + P[v.b - 1].w);
		if (&v == &iv[0]) printf("  vertical interval: %s (want %s)%s\n", seq.c_str(), want.c_str(), sp ? "" : ", spacing off");
	}
	check(!iv.empty() && good_iv == (int)iv.size(), "1: standard vertical interval on half-line spacing");

	// field periods
	double want_fp = pal ? 312.5 * 3665.454545 : (inter ? 262.5 : 262.0) * 3640;
	bool fp_ok = tb_first.size() >= 3;
	printf("  field periods (lines):");
	for (size_t i = 1; i < tb_first.size(); i++) {
		double fp = double(tb_first[i] - tb_first[i - 1]);
		printf(" %.2f", fp / (pal ? 3665.454545 : 3640.0));
		if (fabs(fp - want_fp) > 2) fp_ok = false;
	}
	printf("  (want %.1f)\n", want_fp / (pal ? 3665.454545 : 3640.0));
	check(fp_ok, "2: field period");

	// interleave: first active line after each interval, relative to its
	// first broad pulse
	std::vector<long long> d;
	for (size_t i = 0; i < tb_first.size(); i++)
		for (long long a : act) if (a > iv_end[i]) { d.push_back(a - tb_first[i]); break; }
	bool il_ok = d.size() >= 3;
	double half = pal ? 1832.727 : 1820.0;
	printf("  picture offset between successive fields (samples):");
	for (size_t i = 1; i < d.size(); i++) {
		long long dd = llabs(d[i] - d[i - 1]);
		printf(" %lld", dd);
		if (inter ? (fabs(dd - half) > 2) : (dd > 2)) il_ok = false;
	}
	printf("  (want %s)\n", inter ? (pal ? "~1833" : "1820") : "0");
	check(il_ok, "3: fields interleave by half a line (progressive: not at all)");

	// burst
	int bad_burst = 0;
	for (size_t i = 0; i < iv.size(); i++)
		for (long long b : bur) if (b >= P[iv[i].a].t && b <= iv_end[i]) bad_burst++;
	int hcount = 0; for (auto &p : P) if (p.k == 'H') hcount++;
	printf("  bursts inside vertical intervals: %d; bursts per normal line: %.2f\n",
	       bad_burst, double(bur.size()) / hcount);
	check(bad_burst == 0 && bur.size() >= 0.95 * hcount, "4: no burst in the vertical interval, burst on normal lines");

	// line period on normal stretches
	std::vector<long long> sp;
	bool lp_ok = true;
	for (size_t i = 1; i < P.size(); i++)
		if (P[i].k == 'H' && P[i - 1].k == 'H') sp.push_back(P[i].t - P[i - 1].t);
		else sp.push_back(-1);
	int lmin = 99999, lmax = 0;
	for (size_t i = 0; i < sp.size(); i++) {
		if (sp[i] < 0) continue;
		lmin = std::min<int>(lmin, sp[i]); lmax = std::max<int>(lmax, sp[i]);
		if (!pal && sp[i] != 3640) lp_ok = false;
		if (pal && i + 11 <= sp.size()) {
			long long s = 0; bool full = true;
			for (size_t k = i; k < i + 11; k++) { if (sp[k] < 0) { full = false; break; } s += sp[k]; }
			if (full && s != 40320) lp_ok = false;
		}
	}
	printf("  line period %d..%d clocks\n", lmin, lmax);
	check(lp_ok, pal ? "5: PAL lines average exactly 64 us (11 lines = 40320 clocks)" : "5: NTSC line period exactly 3640 clocks");
}

// stress: errors drive the timing; only pulse shapes are checked
static void stress(const char *name, int pal, bool pc) {
	printf("\n%s\n", name);
	tb->pal = pal; tb->interlace_en = 1; tb->reset = 1;
	tb->h_offset = 0; tb->llm = 0; tb->roll_shift = 0; tb->pulse_cross = pc;
	for (int i = 0; i < 64; i++) tick();
	tb->reset = 0;
	const long long FIELD = pal ? 3666LL * 313 : 3640LL * 263;
	uint32_t x = 0x9E3779B9; long long line = 0;
	std::vector<Pulse> P;
	int ps = tb->sync; long long st = 0, fields = 0;
	for (long long i = 0; i < 10 * FIELD; i++) {
		if (tb->new_line && !pc) {
			line++;
			x ^= x << 13; x ^= x >> 17; x ^= x << 5;
			tb->h_offset = ((x & 0xFF) < 40) ? int16_t((x >> 8) & 0x3FF) - 512 : 0;   // tear ~16% of lines, +/-512
			tb->llm = int(30 * sin(line * 0.002));                                    // wow-ish
			tb->roll_shift = (line / 400) % (pal ? 312 : 262);                            // rolling vsync
		}
		tick();
		if (tb->new_field) fields++;
		int s = tb->sync;
		if (s && !ps) st = t;
		if (!s && ps) {
			int w = int(t - st);
			char k = (w >= 250 && w <= 290) ? 'H' : (w >= 110 && w <= 160) ? 'E' : (w >= 1100 && w <= 1800) ? 'B' : '?';
			P.push_back({st, w, k});
		}
		ps = s;
	}
	int bad = 0, ivs = 0;
	for (size_t i = 0; i < P.size(); i++) {
		if (P[i].k == '?' && getenv("SYNC_DBG") && bad < 4) {
			printf("    malformed: width %d at t=%lld; context:", P[i].w, P[i].t);
			for (size_t k = (i > 3 ? i - 3 : 0); k < i + 4 && k < P.size(); k++) printf(" %c%d@+%lld", P[k].k, P[k].w, P[k].t - P[i].t);
			printf("\n");
		}
		if (P[i].k == '?') bad++;
		if (P[i].k == 'B' && (i == 0 || P[i - 1].k != 'B')) ivs++;
	}
	printf("  %zu pulses over %lld fields: %d malformed, %d vertical intervals\n", P.size(), fields, bad, ivs);
	char w[128];
	snprintf(w, sizeof w, "6: %s: well-formed pulses, a vertical interval every field", pc ? "pulse cross" : "errors running");
	check(bad == 0 && ivs >= fields - 1, w);
	tb->h_offset = 0; tb->llm = 0; tb->roll_shift = 0; tb->pulse_cross = 0;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	tb = new Vtb_sync;
	tb->clk = 0;
	tb->h_offset = 0; tb->llm = 0; tb->roll_shift = 0; tb->pulse_cross = 0;
	run("NTSC, interlaced", 0, 1);
	run("NTSC, progressive", 0, 0);
	run("PAL, interlaced", 1, 1);
	tb->h_offset = 0; tb->llm = 0; tb->roll_shift = 0; tb->pulse_cross = 0;
	stress("NTSC, tearing + wow + rolling vsync", 0, false);
	stress("PAL, tearing + wow + rolling vsync", 1, false);
	stress("NTSC, pulse cross", 0, true);
	tb->final();
	delete tb;
	printf("\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
	return fail ? 1 : 0;
}

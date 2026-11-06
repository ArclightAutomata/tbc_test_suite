// SPDX-License-Identifier: GPL-2.0-or-later
// Same-seed reproducibility testbench driver (tb_repro.sv as top).
//
// The OSD seed is meant to make a test run repeatable: close the OSD,
// and the same seed replays the same error timeline. This closes the
// "OSD" twice, at different points in the line and field, with almost
// every error on (tear, flagwave, skew, wow, flutter, roll drift,
// head-switch unstable, jitter, dropouts, hue drift, burst flicker,
// subcarrier drift, chroma noise), and records a signature of every
// error output on every line for 12 fields, starting at the first
// frame (field 0) after each close - including the subcarrier phase at
// each line start (SC-H) and the PAL V-switch state. Pass criteria:
//   1  same seed, different close moment: identical on every line
//   2  different seed: differs (the signature really sees the errors)
//   3  the errors are actually active in the recording
//   4  Interlace Off: the errors still start (the run start waits for a
//      field-0 frame start, and a progressive field must provide one
//      whatever parity the OSD froze it at)
// Exit code 0 = all checks passed, 1 = a check failed.
#include "Vtb_repro.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vtb_repro *tb;
static void tick() { tb->clk = 1; tb->eval(); tb->clk = 0; tb->eval(); }

static const int FIELD_CYCLES = 3640 * 263;
static const int REC_FIELDS = 12;

struct Trace { std::vector<uint64_t> sig; int torn = 0, dropped = 0, noisy = 0; bool started = false; };

static uint64_t mix(uint64_t h, uint64_t v) { return (h ^ v) * 0x100000001B3ULL; }

// OSD closes after `delay` cycles; record from the first frame start
static Trace run(long delay) {
	Trace t;
	for (long i = 0; i < delay; i++) tick();
	tb->test_active = 1;
	// errors start at the first field-0 frame start after the close;
	// give up after 4 fields (= the errors never start)
	for (long i = 0; i < 4L * FIELD_CYCLES && !tb->err_on; i++) tick();
	if (!tb->err_on) { tb->test_active = 0; return t; }
	t.started = true;
	int fields = 0, drop_cnt = 0;
	bool in_line = false;
	uint64_t h = 0;
	while (fields < REC_FIELDS) {
		tick();
		if (tb->drop_act) drop_cnt++;
		if (tb->new_line) {
			if (in_line) {
				h = mix(h, (uint64_t)drop_cnt);
				t.sig.push_back(h);
				if (drop_cnt) t.dropped++;
			}
			in_line = true; drop_cnt = 0;
			// (new_field pulses the clock after new_line - inside these ticks)
			for (int k = 0; k < 3; k++) { tick(); if (tb->drop_act) drop_cnt++; if (tb->new_field) fields++; }
			h = 0xCBF29CE484222325ULL;
			h = mix(h, tb->v_count);
			h = mix(h, (uint16_t)tb->h_off);
			h = mix(h, (uint16_t)tb->llm);
			h = mix(h, tb->roll);
			h = mix(h, (uint8_t)tb->noise);
			h = mix(h, tb->flick);
			h = mix(h, tb->hue);
			h = mix(h, tb->sc_drift);
			h = mix(h, tb->sc_phase);           // subcarrier-to-line phase
			h = mix(h, tb->pal_flip);
			if (tb->h_off) t.torn++;
			if (tb->noise) t.noisy++;
		}
		if (tb->new_field) fields++;
	}
	tb->test_active = 0;   // OSD opens again
	return t;
}

static int diff(const Trace &a, const Trace &b, int &first) {
	int n = 0; first = -1;
	size_t m = a.sig.size() < b.sig.size() ? a.sig.size() : b.sig.size();
	for (size_t i = 0; i < m; i++) if (a.sig[i] != b.sig[i]) { if (first < 0) first = int(i); n++; }
	return n + int(a.sig.size() > b.sig.size() ? a.sig.size() - m : b.sig.size() - m);
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	tb = new Vtb_repro;
	bool fail = false;
	auto check = [&](bool ok, const char *what) { printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what); if (!ok) fail = true; };

	tb->clk = 0; tb->reset = 1; tb->test_active = 0; tb->seed = 0x3A; tb->interlace = 1;
	for (int i = 0; i < 32; i++) tick();
	tb->reset = 0;
	for (long i = 0; i < 2L * FIELD_CYCLES; i++) tick();

	Trace a = run(1000);                                   // close early in a line
	Trace b = run(long(3.3 * FIELD_CYCLES) + 1777);        // OSD open ~3.3 fields, other line phase
	tb->seed = 0x3B;
	Trace c = run(long(2.6 * FIELD_CYCLES) + 911);         // different seed

	// Interlace Off: open the OSD while the field flag is 1, then close
	// it with interlace off (the OSD forces progressive while open, so
	// the flag is frozen at whatever parity it had)
	tb->interlace = 1; tb->test_active = 1;
	do tick(); while (!(tb->new_field && tb->field == 1));
	tb->test_active = 0; tb->interlace = 0;
	Trace p = run(FIELD_CYCLES / 3);
	printf("run P (Interlace Off): errors %s, %zu lines recorded (torn %d)\n",
	       p.started ? "started" : "NEVER started", p.sig.size(), p.torn);

	int fa, fc;
	int nab = diff(a, b, fa), nac = diff(a, c, fc);
	printf("run A: %zu lines (torn %d, dropout %d, chroma noise %d)\n", a.sig.size(), a.torn, a.dropped, a.noisy);
	printf("run B (same seed, closed at another moment): %d of %zu lines differ from A", nab, a.sig.size());
	if (nab) printf(" (first at line %d of the run)", fa);
	printf("\nrun C (other seed): %d of %zu lines differ from A\n", nac, a.sig.size());

	check(nab == 0, "1: same seed replays the same errors on every line");
	check(nac > int(a.sig.size()) / 2, "2: a different seed gives different errors");
	check(a.torn > 100 && a.dropped > 10 && a.noisy > 100, "3: the errors are active in the recording");
	check(p.started && p.torn > 100, "4: with Interlace Off the errors still start");

	tb->final();
	delete tb;
	printf("\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
	return fail ? 1 : 0;
}

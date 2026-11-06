// SPDX-License-Identifier: GPL-2.0-or-later
// Head Switch testbench (Verilator, error_headswitch as top).
//
// The module's own spec (rtl/error_headswitch.sv): a horizontal phase
// step at line 233 (Subtle 0.5 us = 29 samples, Typical 1.5 us = 86,
// Severe 4 us = 229; Unstable re-rolls it every field) that the "servo"
// pulls in exponentially with tau ~32 lines, so ~40% survives the 29
// lines to the top of the next field and the hook pulls in over the
// next ~50. This records two fields per mode (262 lines, NTSC) and
// checks, in samples:
//   1  the step lands at the switch line with the specified size
//   2  32 lines later ~37% (e^-1) remains          (+/-5% of the step, +/-2)
//   3  at line 0 of the next field ~40% remains     (+/-5% of the step, +/-2)
//   4  fully pulled in (|offset| <= 1) by line 200 - no residual offset
//   5  Unstable: the step varies field to field, and every field settles
// Exit code 0 = all checks passed, 1 = a check failed.
#include "Verror_headswitch.h"
#include "verilated.h"
#include <cmath>
#include <cstdio>
#include <set>
#include <vector>

static Verror_headswitch *d;
static uint32_t xs = 0x1234567;
static void tick() { d->clk = 1; d->eval(); d->clk = 0; d->eval(); }

// one field; returns the offset each line carries (h_offset after its new_line)
static std::vector<int> field() {
	std::vector<int> off(262);
	for (int v = 0; v < 262; v++) {
		xs ^= xs << 13; xs ^= xs >> 17; xs ^= xs << 5;
		d->rng = xs; d->v_count = v; d->new_line = 1; tick();
		d->new_line = 0; tick();
		off[v] = (int16_t)(d->h_offset << 3) >> 3;
	}
	return off;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	d = new Verror_headswitch;
	d->clk = 0; d->reset = 1; d->mode = 0; d->v_count = 0; d->new_line = 0; d->rng = 0;
	for (int i = 0; i < 8; i++) tick();
	d->reset = 0;
	bool fail = false;
	auto check = [&](bool ok, const char *w) { printf("  [%s] %s\n", ok ? "PASS" : "FAIL", w); if (!ok) fail = true; };
	auto near = [](double got, double want, double step) { return fabs(got - want) <= 0.05 * step + 2; };

	const char *names[] = {"", "Subtle", "Typical", "Severe"};
	const int steps[] = {0, 29, 86, 229};
	for (int m = 1; m <= 3; m++) {
		d->mode = m;
		field();                                   // settle into the mode
		auto a = field(), b = field();             // field a's switch decays into b
		int s = steps[m];
		int at = a[234];                           // offset carried by the line after the switch
		int t32 = b[234 + 32 - 262];               // 32 lines on: line 4 of the next field
		int top = b[0], settled = 0;
		for (int v = 200; v < 233; v++) settled = std::max(settled, std::abs(b[v]));
		double e1 = s * exp(-32.0 / 32), e0 = s * exp(-(262 - 234) / 32.0);
		printf("%s: step %d (spec %d), +32 lines %d (~%.0f), next field line 0 %d (~%.0f), residual by line 200 %d\n",
		       names[m], at, s, t32, e1, top, e0, settled);
		char w[96];
		snprintf(w, sizeof w, "%s: 1 step size", names[m]);             check(std::abs(at - s) <= 1, w);
		snprintf(w, sizeof w, "%s: 2 ~37%% after 32 lines", names[m]);  check(near(t32, e1, s), w);
		snprintf(w, sizeof w, "%s: 3 ~40%% at the next field's top", names[m]); check(near(top, e0, s), w);
		snprintf(w, sizeof w, "%s: 4 fully pulled in by line 200", names[m]);   check(settled <= 1, w);
	}

	d->mode = 4;
	field();
	std::set<int> st; int worst = 0;
	for (int f = 0; f < 60; f++) {
		auto o = field();
		st.insert(o[234]);
		for (int v = 200; v < 233; v++) worst = std::max(worst, std::abs(o[v]));
	}
	printf("Unstable: %zu distinct steps over 60 fields (%d..%d), worst residual by line 200: %d\n",
	       st.size(), *st.begin(), *st.rbegin(), worst);
	check(st.size() >= 10, "Unstable: 5 the step re-rolls each field");
	check(worst <= 1, "Unstable: 5 every field pulls in fully");

	d->final();
	delete d;
	printf("\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
	return fail ? 1 : 0;
}

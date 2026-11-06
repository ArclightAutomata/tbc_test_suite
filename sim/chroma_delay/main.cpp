// SPDX-License-Identifier: GPL-2.0-or-later
// Chroma Delay testbench (Verilator, yc_encoder as top).
//
// Chroma Delay is meant to model Y/C misalignment: the color content
// lands later than the luma it belongs to. It must NOT change hue -
// a receiver locks hue to the burst, and a real Y/C delay leaves the
// hue of a flat field alone.
//
// For each OSD delay setting (and both chroma bandwidth modes) this
// drives one NTSC line pattern into the encoder - burst, then black,
// then a flat 75% color field - and measures on the C output:
//   hue    phase of the picture chroma relative to the same line's
//          burst; must match the zero-delay value within 3 degrees
//   delay  chroma edge minus luma edge; must grow by the requested
//          sample count (+/-2) over the zero-delay value
//   burst  amplitude and phase unchanged (within 2% / 3 degrees)
// NTSC subcarrier is exactly 16 clocks per cycle, so phase is measured
// by correlating against the absolute clock count.
//
// Exit code 0 = all checks passed, 1 = a check failed.
#include "Vyc_encoder.h"
#include "verilated.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

static const int LINE = 3640;
static const int BURST_START = 312, BURST_LEN = 144;   // ~5.4 us, 9 cycles
static const int COLOR_END = 3300;
static int COLOR_START = 900;                          // varied per sub-run
static const int RAMP = 160;                           // 10 subcarrier cycles

struct Color { const char *name; int r, g, b; };

struct Meas { double hue, edge, burst_amp, burst_ph; };

static Vyc_encoder *enc;
static long long t = 0;

static void tick() {
	enc->clk = 1; enc->eval();
	enc->clk = 0; enc->eval();
	t++;
}

static double wrap(double d) {
	while (d > 180) d -= 360;
	while (d <= -180) d += 360;
	return d;
}

// I/Q of c over [a, b) of the recorded line, phase in degrees
static void iq(const std::vector<int> &c, const std::vector<long long> &tt, int a, int b,
               double &amp, double &ph) {
	double I = 0, Q = 0;
	for (int h = a; h < b; h++) {
		double w = 2 * M_PI * (tt[h] % 16) / 16.0;
		I += c[h] * cos(w);
		Q += c[h] * sin(w);
	}
	amp = 2 * sqrt(I * I + Q * Q) / (b - a);
	ph = atan2(Q, I) * 180 / M_PI;
}

static Meas run_one(const Color &col, int delay, int bw) {
	enc->chroma_delay = delay;
	enc->chroma_bw = bw;
	std::vector<int> c(LINE), y(LINE);
	std::vector<long long> tt(LINE);
	for (int line = 0; line < 6; line++) {
		for (int h = 0; h < LINE; h++) {
			enc->new_line = (h == 0);
			enc->burst_window = (h >= BURST_START && h < BURST_START + BURST_LEN);
			// the field fades in over RAMP samples, so the edge can be
			// located to a fraction of a sample by interpolation
			double f = (h < COLOR_START || h >= COLOR_END) ? 0.0
			         : std::min(1.0, double(h - COLOR_START) / RAMP);
			enc->r = int(col.r * f + 0.5);
			enc->g = int(col.g * f + 0.5);
			enc->b = int(col.b * f + 0.5);
			tick();
			if (line == 5) { c[h] = int(enc->c_out) - 128; y[h] = enc->y_out; tt[h] = t; }
		}
	}
	Meas m;
	double amp, ph;
	// burst, measured well inside the window
	iq(c, tt, BURST_START + 24, BURST_START + BURST_LEN - 8, m.burst_amp, m.burst_ph);
	// picture chroma, well inside the field (clear of a 255-sample delay)
	double act_amp, act_ph;
	iq(c, tt, 1800, 2600, act_amp, act_ph);
	m.hue = wrap(act_ph - m.burst_ph);
	// chroma envelope: synchronous demodulation against the field's own
	// chroma phase, averaged over one full subcarrier cycle (16 samples).
	// The demodulated product carries the envelope plus terms at
	// multiples of the subcarrier - including the encoder's own LUT and
	// rounding ripple, which repeats every cycle - and a 16-sample
	// average cancels all of them exactly. That keeps the edge position
	// independent of where the edge falls within a subcarrier cycle.
	auto env = [&](int h) {
		double s = 0;
		for (int k = h - 8; k < h + 8; k++)
			s += c[k] * cos(2 * M_PI * (tt[k] % 16) / 16.0 - act_ph * M_PI / 180);
		return 2 * s / 16;
	};
	// chroma edge: envelope crosses half the field amplitude (interpolated)
	double ce = -1, prev = env(COLOR_START - 65);
	for (int h = COLOR_START - 64; h < 1700 && ce < 0; h++) {
		double e = env(h);
		if (e >= 0.5 * act_amp) ce = h - 1 + (0.5 * act_amp - prev) / (e - prev);
		prev = e;
	}
	// luma edge: half the field level, interpolated
	double ylo = y[COLOR_START - 100], yhi = y[2000], mid = (ylo + yhi) / 2, le = -1;
	for (int h = COLOR_START - 64; h < 1700 && le < 0; h++)
		if (y[h] >= mid) le = h - 1 + (mid - y[h - 1]) / double(y[h] - y[h - 1]);
	m.edge = ce - le;
	return m;
}

// The encoder's chroma is not a pure sinusoid (LUT and rounding steps
// repeat every subcarrier cycle), so the measured half-amplitude point
// carries a small bias that depends on where the edge falls within the
// cycle. Repeating the measurement with the field start moved through
// all 16 positions of the cycle and averaging cancels that bias.
static Meas run(const Color &col, int delay, int bw) {
	Meas m{};
	double edge = 0;
	for (int s = 0; s < 16; s++) {
		COLOR_START = 900 + s;
		Meas k = run_one(col, delay, bw);
		if (s == 0) m = k;
		edge += k.edge / 16;
	}
	COLOR_START = 900;
	m.edge = edge;
	return m;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	enc = new Vyc_encoder;
	enc->clk = 0; enc->reset = 1;
	enc->pal = 0; enc->cvbs = 0; enc->hue_offset = 0; enc->burst_level = 0;
	enc->sc_mode = 0; enc->noise_mode = 0; enc->chroma_force = 0; enc->chroma_u = 0;
	enc->seed = 0; enc->reload = 0; enc->new_field = 0; enc->hue_drift = 0; enc->r = enc->g = enc->b = 0; enc->burst_window = 0; enc->new_line = 0;
	enc->chroma_delay = 0; enc->chroma_bw = 0;
	for (int i = 0; i < 16; i++) tick();
	enc->reset = 0;

	// the OSD settings (TBC_Test_Suite.sv chroma_delay map), plus the
	// 1- and 2-sample edge cases of the delay-line read tap
	const int delays[] = {1, 2, 6, 14, 29, 57, 115, 255};
	const Color cols[] = {{"yellow75", 191, 191, 0}, {"cyan75", 0, 191, 191}};
	bool fail = false;

	for (const Color &col : cols) {
		for (int bw = 0; bw <= 1; bw++) {
			Meas ref = run(col, 0, bw);
			printf("\n%s, %s chroma: hue %.1f deg, edge offset %.1f samples (delay 0)\n",
			       col.name, bw ? "broadcast" : "sharp", ref.hue, ref.edge);
			for (int d : delays) {
				Meas m = run(col, d, bw);
				double dh = wrap(m.hue - ref.hue);
				double de = m.edge - ref.edge;
				double db = m.burst_amp / ref.burst_amp - 1;
				double dp = wrap(m.burst_ph - ref.burst_ph);
				bool ok_h = fabs(dh) <= 3, ok_e = fabs(de - d) <= 2;
				bool ok_b = fabs(db) <= 0.02 && fabs(dp) <= 3;
				printf("  delay %3d (%4.0f ns): hue shift %+7.1f deg [%s]  extra delay %5.1f samples [%s]  burst %+.1f%% %+.1f deg [%s]\n",
				       d, d * 17.46, dh, ok_h ? "PASS" : "FAIL", de, ok_e ? "PASS" : "FAIL",
				       db * 100, dp, ok_b ? "PASS" : "FAIL");
				fail |= !(ok_h && ok_e && ok_b);
			}
		}
	}
	// y_lum (the luma the out stage uses to split Composite) must line
	// up exactly: from the same reset and inputs, Composite's
	// y_out - y_lum/2 must equal S-Video's chroma / 2, sample for sample
	{
		std::vector<int> cs, cv;
		long lum_bad = 0;
		for (int pass = 0; pass < 2; pass++) {
			enc->reset = 1; for (int i = 0; i < 16; i++) tick();
			enc->reset = 0; enc->cvbs = pass; enc->chroma_delay = 0; enc->chroma_bw = 0;
			for (int line = 0; line < 3; line++)
				for (int h = 0; h < LINE; h++) {
					enc->new_line = (h == 0);
					enc->burst_window = (h >= BURST_START && h < BURST_START + BURST_LEN);
					bool on = h >= 900 && h < 3300;
					enc->r = on ? (h * 3) & 0xFF : 0; enc->g = on ? (h * 5 + 60) & 0xFF : 0; enc->b = on ? (h * 7) & 0xFF : 0;
					tick();
					if (pass == 0) { cs.push_back(enc->c_out); if (enc->y_lum != enc->y_out) lum_bad++; }
					else cv.push_back((enc->y_out - (enc->y_lum >> 1)) & 0xFF);
				}
		}
		long bad = 0;
		for (size_t i = 0; i < cs.size(); i++) if (cv[i] != (cs[i] >> 1)) bad++;
		printf("\ny_lum alignment: %ld of %zu Composite samples split wrong, %ld S-Video samples with y_lum != y_out\n",
		       bad, cs.size(), lum_bad);
		bool ok = bad == 0 && lum_bad == 0;
		printf("  [%s] y_lum splits Composite exactly into luma + chroma\n", ok ? "PASS" : "FAIL");
		fail |= !ok;
		enc->cvbs = 0;
	}
	enc->final();
	delete enc;
	printf("\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
	return fail ? 1 : 0;
}

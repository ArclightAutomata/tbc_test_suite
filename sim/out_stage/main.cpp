// SPDX-License-Identifier: GPL-2.0-or-later
// Analog output stage testbench (Verilator, out_stage as top).
//
// The stage splits the encoded signal into luma and chroma, applies the
// RF-domain defects (head condition, dropouts, dropout compensation) and
// recombines. In Composite the encoder puts luma at HALF scale on the Y
// pin, riding the chroma midpoint: y = luma/2 + c/2 with c centered at
// 128, so black is 64 and white ~191; everything must use that scale.
// Checks:
//   1  no defect: output bit-identical to the encoder in both modes
//      (and the pulse-cross paths unchanged)
//   2  full dropout (mix 16): the original behavior - S-Video sparkle
//      185-248, Composite sparkle = luma/2 + 64 (never above white),
//      chroma dies in both modes
//   3  partial mix: luma and chroma move from the signal toward the
//      dropout level by exactly floor(diff * mix / 16)
//   4  Composite pulse cross never goes below Composite black (64): the
//      painted sync marks sit AT black and the lift is half-scale (+32).
//      At Y=0 the marks were blacker than black and the TV's sync
//      separator took them for sync (the picture rolled).
//   5  head condition: snow/specks add to the luma with clamping, a
//      clogged head replaces it, chroma mute neutralizes chroma, soft
//      averages the last 4 luma samples; all masked inside the
//      pulse-cross pedestal
//   6  Dropout Comp: during a dropout the luma is the output from exactly
//      1H earlier (3640 samples NTSC, 3665 PAL), recirculating through
//      long dropouts; chroma still drops out
// Exit code 0 = all checks passed, 1 = a check failed.
#include "Vout_stage.h"
#include "verilated.h"
#include <cstdio>
#include <vector>
#include <algorithm>

static Vout_stage *d;
static bool fail = false;
static void check(bool ok, const char *w) { printf("  [%s] %s\n", ok ? "PASS" : "FAIL", w); if (!ok) fail = true; }
static void idle() {
	d->drop_act = 0; d->drop_mix = 16; d->drop_luma = 200; d->doc_en = 0;
	d->hd_noise = 0; d->hd_snow = 0; d->hd_snow_luma = 128; d->hd_cmute = 0; d->hd_soft = 0;
	d->pc_enh = 0; d->pc_blank = 0; d->disp_sync = 0; d->pal = 0;
}
// set the encoder outputs for a luma / chroma pair
static void in(int cvbs, int lum, int ch) {
	d->cvbs = cvbs; d->lum = lum;
	if (cvbs) { d->out_y = (lum >> 1) + ch; d->out_c = 128; }   // ch: 0..127, 64 = none
	else      { d->out_y = lum; d->out_c = ch; }                  // ch: 0..255, 128 = none
}
static void tick() { d->clk = 1; d->eval(); d->clk = 0; d->eval(); }

// the original (pre-blend) output stage, as reference for checks 1, 2, 4
static void ref(int y, int c, int drop, int dl, int pe, int pb, int ds, int cvbs, int &oy, int &oc) {
	int vis = drop && !(pe && pb);
	int pre = vis ? (cvbs ? dl / 2 + 64 : dl) : y;
	int lift = pre + (cvbs ? 32 : 64);
	oy = !pe ? pre : ds ? (cvbs ? 64 : 0) : std::min(255, lift);
	oc = cvbs ? 128 : (vis ? 128 : c);
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	d = new Vout_stage;
	d->clk = 0; idle(); in(0, 0, 128); d->eval();
	char msg[160];

	// ---- 1, 2, 4: the original behavior at mix 16 ----
	long n = 0, bad1 = 0, bad2 = 0, cv_hi = 0, pc_low = 0, bad4 = 0;
	for (int cvbs = 0; cvbs <= 1; cvbs++)
	for (int drop = 0; drop <= 1; drop++)
	for (int pe = 0; pe <= 1; pe++)
	for (int pb = 0; pb <= 1; pb++)
	for (int ds = 0; ds <= 1; ds++)
	for (int dl = 185; dl <= 248; dl += 3)
	for (int lum = 0; lum < 256; lum += 5)
	for (int ch = 0; ch < (cvbs ? 128 : 256); ch += 9) {
		idle(); in(cvbs, lum, ch);
		d->drop_act = drop; d->drop_luma = dl; d->pc_enh = pe; d->pc_blank = pb; d->disp_sync = ds;
		d->eval(); n++;
		int ry, rc; ref(d->out_y, d->out_c, drop, dl, pe, pb, ds, cvbs, ry, rc);
		bool vis = drop && !(pe && pb);
		if (d->y != ry || d->c != rc) { if (vis) bad2++; else if (!pe) bad1++; else bad4++; }
		if (cvbs && vis && !pe && d->y > 191) cv_hi++;
		if (cvbs && pe && d->out_y >= 64 && d->y < 64) pc_low++;
	}
	printf("%ld combinations\n", n);
	check(bad1 == 0, "1: no defect -> output identical to the encoder (S-Video and Composite)");
	check(bad2 == 0 && cv_hi == 0, "2: full dropout matches the original (Composite sparkle on its own scale)");
	check(bad4 == 0 && pc_low == 0, "4: pulse cross unchanged; Composite stays at or above black");

	// ---- 3: partial blend ----
	long bad3 = 0, m3 = 0;
	for (int cvbs = 0; cvbs <= 1; cvbs++)
	for (int mix = 0; mix <= 16; mix++)
	for (int dl = 0; dl < 256; dl += 15)
	for (int lum = 0; lum < 256; lum += 7)
	for (int ch = 0; ch < (cvbs ? 128 : 256); ch += 11) {
		idle(); in(cvbs, lum, ch);
		d->drop_act = 1; d->drop_mix = mix; d->drop_luma = dl;
		d->eval(); m3++;
		auto fl = [](int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); };
		int l = lum + fl((dl - lum) * mix, 16);
		int neutral = cvbs ? 64 : 128;
		int c = ch + fl((neutral - ch) * mix, 16);
		int wy = cvbs ? (l >> 1) + c : l, wc = cvbs ? 128 : c;
		if (d->y != wy || d->c != wc) bad3++;
	}
	snprintf(msg, sizeof msg, "3: partial dropout blends luma and chroma by mix/16 (%ld of %ld off)", bad3, m3);
	check(bad3 == 0, msg);

	// ---- 5: head condition ----
	long bad5 = 0, m5 = 0;
	for (int cvbs = 0; cvbs <= 1; cvbs++)
	for (int nz = -63; nz <= 140; nz += 7)
	for (int lum = 0; lum < 256; lum += 9)
	for (int ch = 0; ch < (cvbs ? 128 : 256); ch += 13)
	for (int mode = 0; mode < 4; mode++) {     // 0 noise, 1 noise+cmute, 2 snow, 3 masked by pulse cross
		idle(); in(cvbs, lum, ch);
		d->hd_noise = nz & 0x1FF; d->hd_snow_luma = (lum * 7 + 3) & 0xFF;
		if (mode == 1) d->hd_cmute = 1;
		if (mode == 2) d->hd_snow = 1;
		if (mode == 3) { d->hd_snow = 1; d->hd_cmute = 1; d->pc_enh = 1; d->pc_blank = 1; }
		d->eval(); m5++;
		int neutral = cvbs ? 64 : 128;
		int l = mode == 2 ? d->hd_snow_luma : mode == 3 ? lum : std::clamp(lum + nz, 0, 255);
		int c = (mode == 1 || mode == 2) ? neutral : ch;
		int wy = cvbs ? (l >> 1) + c : l, wc = cvbs ? 128 : c;
		if (mode == 3) { wy = std::min(255, (cvbs ? d->out_y + 32 : d->out_y + 64)); }
		if (d->y != wy || d->c != wc) bad5++;
	}
	// soft: a 4-sample average of the luma (rounded)
	idle(); in(0, 0, 128);
	std::vector<int> hist;
	long bad5s = 0;
	for (int i = 0; i < 400; i++) {
		int lum = (i * 37 + (i * i) % 91) & 0xFF;
		in(0, lum, 128); d->hd_soft = 1; d->eval();
		hist.push_back(lum);
		if (i >= 3) {
			int a = (hist[i] + hist[i - 1] + hist[i - 2] + hist[i - 3] + 2) >> 2;
			if (d->y != a) bad5s++;
		}
		tick();
	}
	snprintf(msg, sizeof msg, "5: head noise / snow / chroma mute / pulse-cross mask (%ld of %ld off); soft = 4-sample average (%ld off)",
	         bad5, m5, bad5s);
	check(bad5 == 0 && bad5s == 0, msg);

	// ---- 6: Dropout Comp ----
	for (int pal = 0; pal <= 1; pal++)
	for (int cvbs = 0; cvbs <= 1; cvbs++) {
		const int D = pal ? 3665 : 3640, T = D * 8;
		std::vector<int> out(T), want(T);
		long bad6 = 0, chroma_bad = 0, in_drop = 0;
		idle(); d->pal = pal; d->doc_en = 1;
		for (int t = 0; t < T; t++) {
			int line = t / D, x = t % D;
			int lum = (x * 3 + line * 41) & 0xFF;
			int ch = cvbs ? ((x * 5) & 63) + 32 : (x * 7) & 0xFF;
			// a short dropout on line 3, and a long one spanning lines 5-6
			bool drop = (line == 3 && x >= 1000 && x < 1400) || (t >= 5 * D + 2000 && t < 6 * D + 3000);
			in(cvbs, lum, ch); d->drop_act = drop; d->drop_mix = 16; d->eval();
			int l_model = drop ? want[t - D] : lum;   // luma path (S-Video scale)
			want[t] = l_model;
			int neutral = cvbs ? 64 : 128;
			int wy = cvbs ? (l_model >> 1) + (drop ? neutral : ch) : l_model;
			if (t >= D) {   // the first line fills the delay line
				if (d->y != wy) bad6++;
				if (drop) { in_drop++; if ((cvbs ? 0 : d->c != 128)) chroma_bad++; }
			}
			tick();
		}
		snprintf(msg, sizeof msg, "6: %s %s: dropout luma = output 1H (%d samples) back, recirculating (%ld off, %ld dropout samples); chroma dropped",
		         pal ? "PAL" : "NTSC", cvbs ? "Composite" : "S-Video", D, bad6, in_drop);
		check(bad6 == 0 && chroma_bad == 0 && in_drop > 4000, msg);
	}

	d->final();
	delete d;
	printf("\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
	return fail ? 1 : 0;
}

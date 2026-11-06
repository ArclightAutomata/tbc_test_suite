// SPDX-License-Identifier: GPL-2.0-or-later
// Mandelbrot pattern testbench (Verilator, mandel_gen as top).
//
// Drives mandel_gen with interlaced NTSC line timing and reads its RGB
// at every displayed pixel (360 x 480 per frame, both fields). A C++
// reference renders the same frames with identical fixed-point
// arithmetic (Q2.24, |x| or |y| >= 2 escape, 64 iterations) and the
// palette from rtl/sine_lut.sv. Checks:
//   1  every pixel of two whole frames matches the reference exactly
//      (also proves each line is computed before it is displayed)
//   2  the image is a Mandelbrot: a solid inside (black) region in the
//      wide start frame, and many distinct escape colors
//   3  smooth zoom: the pixel step changes on every frame of the loop
// Frames are also written to sim/obj_mandel*/frame*.ppm for viewing.
// Plusargs +deep / +end mark builds started deep in / near the end of
// the zoom (-GSTART_U=..).
// Exit code 0 = all checks passed, 1 = a check failed.
#include "Vmandel_gen.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

static Vmandel_gen *d;
static void tick() { d->clk = 1; d->eval(); d->clk = 0; d->eval(); }

static const int64_t CX = -1696115, CY = 16043825;
static int lut[256];

// steps and origins carry 8 bits below the Q2.24 LSB; coordinates are
// the Q2.24 part (arithmetic shift, as in the RTL)
struct Params { int64_t sxf, syf, cx0f, cy0f; int cyc; };
static Params params(uint32_t u, int cyc) {
	Params p; p.sxf = u >> 4; p.syf = (u >> 5) + (u >> 8);
	p.cx0f = (CX << 8) - p.sxf * 180; p.cy0f = (CY << 8) - p.syf * 240; p.cyc = cyc; return p;
}
static uint32_t next_u(uint32_t u, uint32_t u0) { uint32_t nu = u - (u >> 7); return nu < (1u << 16) ? u0 : nu; }
static int iters(int64_t cx, int64_t cy) {
	int64_t x = 0, y = 0;
	for (int it = 0; it < 64; it++) {
		int64_t s = x + y, dd = x - y;
		int64_t nx = ((s * dd) >> 24) + cx, ny = ((x * y) >> 23) + cy;
		if (nx >= (1 << 25) || nx <= -(1 << 25) || ny >= (1 << 25) || ny <= -(1 << 25)) return it;
		x = nx; y = ny;
	}
	return 64;
}
static uint32_t rgb(int n, int cyc) {
	if (n == 64) return 0;
	int idx = ((n & 31) * 8 + cyc) & 255;
	auto ch = [&](int a) {
		int v = (128 + ((lut[a & 255] >> 1) & 0xFF)) & 0xFF;
		return n < 12 ? (v * (4 + n)) >> 4 : v;          // far-exterior fade
	};
	return (ch(idx) << 16) | (ch(idx + 26) << 8) | ch(idx + 51);
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	// palette table straight from the RTL source
	// (the binary runs from sim/obj_mandel*)
	std::ifstream f("../../rtl/sine_lut.sv"); std::stringstream ss; ss << f.rdbuf();
	std::string src = ss.str(); std::regex re("11'h([0-9A-Fa-f]{3})");
	int i = 0;
	for (auto it = std::sregex_iterator(src.begin(), src.end(), re); it != std::sregex_iterator() && i < 256; ++it, ++i) {
		int v = std::stoi((*it)[1].str(), nullptr, 16); lut[i] = v >= 1024 ? v - 2048 : v;
	}
	if (i != 256) { printf("could not read sine_lut.sv (%d values)\n", i); return 2; }
	// +deep / +end: builds started ~1165x deep / near the end of the zoom
	bool deep = argc > 1 && !strcmp(argv[argc - 1], "+deep");
	bool endz = argc > 1 && !strcmp(argv[argc - 1], "+end");
	uint32_t u0 = deep ? (10u << 16) : endz ? (2u << 16) : (11650u << 16);
	deep = deep || endz;

	d = new Vmandel_gen;
	d->clk = 0; d->reset = 1; d->restart = 0; d->interlace = 1; d->new_line = 0;
	d->v_count = 0; d->field = 0; d->h_pos = 0; d->active = 0;
	for (int k = 0; k < 8; k++) tick();
	d->reset = 0;

	// emulate ntsc_timing: 3640-clock lines, fields 263 (field 0) / 262,
	// v_count and field update one clock after new_line
	int h = 0, v = 0, fld = 0;
	std::vector<uint32_t> img(360 * 480);
	uint32_t u = u0; int cyc = 0, frame = 0, bad = 0, checked = 0;
	bool fail = false;
	auto check = [&](bool ok, const char *w) { printf("  [%s] %s\n", ok ? "PASS" : "FAIL", w); if (!ok) fail = true; };
	std::set<uint32_t> colors; int black = 0;
	for (int fields = 0; fields < 6;) {
		// as in the top level: h_pos = h_count - 668 (combinational, 0
		// before the active line), active_video registered one clock late
		d->new_line = (h == 0);
		d->active = (h >= 669 && h < 3569 && v < 240);
		d->h_pos = (h >= 668) ? h - 668 : 0;
		d->v_count = v; d->field = fld;
		tick();
		// sample mid-pixel; the output pipeline lags the position by ~5 clocks
		if (d->active && frame >= 1) {
			int hp = h - 668 - 5;
			if (hp >= 0 && hp < 2880 && (hp & 7) == 4) img[(2 * v + fld) * 360 + hp / 8] = (d->r << 16) | (d->g << 8) | d->b;
		}
		if (++h == 3640) {
			h = 0;
			int vt = fld == 0 ? 263 : 262;
			if (++v == vt) {
				v = 0; fld ^= 1; fields++;
				if (fld == 0) {
					// a frame just finished
					if (frame >= 1) {
						Params p = params(u, cyc);
						int fb = 0;
						for (int line = 0; line < 480; line++)
							for (int px = 0; px < 360; px++) {
								int n = iters((p.cx0f + px * p.sxf) >> 8, (p.cy0f + line * p.syf) >> 8);
								uint32_t want = rgb(n, cyc), got = img[line * 360 + px];
								if (want != got) { if (fb < 3) printf("    frame %d line %d px %d: got %06x want %06x (n=%d)\n", frame, line, px, got, want, n); fb++; }
								if (n == 64) black++; else colors.insert(got);
								checked++;
							}
						bad += fb;
						char fn[64]; snprintf(fn, sizeof fn, "frame%d%s.ppm", frame, deep ? "_deep" : "");
						FILE *o = fopen(fn, "wb"); fprintf(o, "P6 360 480 255\n");
						for (uint32_t c : img) { unsigned char b3[3] = {(unsigned char)(c >> 16), (unsigned char)(c >> 8), (unsigned char)c}; fwrite(b3, 1, 3, o); }
						fclose(o);
						printf("frame %d (zoom %.0fx): %d mismatched pixels; wrote %s\n", frame, 11650.0 * 65536 / u, fb, fn);
					}
					// frame f is drawn with the parameters after f updates
					// (the update runs on the last field's line 240); frame 0
					// is skipped - its parameters were never set
					u = next_u(u, u0); cyc = (cyc + 1) & 255;
					frame++;
				}
			}
		}
	}
	printf("%d pixels compared, %d mismatched; %d inside-set pixels, %zu distinct colors\n", checked, bad, black, colors.size());
	check(checked == 2 * 360 * 480 && bad == 0, "1: every pixel matches the fixed-point reference");
	// the wide start frame shows the solid inside region; deep in, the
	// Misiurewicz target is almost all boundary detail by design
	check((deep || black > 1000) && colors.size() >= 30, "2: looks like a Mandelbrot (inside region at the start, many escape colors)");
	// 3: smooth zoom - over the whole loop the pixel step (and so the
	// picture's scale) changes on every frame; with whole-LSB steps it
	// held for up to 8 frames near the end (the model is the RTL's
	// arithmetic, which check 1 shows the hardware matches)
	{
		uint32_t uu = 11650u << 16; int64_t prev = -1; int repeats = 0, frames = 0;
		while (true) {
			uint32_t nu = uu - (uu >> 7); if (nu < (1u << 16)) break; uu = nu; frames++;
			int64_t s = uu >> 4; if (s == prev) repeats++; prev = s;
		}
		printf("zoom loop: %d frames (%.1f s), %d with an unchanged pixel step\n", frames, frames / 29.97, repeats);
		check(repeats == 0, "3: the zoom changes scale on every frame of the loop");
	}
	d->final(); delete d;
	printf("\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
	return fail ? 1 : 0;
}

// SPDX-License-Identifier: GPL-2.0-or-later
// SD streaming testbench: the real rtl/video_player.sv (Verilator top)
// against the real tools/tbc_streamd.c loop (compiled in with
// TBC_STREAMD_NO_MAIN), sharing a simulated DDR.
//
// The daemon streams a temporary .sbin whose every pixel encodes its
// frame number, so the frame on screen can be read back from the core's
// RGB output. In a session the daemon's frame w holds file frame
// w % FILE_FRAMES, so "the right content" means: the frame on screen is
// the one the core claims to be on (its reader index, control word 5).
//
// Phases (each must end with video playing correctly):
//   1  normal streaming
//   2  Custom Video deselected for ~5 s, then selected again
//   3  daemon stopped and a new session started (writer restarts at 0)
//   4  a clip is loaded (Load Video) while the daemon is running: the
//      clip must play intact and the daemon must not take the DDR back
//   5  a second daemon starts while one is live: the old one must stop
//      (not keep writing the ring) and the new session must play
// "Playing correctly" over a window of fields: the reader advances
// ~1 frame per 2 fields, the frame on screen matches it, and the daemon
// keeps writing.
//
// Exit code 0 = all checks passed, 1 = a check failed.
// Verilator headers first: the daemon's #defines (MAGIC, ...) would
// otherwise collide with names in them
#include "Vvideo_player.h"
#include "verilated.h"

#define TBC_STREAMD_NO_MAIN
#include "../../tools/tbc_streamd.c"
#include <cstdio>
#include <vector>

static const int LINE = 1200, LINES = 262, ACTIVE = 1000;
static const int FILE_FRAMES = 40;
static const uint64_t RING_W = 0x06000000ULL, CTRL_W = 0x07EFE000ULL;
static const int CLIP_FRAMES = 4;
static const uint64_t CLIP_FRAME_W = 86880;     // 724x480 RGB565 / 8

static Vvideo_player *dut;
static std::vector<uint8_t> ram(RING_FRAMES * FRAME_BYTES);
static volatile uint64_t ctrl[8];
static bool fail = false;

// ---- DDR model (read bursts, position write-back) ----
static int rd_state = 0, rd_left = 0;
static uint64_t rd_a = 0;

static uint64_t mem_rd(uint64_t w) {
	if (w >= CTRL_W && w < CTRL_W + 8) return ctrl[w - CTRL_W];
	uint64_t off = (w - RING_W) * 8;
	if (w >= RING_W && off + 8 <= ram.size()) { uint64_t v; memcpy(&v, &ram[off], 8); return v; }
	return 0;
}

static void ddr_cycle() {
	dut->rd_ack = 0; dut->ddram_dout_ready = 0; dut->posw_ack = 0;
	if (rd_state == 0 && dut->rd_req) { rd_a = dut->rd_addr; rd_left = dut->rd_burstcnt; rd_state = 1; dut->rd_ack = 1; }
	else if (rd_state == 1) { dut->ddram_dout = mem_rd(rd_a++); dut->ddram_dout_ready = 1; if (--rd_left == 0) rd_state = 0; }
	if (dut->posw_req) { ctrl[dut->posw_addr - CTRL_W] = dut->posw_din; dut->posw_ack = 1; }
}

// ---- video timing + daemon scheduling ----
static int h = 0, v = 0, fieldbit = 0;
static struct stream S, S2;          // S2: phase 5's second session
static bool daemon_on = false, d2_on = false;
static int daemon_sleep = 0, d2_sleep = 0;
static long long field_no = 0;
static int shown = -1;         // pixel code on screen this field

static void cycle() {
	dut->h_pos = h; dut->v_count = v; dut->field = fieldbit;
	dut->active = (h < ACTIVE && v < 240);
	dut->new_line = (h == 0);
	dut->new_field = (h == 0 && v == 0);
	ddr_cycle();
	dut->clk = 1; dut->eval();
	dut->clk = 0; dut->eval();
	if (v == 100 && h == 100) {
		int r = dut->r, g = dut->g, b = dut->b;
		shown = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
	}
	if (++h == LINE) { h = 0; if (++v == LINES) { v = 0; fieldbit ^= 1; } }
}

// one field; the daemon gets one pass per field (usleep(100 ms) = 6 fields)
static void field() {
	if (daemon_on) {
		if (daemon_sleep > 0) daemon_sleep--;
		else {
			int r = stream_tick(&S);
			if (r == TICK_WAIT) daemon_sleep = 6;
			if (r == TICK_STOP) { stream_stop(&S); daemon_on = false; printf("    (daemon exited at field %lld)\n", field_no); }
		}
	}
	if (d2_on) {
		if (d2_sleep > 0) d2_sleep--;
		else {
			int r = stream_tick(&S2);
			if (r == TICK_WAIT) d2_sleep = 6;
			if (r == TICK_STOP) { stream_stop(&S2); d2_on = false; printf("    (second daemon exited at field %lld)\n", field_no); }
		}
	}
	for (int i = 0; i < LINE * LINES; i++) cycle();
	field_no++;
}

static void check(bool ok, const char *what) {
	printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
	if (!ok) fail = true;
}

// run n fields; over the last `win` of them measure stream health
static void play(int n, int win, const char *what) {
	long long r0 = 0, w0 = 0; int match = 0, samples = 0;
	for (int i = 0; i < n; i++) {
		if (i == n - win) { r0 = ctrl[5]; w0 = ctrl[4]; }
		field();
		if (i >= n - win) {
			long long rd = ctrl[5];
			int a = 0x1000 + int(rd % FILE_FRAMES), b2 = 0x1000 + int((rd + 1) % FILE_FRAMES);
			samples++;
			if (ctrl[0] == MAGIC && (shown == a || shown == b2)) match++;
		}
	}
	long long adv = (long long)ctrl[5] - r0, wadv = (long long)ctrl[4] - w0;
	printf("  %s: reader +%lld, writer +%lld over %d fields; frame on screen matches reader in %d/%d fields\n",
	       what, adv, wadv, win, match, samples);
	char msg[160];
	snprintf(msg, sizeof msg, "%s: playing (reader advances, screen matches, daemon writing)", what);
	check(adv >= win / 2 - 4 && match >= samples * 95 / 100 && wadv > 0, msg);
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	dut = new Vvideo_player;

	// temporary .sbin: header + FILE_FRAMES frames, pixel = 0x1000 + frame
	char path[] = "/tmp/tbc_stream_tb_XXXXXX";
	int fd = mkstemp(path);
	FILE *f = fdopen(fd, "wb");
	uint64_t hdr[576] = {MAGIC, 360};
	fwrite(hdr, 1, HDR_BYTES, f);
	std::vector<uint16_t> fr(FRAME_BYTES / 2);
	for (int k = 0; k < FILE_FRAMES; k++) {
		std::fill(fr.begin(), fr.end(), uint16_t(0x1000 + k));
		fwrite(fr.data(), 1, FRAME_BYTES, f);
	}
	fclose(f);

	dut->reset = 1; dut->enable = 1; dut->loading = 0; dut->frame_count = 0;
	for (int i = 0; i < 64; i++) cycle();
	dut->reset = 0;

	auto start_daemon = [&]() {
		if (stream_open(&S, path) < 0) { printf("stream_open failed\n"); exit(2); }
		S.ctrl = ctrl; S.ring = ram.data();
		stream_start(&S);
		daemon_on = true; daemon_sleep = 0;
	};

	printf("Phase 1: normal streaming\n");
	start_daemon();
	play(700, 300, "1 normal");

	printf("Phase 2: Custom Video deselected for 300 fields, then selected\n");
	dut->enable = 0;
	for (int i = 0; i < 300; i++) field();
	dut->enable = 1;
	play(500, 300, "2 reselected");

	printf("Phase 3: daemon restarted (new session)\n");
	stream_stop(&S); daemon_on = false; fclose(S.f); free(S.buf);
	for (int i = 0; i < 20; i++) field();
	start_daemon();
	play(700, 300, "3 restarted");

	printf("Phase 4: clip loaded while the daemon runs\n");
	// what video_loader does: clear the magic, write the clip from the
	// start of the region (over ~30 fields), then report its frames
	dut->loading = 1;
	ctrl[0] = 0;
	const uint64_t clip_words = CLIP_FRAMES * CLIP_FRAME_W;
	for (int i = 0; i < 30; i++) {
		uint64_t a = clip_words * i / 30, b = clip_words * (i + 1) / 30;
		for (uint64_t w = a; w < b; w++) {
			uint16_t px = uint16_t(0xC000 | (w / CLIP_FRAME_W));
			uint64_t word = px * 0x0001000100010001ULL;
			memcpy(&ram[w * 8], &word, 8);
		}
		field();
	}
	dut->loading = 0; dut->frame_count = CLIP_FRAMES;
	int clip_shown = 0, samples = 0, seen[CLIP_FRAMES] = {0};
	for (int i = 0; i < 300; i++) {
		field();
		if (i >= 100) {
			samples++;
			if ((shown & 0xFFFC) == 0xC000) { clip_shown++; seen[shown & 3] = 1; }
		}
	}
	int distinct = seen[0] + seen[1] + seen[2] + seen[3];
	uint64_t bad = 0;
	for (uint64_t w = 0; w < clip_words; w++) {
		uint64_t word; memcpy(&word, &ram[w * 8], 8);
		if (word != uint16_t(0xC000 | (w / CLIP_FRAME_W)) * 0x0001000100010001ULL) bad++;
	}
	printf("  clip frames on screen in %d/%d fields (%d of %d distinct); corrupted clip words: %llu of %llu; magic %s\n",
	       clip_shown, samples, distinct, CLIP_FRAMES, (unsigned long long)bad, (unsigned long long)clip_words,
	       ctrl[0] == MAGIC ? "re-published" : "clear");
	check(clip_shown == samples && distinct == CLIP_FRAMES, "4a: the loaded clip plays (all its frames)");
	check(bad == 0, "4b: the clip in DDR is intact");
	check(ctrl[0] != MAGIC, "4c: the daemon did not re-publish the stream");

	printf("Phase 5: a second daemon starts while one is live\n");
	if (daemon_on) { fclose(S.f); free(S.buf); }
	start_daemon();                      // session A
	play(400, 100, "5 session A");
	if (stream_open(&S2, path) < 0) { printf("stream_open failed\n"); exit(2); }
	S2.ctrl = ctrl; S2.ring = ram.data();
	stream_start(&S2);                   // session B claims the block
	d2_on = true;
	play(800, 300, "5 session B");
	check(!daemon_on, "5: the older session stopped");

	unlink(path);
	dut->final();
	delete dut;
	printf("\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
	return fail ? 1 : 0;
}

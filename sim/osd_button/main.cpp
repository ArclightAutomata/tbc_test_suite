// SPDX-License-Identifier: GPL-2.0-or-later
// Button B -> OSD testbench (Verilator, osd_button as top).
//
// Joystick Button B is meant to close the test and reopen the OSD by
// driving the virtual OSD button (BUTTONS[0]). That line reaches the
// ARM through the gp_in register (sys_top.v), which Main_MiSTer polls
// in software - roughly every millisecond, not every clock. This
// models that: the "ARM" samples `press` once per POLL at a range of
// phase offsets and opens the OSD a few ms after it sees it high.
//
// Checks (57.272727 MHz clock, real-time scale):
//   A  a B press opens the OSD within 30 ms, at every poll phase
//   B  once the OSD is open, press releases within 5 ms and stays low
//   C  B pressed while the OSD is already open does nothing
//   D  if the ARM never responds, press still releases within 1 s
//   E  B held down across the OSD closing does not re-trigger
//
// Exit code 0 = all checks passed, 1 = a check failed.
#include "Vosd_button.h"
#include "verilated.h"
#include <cstdio>

static const long long CLK = 57272727;
static const long long MS = CLK / 1000;
static const long long POLL = MS;          // ARM poll period
static const long long ARM_LAT = 3 * MS;   // poll -> OSD shown

static Vosd_button *dut;
static long long t = 0;
static bool fail = false;

static void tick() {
	dut->clk = 1; dut->eval();
	dut->clk = 0; dut->eval();
	t++;
}

static void check(bool ok, const char *what) {
	printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what);
	if (!ok) fail = true;
}

// run for n cycles with a polling ARM; returns cycles until the OSD
// opened (-1 if it did not). arm_on=false models an unresponsive ARM.
struct Run { long long opened_at = -1, max_high_run = 0, high_while_open = 0; };
static Run run(long long n, long long phase, bool arm_on, long long btn_until) {
	Run r;
	long long seen_at = -1, high_run = 0;
	for (long long i = 0; i < n; i++) {
		dut->btn = (i < btn_until);
		if (arm_on && seen_at < 0 && !dut->osd_open && i >= phase && (i - phase) % POLL == 0 && dut->press)
			seen_at = i;
		if (seen_at >= 0 && !dut->osd_open && i >= seen_at + ARM_LAT) {
			dut->osd_open = 1;
			r.opened_at = i;
		}
		tick();
		high_run = dut->press ? high_run + 1 : 0;
		if (high_run > r.max_high_run) r.max_high_run = high_run;
		if (dut->osd_open && r.opened_at >= 0 && i > r.opened_at + 5 * MS && dut->press) r.high_while_open++;
	}
	return r;
}

static void idle(long long n) { dut->btn = 0; for (long long i = 0; i < n; i++) tick(); }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	dut = new Vosd_button;
	dut->clk = 0; dut->btn = 0; dut->osd_open = 0;
	idle(1000);

	printf("A/B: B press (held 100 ms) with the ARM polling every 1 ms\n");
	int opened = 0, released = 0;
	long long worst = 0;
	const int PHASES = 10;
	for (int p = 0; p < PHASES; p++) {
		dut->osd_open = 0; idle(10 * MS);
		Run r = run(200 * MS, p * POLL / PHASES, true, 100 * MS);
		if (r.opened_at >= 0) { opened++; if (r.opened_at > worst) worst = r.opened_at; }
		if (r.opened_at >= 0 && r.high_while_open == 0) released++;
	}
	printf("  OSD opened in %d of %d poll phases (worst %.1f ms)\n", opened, PHASES, worst / double(MS));
	check(opened == PHASES && worst <= 30 * MS, "A: every press opens the OSD within 30 ms");
	check(opened == PHASES && released == PHASES, "B: press releases within 5 ms of the OSD opening");

	printf("C: B pressed while the OSD is open\n");
	dut->osd_open = 1; idle(10 * MS);
	Run c = run(100 * MS, 0, false, 50 * MS);
	check(c.max_high_run == 0, "C: no press while the OSD is open");

	printf("D: ARM never responds\n");
	dut->osd_open = 0; idle(10 * MS);
	Run d = run(1500 * MS, 0, false, 1200 * MS);
	printf("  longest press: %.1f ms\n", d.max_high_run / double(MS));
	check(d.max_high_run <= CLK, "D: press never held longer than 1 s");
	idle(10 * MS);

	printf("E: B held while the OSD closes\n");
	dut->osd_open = 1; dut->btn = 1;
	for (long long i = 0; i < 10 * MS; i++) tick();
	dut->osd_open = 0;                 // OSD closes, B still held
	long long hi = 0;
	for (long long i = 0; i < 100 * MS; i++) { tick(); if (dut->press) hi++; }
	check(hi == 0, "E: holding B across the OSD closing does not re-trigger");

	dut->final();
	delete dut;
	printf("\n%s\n", fail ? "RESULT: FAIL" : "RESULT: PASS");
	return fail ? 1 : 0;
}

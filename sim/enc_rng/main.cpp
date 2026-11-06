// SPDX-License-Identifier: GPL-2.0-or-later
// Verilator driver: toggles the clock until the testbench reports done.
// Exit code 0 = all checks passed, 1 = a check failed.
#include "Vtb_enc_rng.h"
#include "verilated.h"

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	Vtb_enc_rng *tb = new Vtb_enc_rng;
	tb->clk = 0;
	tb->eval();
	while (!tb->done && !Verilated::gotFinish()) {
		tb->clk = 1; tb->eval();
		tb->clk = 0; tb->eval();
	}
	int rc = tb->failed ? 1 : 0;
	tb->final();
	delete tb;
	printf("\n%s\n", rc ? "RESULT: FAIL" : "RESULT: PASS");
	return rc;
}

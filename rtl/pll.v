// SPDX-License-Identifier: GPL-2.0-or-later
// megafunction wizard: %Altera PLL v17.0%
// PLL for TBC Test Suite
// Input:  50.0 MHz
// Output: 57.272727 MHz (16x NTSC color subcarrier = 16 x 3.579545 MHz)

`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk
		output wire  locked    //  locked.export
	);

	pll_0002 pll_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.locked   (locked)
	);

endmodule

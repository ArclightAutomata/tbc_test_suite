// SPDX-License-Identifier: GPL-2.0-or-later
// Wrapper for the Jitter / Wow level testbench: both generators side by
// side, driven from main.cpp.
module tb_levels (
	input                clk,
	input                reset,
	input                new_line,
	input  [2:0]         jit_mode,
	input  [2:0]         wow_mode,
	input  [31:0]        rng,
	output signed [12:0] jit_off,
	output signed [12:0] wow_llm
);
error_jitter jit (
	.clk(clk), .reset(reset), .mode(jit_mode), .ramp(8'd0),
	.new_line(new_line), .rng(rng), .h_offset(jit_off)
);
error_wow wow (
	.clk(clk), .reset(reset), .wow_mode(wow_mode), .flutter_mode(2'd0),
	.ramp(8'd0), .new_line(new_line), .line_length_mod(wow_llm)
);
endmodule

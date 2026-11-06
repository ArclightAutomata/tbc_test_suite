// SPDX-License-Identifier: GPL-2.0-or-later
// Sync waveform testbench wrapper: ntsc_timing feeding the framework's
// csync combiner exactly as the core is wired, so the C++ driver sees
// the composite sync the IO board's sync-on-green actually receives:
// core-generated composite sync on HS, the framework csync vsync input
// tied low (framework mod #3) - pass-through.
module tb_sync (
	input        clk,
	input        reset,
	input        pal,
	input        interlace_en,
	input signed [12:0] h_offset,     // timing errors (stress phase)
	input signed [12:0] llm,
	input  [8:0] roll_shift,
	input        pulse_cross,
	output       sync,
	output       burst,
	output       active,
	output       new_field,
	output       field,
	output       new_line
);

wire hsync, vsync, csync_core, burst_window, active_video;
wire [11:0] h_count;
wire [8:0]  v_count;

ntsc_timing t (
	.clk(clk), .reset(reset), .pal(pal), .interlace_en(interlace_en), .v_shift(2'd0),
	.line_length_mod(llm), .h_offset(h_offset), .roll_shift(roll_shift),
	.pulse_cross(pulse_cross), .pc_enhanced(pulse_cross),
	.h_count(h_count), .v_count(v_count), .field(field),
	.hsync(hsync), .vsync(vsync), .hblank(), .vblank(),
	.burst_window(burst_window), .active_video(active_video),
	.new_line(new_line), .new_field(new_field), .pc_blank(), .disp_sync(),
	.csync(csync_core)
);

framework_csync fc (.clk(clk), .hsync(csync_core), .vsync(1'b0), .csync(sync));

assign burst  = burst_window;
assign active = active_video;

endmodule

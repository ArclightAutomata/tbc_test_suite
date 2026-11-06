// SPDX-License-Identifier: GPL-2.0-or-later
// Mod Staircase / Mod Ramp chroma testbench wrapper: the real
// pattern_gen feeding the real yc_encoder (forced-chroma path) on NTSC
// line timing, so the C++ driver can demodulate the chroma against the
// line's own burst.
module tb_modstair (
	input        clk,
	input        reset,
	input  [4:0] pattern,
	output [7:0] c_out,
	output [7:0] y_out,
	output reg [11:0] h = 12'd0
);
reg new_line = 0;
always @(posedge clk) begin
	h <= (h == 12'd3639) ? 12'd0 : h + 12'd1;
	new_line <= (h == 12'd3639);
end
wire active = (h >= 12'd668) && (h < 12'd3568);
wire burst  = (h >= 12'd327) && (h <= 12'd470);

wire [7:0] r, g, b;
wire cf; wire signed [9:0] cu;
pattern_gen pg (
	.clk(clk), .reset(reset), .h_pos(active ? h - 12'd668 : 12'd0), .v_pos(9'd100),
	.active(active), .new_field(1'b0), .pattern_sel(pattern), .solid_color(3'd0),
	.window_bounce(1'b0), .smpte_100(1'b0), .sweep_active(1'b0), .ramp_level(8'd0),
	.r(r), .g(g), .b(b), .chroma_force(cf), .chroma_u(cu)
);
yc_encoder enc (
	.clk(clk), .reset(reset), .r(r), .g(g), .b(b), .burst_window(burst),
	.new_line(new_line), .seed(8'd0), .reload(1'b0), .new_field(1'b0),
	.pal(1'b0), .cvbs(1'b0), .hue_offset(8'd0), .hue_drift(1'b0), .burst_level(3'd0),
	.sc_mode(3'd0), .chroma_delay(8'd0), .noise_mode(2'd0), .chroma_bw(1'b0),
	.chroma_force(cf), .chroma_u(cu), .y_out(y_out), .c_out(c_out)
);
endmodule

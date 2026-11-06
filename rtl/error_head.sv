// SPDX-License-Identifier: GPL-2.0-or-later
// Video head condition - dirty and clogged heads.
//
// A VHS deck reads alternate fields with its two heads (A and B), and
// the handoff happens at the head switch a few lines above the bottom
// of the picture (line 233, the same point as rtl/error_headswitch.sv).
// So each head's span runs from line 233 of one field to line 232 of
// the next - through the vertical interval, including vsync.
//
// Unlike a dropout (a brief tape defect), head condition is a steady
// state of the deck: a dirty head lowers the RF level for every line
// it reads, so its fields carry continuous snow (FM noise), many tiny
// white specks, a softer picture and, when bad, chroma the deck's
// color killer drops. One head is usually worse than the other, so
// the noise flickers at the field rate. A fully clogged head reads
// nothing: its fields are pure snow with no sync at all.
//
// Modes (outputs apply on the head(s) listed):
//   1 Dirty        A: snow +/-8, specks ~15/field
//                  B: snow +/-16, specks ~58/field
//   2 Very Dirty   A: as Dirty's A
//                  B: snow +/-47, specks ~460/field, soft luma, no chroma
//   3 One Clogged  A: clean;  B: pure snow, sync removed
//   4 Both Clogged pure snow on every field, sync removed (loss of signal)
// The snow is band-limited (a new value every 4 samples, ~14 MHz) and
// triangular (sum of two uniforms). All randomness comes from a private
// stream seeded from the OSD seed and reloaded at every run start, and
// the head phase restarts there too, so seeded runs replay exactly.

module error_head (
	input         clk,
	input         reset,
	input  [2:0]  mode,         // gated by the error run at the top level
	input  [8:0]  v_count,
	input         new_line,
	input  [7:0]  seed,
	input         reload,

	output reg        head_b,     // head B is reading this line
	output reg signed [8:0] noise, // luma to add (snow + specks)
	output            snow,       // replace the whole signal with snow_luma
	output reg [7:0]  snow_luma,
	output            cmute,      // chroma dropped (color killer)
	output            soften,     // soften luma (lost high frequencies)
	output            nosync      // remove composite sync
);

localparam [8:0] SWITCH_LINE = 9'd233;

// head phase: toggles at the head switch; restarts on head A at a run start
always @(posedge clk) begin
	if (reset || reload || mode == 3'd0) head_b <= 1'b0;
	else if (new_line && v_count == SWITCH_LINE) head_b <= ~head_b;
end

wire [31:0] r;
prng head_rng (
	.clk(clk), .reset(reset), .seed(seed ^ 8'h27), .reload(reload),
	.advance(mode != 3'd0), .rng_value(r)
);

// per-head settings
reg [1:0]  amp;        // snow scale: 0 none, 1 = >>>3, 2 = >>>2, 3 = 3/4
reg [15:0] speck_p;    // speck start odds per sample, out of 65536
always @(*) begin
	amp = 2'd0; speck_p = 16'd0;
	case (mode)
		3'd1: if (head_b) begin amp = 2'd2; speck_p = 16'd4; end
		      else        begin amp = 2'd1; speck_p = 16'd1; end
		3'd2: if (head_b) begin amp = 2'd3; speck_p = 16'd32; end
		      else        begin amp = 2'd1; speck_p = 16'd1; end
		default: ;
	endcase
end

assign snow   = (mode == 3'd4) || (mode == 3'd3 && head_b);
assign nosync = snow;
assign cmute  = snow || (mode == 3'd2 && head_b);
assign soften = (mode == 3'd2 && head_b);

// band-limited triangular snow: -63..+63, a new value every 4 samples
reg [1:0] div;
reg signed [7:0] tnoise;
always @(posedge clk) begin
	if (reset || reload || mode == 3'd0) begin
		div <= 2'd0; tnoise <= 8'sd0; snow_luma <= 8'd128;
	end else begin
		div <= div + 2'd1;
		if (div == 2'd0) begin
			tnoise <= $signed({2'b0, r[5:0]}) + $signed({2'b0, r[11:6]}) - 8'sd63;
			// clogged: wide snow around mid-gray, 2..254
			snow_luma <= 8'd128 + {r[17:12], 1'b0} - {r[23:18], 1'b0};
		end
	end
end

wire signed [8:0] tn9 = {tnoise[7], tnoise};
wire signed [8:0] snow_add = (amp == 2'd1) ? (tn9 >>> 3) :
                             (amp == 2'd2) ? (tn9 >>> 2) :
                             (amp == 2'd3) ? ((tn9 >>> 1) + (tn9 >>> 2)) : 9'sd0;

// tiny white specks: 12-42 samples (0.2-0.7 us) of +96 riding the picture
reg [5:0] speck_rem;
always @(posedge clk) begin
	if (reset || reload || mode == 3'd0) speck_rem <= 6'd0;
	else if (speck_rem != 0)              speck_rem <= speck_rem - 6'd1;
	else if (r[31:16] < speck_p)          speck_rem <= {1'b0, r[27:24], 1'b0} + 6'd12;
end

always @(posedge clk) begin
	if (reset || reload || mode == 3'd0) noise <= 9'sd0;
	else noise <= snow_add + ((speck_rem != 0) ? 9'sd96 : 9'sd0);
end

endmodule

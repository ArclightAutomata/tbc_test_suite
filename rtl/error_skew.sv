// SPDX-License-Identifier: GPL-2.0-or-later
// Skew Error Generator
// Horizontal offset that varies by vertical position (tape tension /
// head drum speed errors)
//
// Top Heavy and Bottom Heavy are different SHAPES, not one slant at two
// DC levels (a TV's AFC or a TBC removes any constant offset, so a
// shifted copy of the same slant is the same defect):
//   Top Heavy    - the tension hook after the head switch: the top of
//                  the picture starts ~1.1 us early and curves back into
//                  place by line 80 (quadratic), straight below that.
//                  The offset steps in at the start of vertical
//                  blanking and holds through vsync, so the jump itself
//                  is never in the picture.
//   Bottom Heavy - the mirror: straight until line 160, then curving
//                  ~1.1 us late by the last visible line; it ramps back
//                  to zero during vertical blanking.
//   Moderate / Severe - linear slants across the whole field, centered
//                  on line 131 (+/-65 / +/-262 samples).
// Visible lines are 0-239 for both NTSC and PAL; blanking follows.

module error_skew (
	input        clk,
	input        reset,
	input  [2:0] mode,        // 0=Off, 1=Top Heavy, 2=Bottom Heavy, 3=Moderate, 4=Severe
	input  [8:0] v_count,     // current line number (0-261 NTSC, 0-312 PAL)
	input        new_line,    // pulse at start of each line

	output reg signed [12:0] h_offset  // horizontal offset for this line
);

localparam [8:0] VIS  = 9'd240;   // first blanking line
localparam [8:0] BEND = 9'd80;    // lines over which a heavy mode bends

wire signed [9:0] line_centered = $signed({1'b0, v_count}) - 10'sd131; // -131 to +181

// Quadratic bend: k = 0..80 -> k^2 * 41 / 4096 = 0..64 samples (~1.1 us)
wire [8:0]  k_top = (v_count < BEND) ? (BEND - v_count) : 9'd0;              // 80..1 at the top
wire [8:0]  k_bot = (v_count >= VIS - BEND && v_count < VIS)
                    ? (v_count - (VIS - BEND) + 9'd1) : 9'd0;                // 1..80 at the bottom
wire [12:0] sq_top = k_top[6:0] * k_top[6:0];
wire [12:0] sq_bot = k_bot[6:0] * k_bot[6:0];
wire [18:0] pr_top = {6'd0, sq_top} * 19'd41;     // up to 262400: 19 bits
wire [18:0] pr_bot = {6'd0, sq_bot} * 19'd41;
wire [6:0]  bend_top = pr_top[18:12];
wire [6:0]  bend_bot = pr_bot[18:12];

// Bottom Heavy's return through blanking: 64 down to 0 over 21 lines
wire [8:0]  kb = v_count - VIS;
wire [6:0]  ret_bot = (v_count >= VIS && kb < 9'd21) ? (7'd64 - kb[6:0] * 7'd3) : 7'd0;

always @(posedge clk) begin
	if (reset) begin
		h_offset <= 13'sd0;
	end else if (new_line) begin
		case (mode)
			3'd0: h_offset <= 13'sd0;  // Off

			3'd1:  // Top Heavy: hook at the top, held through blanking
				h_offset <= (v_count >= VIS) ? -13'sd64 : -$signed({6'd0, bend_top});

			3'd2:  // Bottom Heavy: curl at the bottom, returns in blanking
				h_offset <= (v_count >= VIS) ? $signed({6'd0, ret_bot}) : $signed({6'd0, bend_bot});

			3'd3: h_offset <= $signed(line_centered) >>> 1;   // Moderate: linear, centered
			3'd4: h_offset <= $signed(line_centered) <<< 1;   // Severe: linear, large

			default: h_offset <= 13'sd0;
		endcase
	end
end

endmodule

// SPDX-License-Identifier: GPL-2.0-or-later
// Picture Roll Error Generator
//
// Rolls the picture by ROTATING THE VSYNC POSITION through the field, a
// little more each field. The monitor stays locked (field rate never
// changes) but the picture-to-vsync phase slides continuously, so the
// image visibly rolls through the screen - the classic lost-vertical-
// hold look.
//
// (The first implementation emitted a constant field-length offset
// instead. That just presents a stable picture at an off-spec field
// rate - 261 lines is 60.3 Hz - which any monitor's vertical AFC locks
// to without complaint, so nothing visibly rolled.)

module error_roll (
	input        clk,
	input        reset,
	input  [2:0] mode,       // 0=Off, 1=Slow Up, 2=Slow Down, 3=Fast Up, 4=Fast Down, 5=Drift
	input        pal,
	input        new_field,  // pulse at start of each field

	output reg [8:0] roll_shift  // vsync phase rotation in lines, 0..wrap-1
);

// Phase accumulator modulo the field height. Interlace alternates
// 263/262 (313/312) line fields; using the long field as the modulus
// costs at most a one-line hiccup per revolution, invisible in a roll.
wire [8:0] wrap = pal ? 9'd313 : 9'd263;

// Lines of vsync advance per field. Positive = vsync earlier = picture
// slides down the screen. Slow = one revolution in ~4.4 s, Fast ~0.9 s.
reg signed [3:0] step;
always @(*) begin
	case (mode)
		3'd1:    step = -4'sd1;  // Slow Up
		3'd2:    step =  4'sd1;  // Slow Down
		3'd3:    step = -4'sd5;  // Fast Up
		3'd4:    step =  4'sd5;  // Fast Down
		default: step =  4'sd0;
	endcase
end

// Drift mode: bounded triangle wobble, +/-8 lines over ~8.5 s - a
// vertical hold sitting right on the edge, bouncing but never flipping.
reg [8:0] drift_cnt;
wire [3:0] tri_mag = drift_cnt[7:4];
wire signed [5:0] drift_off = drift_cnt[8] ? ($signed({2'd0, tri_mag}) - 6'sd8)
                                           : (6'sd8 - $signed({2'd0, tri_mag}));

wire signed [10:0] stepped = $signed({2'b0, roll_shift}) + {{7{step[3]}}, step};
wire signed [10:0] wrapped = (stepped < 0)                      ? stepped + $signed({2'b0, wrap}) :
                             (stepped >= $signed({2'b0, wrap})) ? stepped - $signed({2'b0, wrap}) :
                                                                  stepped;

wire signed [10:0] drift_ext = {{5{drift_off[5]}}, drift_off};
wire signed [10:0] drift_mod = (drift_off < 0) ? drift_ext + $signed({2'b0, wrap}) : drift_ext;

always @(posedge clk) begin
	if (reset || mode == 3'd0) begin
		roll_shift <= 9'd0;
		drift_cnt  <= 9'd0;
	end else if (new_field) begin
		if (mode == 3'd5) begin
			drift_cnt  <= drift_cnt + 9'd1;
			roll_shift <= drift_mod[8:0];
		end else begin
			roll_shift <= wrapped[8:0];
		end
	end
end

endmodule

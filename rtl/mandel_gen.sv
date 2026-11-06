// SPDX-License-Identifier: GPL-2.0-or-later
// Mandelbrot pattern: a real-time zoom generated in the FPGA.
//
// 360 pixels per line (pixel-doubled across the 2880-sample active
// line, like the streaming format), every line of every field computed
// live - each field draws its own lines of the 480-line frame, so the
// image is properly interlaced. Each line is computed during the line
// before it (line 0 of a field during vertical blanking) into a double
// line buffer.
//
// Compute: NE engines in lockstep, each doing one Mandelbrot iteration
// per clock (z <- z^2 + c with two 27x27 multiplies:
// x^2 - y^2 = (x+y)(x-y) and 2xy), a fixed IT iterations per pixel.
// Engine k handles pixels k, k+NE, k+2NE, ... so a line takes
// (360/NE) * IT clocks = 1920 with 12 engines and 64 iterations - less
// than the shortest line the timing errors can produce (2048 clocks).
//
// Fixed point Q2.24 (27 bits: sign, 2 integer, 24 fraction bits). A
// pixel escapes when |x| or |y| reaches 2 (checked on the wider
// pre-truncation sum, so nothing wraps); escaped pixels stop updating.
//
// Animation: an exponential zoom toward the Misiurewicz point M23,2
// (-0.10109636 + 0.95628651i), ~2x every 3 s down to ~8000x, then it
// starts over; the palette cycles one step per frame. A Misiurewicz
// point sits on the set's boundary and is self-similar, so the frame
// stays full of dendrites and spirals at every depth (<= 5% inside-set
// black at 64 iterations; Seahorse Valley, tried first, went 50-90%
// black). Palette: a blue-white-orange cosine gradient (one sine table,
// channels offset 0/26/51 steps), with the far exterior faded toward
// dark so the set stands out in the wide shots. `restart` (the error run start) resets both, so a
// seeded run replays the same frames.
module mandel_gen #(
	parameter NE = 12,             // engines
	parameter IT = 64,             // iterations per pixel
	parameter [31:0] START_U = 32'd11650 << 16  // zoom start (sim can start deep)
) (
	input             clk,
	input             reset,
	input             restart,     // run start: zoom + color cycle from the top
	input             new_line,
	input      [8:0]  v_count,
	input             field,
	input             interlace,
	input      [11:0] h_pos,       // 0-2899 within the active line
	input             active,
	output reg [7:0]  r,
	output reg [7:0]  g,
	output reg [7:0]  b
);

localparam W     = 360;
localparam SLOTS = W / NE;         // pixels per engine per line (30)

// ---- zoom state (Q2.24 coordinates) ----
localparam signed [26:0] CX = -27'sd1696115;    // -0.10109636
localparam signed [26:0] CY =  27'sd16043825;   //  0.95628651
localparam [31:0] U0 = START_U;                 // 11650<<16: 4.0 units across
reg  [31:0] u_f;                                // zoom unit, 16 fraction bits
reg  [7:0]  cyc;                                // palette cycle
// Pixel steps x 16u, y 9u (square pixels: 360 px x 480 lines at 4:3),
// carried with 8 bits below the Q2.24 LSB, as are the coordinate
// accumulators; the engines take the Q2.24 part. With whole-LSB steps
// the deepest part of the zoom could only change scale in ~6% jumps
// (sx ~ 16 LSB): the picture held for up to 8 frames, then jumped -
// the zoom visibly stuttered toward the end of the loop.
wire [27:0] sxf = u_f[31:4];                    // 16u, 8 fraction bits
wire [27:0] syf = {1'b0, u_f[31:5]} + {4'd0, u_f[31:8]}; // 8u + u = 9u
reg  signed [36:0] cx0, cy0;                    // Q2.24 + 8 fraction bits
reg  signed [36:0] sx_q, sy_q;

// ---- line scheduling (v_count is valid one clock after new_line) ----
reg nl_d;
always @(posedge clk) nl_d <= new_line;
wire        nxt_f0   = interlace ? field : 1'b1;    // next field is field 0
wire        nxt_fld  = interlace ? ~field : 1'b0;

reg         run;                 // computing a line
reg  [5:0]  it;                  // iteration within the slot
reg  [4:0]  slot;
reg         wbuf;                // buffer being written
reg  signed [36:0] cy_line;     // Q2.24 + 8 fraction bits
reg  [2:0]  fstage;              // frame-update pipeline

// per-engine state
reg  signed [26:0] zx [0:NE-1];
reg  signed [26:0] zy [0:NE-1];
reg  signed [36:0] ccx [0:NE-1];   // Q2.24 + 8 fraction bits
reg         esc [0:NE-1];
reg  [6:0]  cnt [0:NE-1];

// line buffers: one NE*7-bit word per slot
reg  [NE*7-1:0] lbuf0 [0:SLOTS-1];
reg  [NE*7-1:0] lbuf1 [0:SLOTS-1];

// ---- per-engine iteration datapath (combinational, one step per clock) ----
wire signed [31:0] nx [0:NE-1];
wire signed [31:0] ny [0:NE-1];
wire               esc_now [0:NE-1];
genvar gk;
generate for (gk = 0; gk < NE; gk = gk + 1) begin : eng
	// |x|,|y| < 2 while iterating, so x+y and x-y fit 27 bits (|.| < 4)
	wire signed [26:0] s  = zx[gk] + zy[gk];
	wire signed [26:0] d  = zx[gk] - zy[gk];
	wire signed [53:0] p1 = s * d;                     // x^2 - y^2   (Q4.48)
	wire signed [53:0] p2 = zx[gk] * zy[gk];           // xy          (Q4.48)
	assign nx[gk] = 32'(p1 >>> 24) + 32'(ccx[gk] >>> 8);
	assign ny[gk] = 32'(p2 >>> 23) + 32'(cy_line >>> 8);   // 2xy + cy
	assign esc_now[gk] = (nx[gk] >= 32'sd33554432) || (nx[gk] <= -32'sd33554432) ||
	                     (ny[gk] >= 32'sd33554432) || (ny[gk] <= -32'sd33554432);   // |.| >= 2.0
end endgenerate

integer k;
always @(posedge clk) begin
	if (reset || restart) begin
		u_f <= U0;
		cyc <= 8'd0;
		fstage <= 3'd0;
		run <= 1'b0;
	end else begin
		// frame update on the first blanking line before a field-0 field
		// (not earlier: the palette cycle would change under the last
		// displayed line); line 0 starts computing on the next line
		if (nl_d && v_count == 9'd240 && nxt_f0) fstage <= 3'd1;
		case (fstage)
			3'd1: begin
				u_f <= (u_f - (u_f >> 7) < (32'd1 << 16)) ? U0 : (u_f - (u_f >> 7));
				cyc <= cyc + 8'd1;
				fstage <= 3'd2;
			end
			3'd2: begin sx_q <= $signed({9'd0, sxf}); sy_q <= $signed({9'd0, syf}); fstage <= 3'd3; end
			3'd3: begin
				// cx0 = CX - 180 sx (180 = 128+32+16+4), cy0 = CY - 240 sy (256-16)
				cx0 <= ($signed({{10{CX[26]}}, CX}) <<< 8) - ((sx_q <<< 7) + (sx_q <<< 5) + (sx_q <<< 4) + (sx_q <<< 2));
				cy0 <= ($signed({{10{CY[26]}}, CY}) <<< 8) - ((sy_q <<< 8) - (sy_q <<< 4));
				fstage <= 3'd0;
			end
			default: ;
		endcase

		// start a line computation
		if (nl_d && (v_count < 9'd239 || v_count == 9'd241)) begin
			run  <= 1'b1;
			it   <= 6'd0;
			slot <= 5'd0;
			if (v_count == 9'd241) begin
				// line 0 of the next field: frame line = field parity
				wbuf    <= 1'b0;
				cy_line <= cy0 + (nxt_fld ? sy_q : 37'sd0);
			end else begin
				// line v+1 of this field: frame line advances by 2
				wbuf    <= ~v_count[0];
				cy_line <= cy_line + (sy_q <<< 1);
			end
			for (k = 0; k < NE; k = k + 1) begin
				ccx[k] <= cx0 + sx_q * k;          // constant multiples
				zx[k] <= 27'sd0; zy[k] <= 27'sd0; esc[k] <= 1'b0; cnt[k] <= IT[6:0];
			end
		end else if (run) begin
			it <= it + 6'd1;
			for (k = 0; k < NE; k = k + 1) begin
				if (!esc[k]) begin
					if (esc_now[k]) begin
						esc[k] <= 1'b1;
						cnt[k] <= {1'b0, it};
					end else begin
						zx[k] <= nx[k][26:0];
						zy[k] <= ny[k][26:0];
					end
				end
			end
			if (it == IT - 1) begin
				// slot done: store every engine's count (escape iteration,
				// or IT = inside the set), then start the next slot
				for (k = 0; k < NE; k = k + 1) begin
					if (wbuf) lbuf1[slot][k*7 +: 7] <= esc[k] ? cnt[k] : (esc_now[k] ? {1'b0, it} : IT[6:0]);
					else      lbuf0[slot][k*7 +: 7] <= esc[k] ? cnt[k] : (esc_now[k] ? {1'b0, it} : IT[6:0]);
					ccx[k] <= ccx[k] + sx_q * NE;
					zx[k] <= 27'sd0; zy[k] <= 27'sd0; esc[k] <= 1'b0; cnt[k] <= IT[6:0];
				end
				if (slot == SLOTS - 1) run <= 1'b0;
				else slot <= slot + 5'd1;
			end
		end
	end
end

// ---- display: pixel px = h_pos / 8 -> (slot, lane) = (px / NE, px % NE) ----
reg  [4:0]  d_slot;
reg  [3:0]  d_lane;
reg  [2:0]  d_sub;
reg         d_on;
// h_pos is 0 from the start of the line up to the first active sample
// (it is combinational in the top level, while `active` arrives one
// clock later), so the counters arm on h_pos == 0 and the output is
// gated by `active` separately.
always @(posedge clk) begin
	if (h_pos == 12'd0) begin
		d_slot <= 5'd0; d_lane <= 4'd0; d_sub <= 3'd0;
		d_on   <= 1'b1;
	end else begin
		d_sub <= d_sub + 3'd1;
		if (d_sub == 3'd7) begin
			if (d_lane == NE - 1) begin
				d_lane <= 4'd0;
				if (d_slot == SLOTS - 1) d_on <= 1'b0;
				else d_slot <= d_slot + 5'd1;
			end else d_lane <= d_lane + 4'd1;
		end
	end
end
wire [NE*7-1:0] dword = v_count[0] ? lbuf1[d_slot] : lbuf0[d_slot];

// palette, pipelined in three stages (lane select -> sine lookup ->
// brightness) - in one clock this path missed timing
reg  [6:0] n1;
reg        on1, on2, in2, dim2;
reg  [4:0] br2;
reg  [7:0] vr2, vg2, vb2;
wire [7:0] pidx = {n1[4:0], 3'b000} + cyc;
wire signed [10:0] sr, sg, sb;
sine_lut lr (.addr(pidx),          .data(sr));
sine_lut lg (.addr(pidx + 8'd26),  .data(sg));
sine_lut lb (.addr(pidx + 8'd51),  .data(sb));
wire [12:0] pr = vr2 * br2, pg = vg2 * br2, pb = vb2 * br2;
always @(posedge clk) begin
	// stage 1: this pixel's count
	n1  <= dword[d_lane*7 +: 7];
	on1 <= d_on && active;
	// stage 2: palette lookup; far-exterior brightness (4 + n)/16 for n < 12
	vr2 <= 8'd128 + sr[8:1];
	vg2 <= 8'd128 + sg[8:1];
	vb2 <= 8'd128 + sb[8:1];
	dim2 <= (n1 < 7'd12);
	br2  <= 5'd4 + n1[3:0];
	in2  <= (n1 == IT[6:0]);
	on2  <= on1;
	// stage 3: output (black outside the image and inside the set)
	if (!on2 || in2) begin
		{r, g, b} <= 24'd0;
	end else begin
		r <= dim2 ? pr[11:4] : vr2;
		g <= dim2 ? pg[11:4] : vg2;
		b <= dim2 ? pb[11:4] : vb2;
	end
end

endmodule

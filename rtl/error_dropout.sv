// SPDX-License-Identifier: GPL-2.0-or-later
// Dropout Generator - tape defect simulation.
//
// A dropout is loss of RF envelope off the tape (a spot of missing or
// lifted oxide): the FM demod output collapses into bright noise,
// chroma vanishes, and - unlike the timing errors - it is a defect in
// the DEMODULATED signal, so it gates the encoded Y/C downstream of the
// encoder (rtl/out_stage.sv). Events longer than the remaining line run
// straight through hsync and the burst, like real tape. A dirty or
// clogged HEAD is a different, continuous defect: rtl/error_head.sv.
//
// Shape of one event, as a deck without dropout compensation shows it:
//   - length is short-weighted like real oxide defects: (64..127) << e
//     samples with e = 0,1,2,3,4 at p = 1/2, 1/4, 1/8, 1/16, 1/16 -
//     half under 2.2 us, 7/8 under 9 us, the longest ~35 us
//   - soft onset: the streak blends in over 16 samples (~0.3 us)
//   - dark tail: when the RF returns the demod undershoots, leaving a
//     black streak a quarter of the event long (+16 samples) that
//     fades back into the picture over its last 16 samples
// The out stage blends with `mix` (0-16 sixteenths) toward `luma`
// (sparkle in the body, black in the tail) - or, with Dropout Comp on,
// toward the line above from its 1H delay line.
//
// Modes: 1 Light  (~1 streak/s - a worn tape)
//        2 Moderate (~10/s)
//        3 Heavy  (~100/s - badly damaged tape)
//        4 Stress (~1000/s, lengths one octave longer: 128-2032
//                  samples, mean ~480 - beyond real tape, for stress
//                  testing a TBC's dropout and sync handling)
//        5 Crease (clusters of streaks at the same horizontal position
//                  across 4-11 consecutive lines, plus light singles)
//
// Two private PRNG streams, both seeded from the OSD seed and reloaded
// at every run start, so seeded runs stay reproducible:
//   trig_rng - event TIMING (the dice) plus crease jitter/duration. It
//     used to be the shared per-line word, whose high bits also feed
//     Jitter and Head Switch: every dropout line forced Jitter's sign
//     positive (caught by sim/err_rng).
//   mag_rng  - event SIZE and POSITION. The trigger condition pins the
//     high bits of its own draw (dice < 13 means bits 31:20 are zero),
//     so sizes cannot come from the dice word: that made every Light
//     dropout ~2.3 us long and every crease land on lines 46-47 (caught
//     by sim/dropout).

module error_dropout (
	input         clk,
	input         reset,
	input  [2:0]  mode,
	input  [11:0] h_pos,
	input  [8:0]  v_count,
	input         new_line,
	input         new_field,
	input  [7:0]  seed,         // OSD seed (private streams)
	input         reload,       // restart the private streams (run start)

	output        act,          // dropout active this sample (body or tail)
	output        body,         // in the bright body (not the dark tail)
	output [4:0]  mix,          // blend weight toward luma, 0-16 sixteenths
	output [7:0]  luma          // level to blend toward: sparkle, or black in the tail
);

// intra-line sparkle: a private xorshift32 stream stepping every sample,
// so each sample gets a fresh, uncorrelated value and the texture only
// repeats after 2^32-1 samples (~75 s). It reloads from the seed at
// every run start, so the texture replays with the seed like everything
// else. (It was a 17-bit LFSR shifting one bit per sample: the texture
// repeated every ~36 lines and neighboring samples shared 5 of 6 bits.)
wire [31:0] sparkle;
prng sparkle_rng (
	.clk(clk), .reset(reset), .seed(seed ^ 8'h9E), .reload(reload),
	.advance(mode != 3'd0), .rng_value(sparkle)
);
wire [7:0] sparkle_lvl = 8'd185 + {2'b0, sparkle[5:0]};   // 185-248 bright FM-noise sparkle

// event state
reg [12:0] spill_rem;      // samples remaining (crosses line boundaries)
reg [11:0] seg_start;      // scheduled segment this line (crease)
reg [12:0] seg_len;
reg        seg_on;
reg  [9:0] tail_len;       // dark tail length for the running event
reg  [9:0] tail_rem;       // tail samples remaining
reg  [4:0] ramp;           // onset blend, 1..16

// crease state: a physical tape crease is a STATIONARY defect - the
// same screen zone streaks on every field for the second or so the
// damaged tape takes to pass the head
reg [8:0]  crease_v;        // first affected line
reg [3:0]  crease_lines;    // lines tall
reg [11:0] crease_h;
reg [12:0] crease_len;
reg [6:0]  crease_fields;   // persistence in fields

wire [31:0] rng;
prng trig_rng (
	.clk(clk), .reset(reset), .seed(seed ^ 8'h6D), .reload(reload),
	.advance(new_line && mode != 3'd0), .rng_value(rng)
);
wire [15:0] dice = rng[31:16];
// per-line odds out of 65536 at 15734 lines/s: 4 -> ~1/s, 42 -> ~10/s,
// 420 -> ~100/s, 4200 -> ~1000/s
wire trig_single = (mode == 3'd1) ? (dice < 16'd4)    :
                   (mode == 3'd2) ? (dice < 16'd42)   :
                   (mode == 3'd3) ? (dice < 16'd420)  :
                   (mode == 3'd4) ? (dice < 16'd4200) :
                   (mode == 3'd5) ? (dice < 16'd4)    : 1'b0;
wire trig_crease = (mode == 3'd5) && (dice >= 16'd4) && (dice < 16'd7);

// Private size/position stream: same seed, different expansion, advances
// once per line while dropouts run (mode is already gated by the OSD).
wire [31:0] mag;
prng mag_rng (
	.clk(clk),
	.reset(reset),
	.seed(seed ^ 8'hC3),
	.reload(reload),
	.advance(new_line && mode != 3'd0),
	.rng_value(mag)
);

// short-weighted length: mantissa 64-127, exponent = leading ones of
// mag[9:6] (0-4), so each doubling is half as likely; 64-2032 samples.
// Stress starts one octave up (exponent 1-4: 128-2032 samples).
wire [2:0]  lead_ones = !mag[6] ? 3'd0 : !mag[7] ? 3'd1 : !mag[8] ? 3'd2 : !mag[9] ? 3'd3 : 3'd4;
wire [2:0]  len_exp   = (mode == 3'd4 && lead_ones != 3'd4) ? lead_ones + 3'd1 : lead_ones;
wire [12:0] rnd_len   = {6'd1, mag[5:0]} << len_exp;      // 1.1-35 us
wire [11:0] rnd_start = {1'b0, mag[21:11]} + 12'd300;   // within the line

always @(posedge clk) begin
	if (reset || mode == 3'd0) begin
		spill_rem     <= 13'd0;
		seg_on        <= 1'b0;
		crease_fields <= 7'd0;
		tail_rem      <= 10'd0;
		tail_len      <= 10'd0;
		ramp          <= 5'd1;
	end else begin
		if (spill_rem != 0 && !(new_line && seg_on)) begin
			spill_rem <= spill_rem - 13'd1;
			if (ramp != 5'd16) ramp <= ramp + 5'd1;
			if (spill_rem == 13'd1) tail_rem <= tail_len;   // body ends: dark tail
		end else if (tail_rem != 0) begin
			tail_rem <= tail_rem - 10'd1;
		end

		if (new_field && crease_fields != 0)
			crease_fields <= crease_fields - 7'd1;

		if (new_line) begin
			seg_on <= 1'b0;

			// active crease: streak the same zone on every field pass
			if (crease_fields != 0 && v_count >= crease_v &&
			    v_count < crease_v + {5'd0, crease_lines}) begin
				seg_start <= crease_h + {8'd0, rng[3:0]};   // slight jitter
				seg_len   <= crease_len;
				seg_on    <= 1'b1;
			end else if (crease_fields == 0 && trig_crease) begin
				crease_h      <= rnd_start;
				crease_len    <= rnd_len;
				crease_v      <= {2'd0, mag[28:22]} + 9'd40;    // lines 40-167
				crease_lines  <= {1'b0, mag[31:29]} + 4'd4;     // 4-11 lines
				// rng[15:14] sits outside the dice bits, so it is free here
				// (same private word as the dice)
				crease_fields <= {1'b0, rng[15:14], 4'd0} + 7'd48;  // 48-96 fields (~0.8-1.6 s)
			end else if (trig_single) begin
				seg_start <= rnd_start;
				seg_len   <= rnd_len;
				seg_on    <= 1'b1;
			end
		end

		// a scheduled segment converts to a sample countdown at its start,
		// so long events spill across hsync into following lines
		if (seg_on && h_pos == seg_start) begin
			spill_rem <= seg_len;
			seg_on    <= 1'b0;
			tail_len  <= seg_len[11:2] + 10'd16;
			tail_rem  <= 10'd0;
			if (spill_rem == 0) ramp <= 5'd1;   // a fresh event fades in; a running one continues
		end
	end
end

assign body = (spill_rem != 0);
assign act  = body || (tail_rem != 0);
assign mix  = body ? ramp : (tail_rem >= 10'd16) ? 5'd16 : tail_rem[4:0];
assign luma = body ? sparkle_lvl : 8'd0;

endmodule

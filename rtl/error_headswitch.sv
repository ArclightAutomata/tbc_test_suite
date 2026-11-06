// SPDX-License-Identifier: GPL-2.0-or-later
// Head-switch simulation - the helical-scan head handoff.
//
// Every helical tape deck switches video heads a few lines above the
// bottom of the picture. The incoming head arrives with a horizontal
// phase error that the deck's servo then pulls in over tens of lines -
// through vertical blanking and into the TOP of the next field, which
// is why consumer VHS shows "flagging" at the top of the screen. This
// is inherent to ALL helical playback and is the single most
// characteristic stress a line TBC must ride through.
//
// The phase step is applied at SWITCH_LINE and decays exponentially
// (tau ~32 lines) across the field boundary. "Unstable" re-rolls the
// step magnitude and sign every field from the PRNG.
//
// Where to look: the displaced switch lines themselves (233-239) sit in
// the bottom overscan, hidden on consumer CRTs exactly like real VHS.
// The visible signature is the hook at the TOP of the picture - ~40% of
// the step survives the ~29 blanked lines to line 0 and pulls in over
// the next ~50 lines. (An earlier tau of 16 left only 15% by the top,
// which vanished under the top overscan.)

module error_headswitch (
	input         clk,
	input         reset,
	input  [2:0]  mode,       // 0=Off 1=Subtle(0.5us) 2=Typical(1.5us) 3=Severe(4us) 4=Unstable
	input  [8:0]  v_count,
	input         new_line,
	input  [31:0] rng,

	output reg signed [12:0] h_offset
);

localparam [8:0] SWITCH_LINE = 9'd233;   // last visible lines of the field

// Level with 8 fractional bits: a plain 13-bit `level - (level >>> 5)`
// stops decaying below 32 samples (the shift rounds to 0), which left
// Subtle (29) never pulling in at all and every other mode stuck on a
// permanent 31-sample (~0.5 us) offset. With the fraction the decay is
// a true exponential down to zero; the output rounds to samples.
reg signed [20:0] level;

wire signed [12:0] step =
	(mode == 3'd1) ? 13'sd29  :                                   // ~0.5 us
	(mode == 3'd2) ? 13'sd86  :                                   // ~1.5 us
	(mode == 3'd3) ? 13'sd229 :                                   // ~4 us
	(mode == 3'd4) ? (13'sd57 + {{6{rng[30]}}, rng[30:24]}) :     // ~1 us +/- 1.1 us, per field
	                 13'sd0;

always @(posedge clk) begin
	if (reset || mode == 3'd0) begin
		level    <= 21'sd0;
		h_offset <= 13'sd0;
	end else if (new_line) begin
		if (v_count == SWITCH_LINE)
			level <= {step, 8'd0};
		else
			level <= level - (level >>> 5);   // servo pull-in, tau ~32 lines
		h_offset <= 13'((level + 21'sd128) >>> 8);
	end
end

endmodule

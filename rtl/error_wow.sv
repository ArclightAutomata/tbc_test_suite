// SPDX-License-Identifier: GPL-2.0-or-later
// Wow / Flutter Error Generator
//
// Models tape-transport speed error: the timebase itself stretches and
// compresses as a slow function of TIME. Unlike flagwaving (a per-field
// standing wave indexed by line number), free-running phase accumulators
// advance once per line, so the modulation crawls continuously across
// fields exactly like capstan/reel speed error on a real transport.
//
// Wow (0.5-1.5 Hz) and flutter (10-30 Hz, smaller depth) are distinct
// transport mechanisms that coexist on real decks, so they are
// independent controls here; their contributions sum.
//
// Line rate is 15734 Hz, so freq = inc * 15734 / 2^24.
// line_length_mod = 3640 * speed deviation (e.g. +/-15 samples = 0.4%).
// The deviation integrates into a large absolute timebase drift over a
// wow cycle (many microseconds) - that drift is the point: it exercises a
// TBC's correction window and servo tracking, not just its per-line jitter
// tolerance.

module error_wow (
	input        clk,
	input        reset,
	input  [2:0] wow_mode,      // 0=Off 1=Gentle 2=Slow 3=Typical 4=Deep 7=Ramp (sweep)
	input  [1:0] flutter_mode,  // 0=Off 1=Typical (10 Hz) 2=Fast (30 Hz)
	input  [7:0] ramp,          // sweep level for mode 7 (0..255 -> 0..±31 samples at 1.5 Hz)
	input        new_line,      // pulse at start of each line

	output reg signed [12:0] line_length_mod
);

// Phase increments per line
localparam [23:0] INC_WOW_SLOW     = 24'd533;    // 0.5 Hz
localparam [23:0] INC_WOW          = 24'd1599;   // 1.5 Hz
localparam [23:0] INC_FLUTTER      = 24'd10663;  // 10 Hz
localparam [23:0] INC_FLUTTER_FAST = 24'd31989;  // 30 Hz

reg [23:0] phase1, phase2;

wire signed [10:0] wave1, wave2;
sine_lut lut1 (.addr(phase1[23:16]), .data(wave1));
sine_lut lut2 (.addr(phase2[23:16]), .data(wave2));

// Wow rate and depth (sine amplitude is +/-255)
reg [23:0] inc1;
reg  [2:0] shift1;   // depth: >>>3 = +/-32 (0.9%), >>>4 = +/-16 (0.4%), >>>7 = +/-2 (0.05%)
always @(*) begin
	case (wow_mode)
		3'd1:    begin inc1 = INC_WOW;      shift1 = 3'd7; end   // Gentle: a drum servo hunting slightly
		3'd2:    begin inc1 = INC_WOW_SLOW; shift1 = 3'd4; end
		3'd3:    begin inc1 = INC_WOW;      shift1 = 3'd4; end
		3'd4:    begin inc1 = INC_WOW_SLOW; shift1 = 3'd3; end
		3'd7:    begin inc1 = INC_WOW;      shift1 = 3'd4; end   // Ramp (depth from ramp input)
		default: begin inc1 = 24'd0;        shift1 = 3'd4; end
	endcase
end

wire [23:0] inc2 = (flutter_mode == 2'd1) ? INC_FLUTTER :
                   (flutter_mode == 2'd2) ? INC_FLUTTER_FAST : 24'd0;

// Ramp mode: depth scales continuously with the sweep level.
// level 255 -> wave >>> 3 = +/-31 samples (0.9% speed deviation, "Deep")
wire signed [19:0] ramp_prod = wave1 * $signed({1'b0, ramp});
wire signed [12:0] mod_ramp  = ramp_prod >>> 11;

wire wow_on     = (wow_mode != 3'd0);
wire flutter_on = (flutter_mode != 2'd0);

// Round to nearest: a plain >>> floors, so the wave ran -16..+15 and
// every line averaged half a sample short (a constant line-rate offset
// on top of the wow; a third of the Gentle level's own swing)
wire signed [12:0] wave1_r = wave1 + (13'sd1 <<< (shift1 - 3'd1));
wire signed [12:0] mod1 = (wow_mode == 3'd7) ? mod_ramp : (wave1_r >>> shift1);
wire signed [12:0] mod2 = wave2 >>> 3'd6;                // +/-3 samples (0.1%)

always @(posedge clk) begin
	if (reset) begin
		phase1 <= 24'd0;
		phase2 <= 24'd0;
		line_length_mod <= 13'sd0;
	end else if (new_line) begin
		phase1 <= wow_on     ? phase1 + inc1 : 24'd0;
		phase2 <= flutter_on ? phase2 + inc2 : 24'd0;
		line_length_mod <= (wow_on     ? mod1 : 13'sd0) +
		                   (flutter_on ? mod2 : 13'sd0);
	end
end

endmodule

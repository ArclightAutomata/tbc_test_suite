// SPDX-License-Identifier: GPL-2.0-or-later
// Error Injector Coordinator
// Decodes OSD settings and coordinates all error sub-modules
// Sums contributions from multiple error types
//
// Timing errors work by modifying line lengths, line start offsets,
// and the vsync position in ntsc_timing; the custom encoder's burst
// window follows that timing, producing malformed Y/C for TBC testing.

module error_injector (
	input         clk,
	input         reset,
	input         test_active,    // errors only active during test mode
	input         pal,            // roll phase wraps at the field height

	// Timing inputs
	input  [8:0]  v_count,
	input         field,
	input         new_line,
	input         new_field,

	// OSD configuration (from status register)
	input  [2:0]  roll_mode,      // picture roll
	input  [2:0]  tear_mode,      // tearing
	input  [2:0]  flagwave_mode,  // flagwaving
	input  [2:0]  skew_mode,      // skew error
	input  [2:0]  wow_mode,       // wow (slow speed error)
	input  [1:0]  flutter_mode,   // flutter (fast speed error, independent of wow)
	input  [2:0]  dropout_mode,   // dropouts (applied downstream of the encoder)
	input  [2:0]  headsw_mode,    // head-switch phase step
	input  [2:0]  jitter_mode,   // white per-line timebase jitter
	input  [2:0]  sweep_sel,      // severity ramp: 0=Off 1=Wow 2=Tearing 3=Flagwave 4=Jitter
	input  [7:0]  prng_seed,

	// Error injection outputs (to timing generator)
	output signed [12:0] h_offset_out,       // combined horizontal offset
	output signed [12:0] line_length_mod_out, // line length modification
	output [8:0]  roll_shift_out,             // vsync phase rotation (picture roll)
	output [2:0]  dropout_eff,                // dropout mode gated by the run
	output reg [7:0] ramp_level,              // sweep severity 0-255 (for scaling + on-screen gauge)
	output [31:0] rng_out,                    // shared PRNG stream (Tearing only)
	output        reseed_out,                 // restart pulse (dropout + encoder private streams)
	output        err_active                  // errors running (gate the encoding errors with this)
);

// Run start: errors do not start the moment the OSD closes (an
// arbitrary line and field) but at the next frame start - field 0,
// line 0. The PRNGs reload there and every error module comes out of
// its Off state there, so a given seed replays the same errors on the
// same lines whenever the OSD is closed. (At most ~33 ms of delay.)
reg run;
always @(posedge clk) begin
	if (reset || !test_active) run <= 1'b0;
	else if (new_field && !field) run <= 1'b1;
end
assign err_active = run;

// Severity sweep: level 0->255 over ~60 s (one step per 14 fields),
// looping. Restarts when the sweep target changes; freezes with the
// OSD open like everything else.
reg [3:0] ramp_div;
reg [2:0] sweep_prev;
always @(posedge clk) begin
	if (reset) begin
		ramp_level <= 8'd0;
		ramp_div   <= 4'd0;
		sweep_prev <= 3'd0;
	end else begin
		sweep_prev <= sweep_sel;
		if (sweep_sel != sweep_prev) begin
			ramp_level <= 8'd0;
			ramp_div   <= 4'd0;
		end else if (new_field && run && sweep_sel != 3'd0) begin
			if (ramp_div == 4'd13) begin
				ramp_div   <= 4'd0;
				ramp_level <= ramp_level + 8'd1;   // wraps: looping sawtooth
			end else begin
				ramp_div <= ramp_div + 4'd1;
			end
		end
	end
end

// VCR presets are handled at the top level: selecting one WRITES the
// curated values into the individual OSD rows via status_in/status_set,
// so the rows always show (and the user can tweak) exactly what runs.
// This module only sees the manual modes.

assign dropout_eff = run ? dropout_mode : 3'd0;

// Sweep override: the ramped error runs in mode 7 with sweep-scaled
// severity; other errors keep their configured behavior.
wire [2:0] wow_run  = (sweep_sel == 3'd1) ? 3'd7 : wow_mode;
wire [2:0] tear_run = (sweep_sel == 3'd2) ? 3'd7 : tear_mode;
wire [2:0] flag_run = (sweep_sel == 3'd3) ? 3'd7 : flagwave_mode;
wire [2:0] jit_run  = (sweep_sel == 3'd4) ? 3'd7 : jitter_mode;

// PRNG. Reseeds when the OSD seed changes and at every run start, so
// each run replays the same error timeline from the same starting point.
reg [7:0] seed_prev;
reg       run_prev;
always @(posedge clk) begin
	seed_prev <= prng_seed;
	run_prev  <= run;
end
wire reseed = (prng_seed != seed_prev) || (run && !run_prev);
assign reseed_out = reseed;

wire [31:0] rng_value;
prng prng_inst (
	.clk(clk),
	.reset(reset),
	.seed(prng_seed),
	.reload(reseed),
	.advance(new_line & run),
	.rng_value(rng_value)
);

// Individual error outputs
wire [8:0]         roll_phase;
wire signed [12:0] tear_h_offset;
wire signed [12:0] flagwave_line_mod;
wire signed [12:0] skew_h_offset;
wire signed [12:0] wow_line_mod;

// Error sub-modules
error_roll roll_inst (
	.clk(clk), .reset(reset),
	.mode(run ? roll_mode : 3'd0),
	.pal(pal),
	.new_field(new_field),
	.roll_shift(roll_phase)
);

error_tear tear_inst (
	.clk(clk), .reset(reset),
	.mode(run ? tear_run : 3'd0),
	.ramp(ramp_level),
	.new_line(new_line),
	.rng_value(rng_value),
	.h_offset(tear_h_offset)
);

error_flagwave flagwave_inst (
	.clk(clk), .reset(reset),
	.mode(run ? flag_run : 3'd0),
	.ramp(ramp_level),
	.v_count(v_count),
	.new_line(new_line),
	.new_field(new_field),
	.line_length_mod(flagwave_line_mod)
);

error_skew skew_inst (
	.clk(clk), .reset(reset),
	.mode(run ? skew_mode : 3'd0),
	.v_count(v_count),
	.new_line(new_line),
	.h_offset(skew_h_offset)
);

error_wow wow_inst (
	.clk(clk), .reset(reset),
	.wow_mode(run ? wow_run : 3'd0),
	.flutter_mode(run ? flutter_mode : 2'd0),
	.ramp(ramp_level),
	.new_line(new_line),
	.line_length_mod(wow_line_mod)
);

// Private streams for Jitter and Head Switch (same seed XOR a constant,
// same reload/advance as the shared one). On the shared word their bits
// overlapped each other's, Tearing's and the dropout trigger's: every
// dropout line forced Jitter's sign, and the head-switch step equaled
// bits of that line's jitter (caught by sim/err_rng). Tearing keeps the
// shared stream to itself.
wire [31:0] jit_rng, hs_rng;
prng jit_prng (
	.clk(clk), .reset(reset), .seed(prng_seed ^ 8'h5C), .reload(reseed),
	.advance(new_line & run), .rng_value(jit_rng)
);
prng hs_prng (
	.clk(clk), .reset(reset), .seed(prng_seed ^ 8'h3A), .reload(reseed),
	.advance(new_line & run), .rng_value(hs_rng)
);

wire signed [12:0] headsw_h_offset;
error_headswitch headsw_inst (
	.clk(clk), .reset(reset),
	.mode(run ? headsw_mode : 3'd0),
	.v_count(v_count),
	.new_line(new_line),
	.rng(hs_rng),
	.h_offset(headsw_h_offset)
);

wire signed [12:0] jitter_h_offset;
error_jitter jitter_inst (
	.clk(clk), .reset(reset),
	.mode(run ? jit_run : 3'd0),
	.ramp(ramp_level),
	.new_line(new_line),
	.rng(jit_rng),
	.h_offset(jitter_h_offset)
);

// Combine horizontal offsets (tearing + skew + head switch + jitter
// are additive; worst case sum stays far inside 13-bit signed)
assign h_offset_out = run ? (tear_h_offset + skew_h_offset + headsw_h_offset + jitter_h_offset) : 13'sd0;

// Line length modification (flagwaving + wow/flutter are additive;
// worst case |63| + |34| fits comfortably in 13-bit signed)
assign line_length_mod_out = run ? (flagwave_line_mod + wow_line_mod) : 13'sd0;

// Vsync phase rotation (from picture roll; the module holds phase 0
// while its mode input is gated to Off)
assign roll_shift_out = roll_phase;

assign rng_out = rng_value;

endmodule

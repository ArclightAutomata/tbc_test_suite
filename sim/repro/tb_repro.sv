// SPDX-License-Identifier: GPL-2.0-or-later
// Same-seed reproducibility testbench: a mini top level wiring the real
// ntsc_timing, error_injector, error_dropout and yc_encoder the way
// TBC_Test_Suite.sv does (keep the two in step). The C++ driver
// (main.cpp) opens/closes the "OSD" via test_active and compares the
// per-line error outputs of two runs.

module tb_repro (
	input             clk,
	input             reset,
	input             test_active,
	input       [7:0] seed,
	input             interlace,    // OSD Interlace (On/Off)

	output            new_line,
	output            new_field,
	output            field,
	output      [8:0] v_count,
	output signed [12:0] h_off,
	output signed [12:0] llm,
	output      [8:0] roll,
	output signed [7:0] noise,
	output      [1:0] flick,
	output      [7:0] hue,
	output     [23:0] sc_drift,
	output      [7:0] sc_phase,     // subcarrier phase (encoder DDS top bits)
	output            pal_flip,
	output            drop_act,
	output      [7:0] drop_luma,
	output            err_on        // errors running (for the driver's alignment)
);

// errors on, roughly a "Damaged tape" mix plus every encoding error
localparam [2:0] ROLL = 3'd5, TEAR = 3'd3, FLAG = 3'd2, SKEW = 3'd3, WOW = 3'd3,
                 DROP = 3'd3, HSW = 3'd4, JIT = 3'd3;
localparam [1:0] FLUT = 2'd1;

wire [11:0] h_count;
wire signed [12:0] err_h_offset, err_line_length_mod;
wire [8:0]  err_roll_shift;
wire [2:0]  dropout_eff;
wire [7:0]  ramp_level;
wire [31:0] rng_value;
wire        prng_reseed;
wire        burst_window;

wire interlace_eff = test_active & interlace;   // forced progressive with the OSD open

ntsc_timing timing (
	.clk(clk), .reset(reset), .pal(1'b0), .interlace_en(interlace_eff),
	.v_shift(2'd0), .pulse_cross(1'b0), .pc_enhanced(1'b0),
	.line_length_mod(err_line_length_mod), .h_offset(err_h_offset), .roll_shift(err_roll_shift),
	.h_count(h_count), .v_count(v_count), .field(field),
	.hsync(), .vsync(), .hblank(), .vblank(), .burst_window(burst_window), .active_video(),
	.new_line(new_line), .new_field(new_field), .pc_blank(), .disp_sync()
);

error_injector error_inj (
	.clk(clk), .reset(reset), .test_active(test_active), .pal(1'b0),
	.v_count(v_count), .field(field), .new_line(new_line), .new_field(new_field),
	.roll_mode(ROLL), .tear_mode(TEAR), .flagwave_mode(FLAG), .skew_mode(SKEW),
	.wow_mode(WOW), .flutter_mode(FLUT), .dropout_mode(DROP), .headsw_mode(HSW),
	.jitter_mode(JIT), .sweep_sel(3'd0), .prng_seed(seed),
	.h_offset_out(err_h_offset), .line_length_mod_out(err_line_length_mod),
	.roll_shift_out(err_roll_shift), .dropout_eff(dropout_eff), .ramp_level(ramp_level),
	.rng_out(rng_value), .reseed_out(prng_reseed), .err_active(err_on)
);

wire [11:0] h_pos = (h_count >= 12'd668) ? (h_count - 12'd668) : 12'd0;
error_dropout dropout (
	.clk(clk), .reset(reset), .mode(dropout_eff), .h_pos(h_pos), .v_count(v_count),
	.new_line(new_line), .new_field(new_field),
	.seed(seed), .reload(prng_reseed), .act(drop_act), .luma(drop_luma)
);

// encoding errors gated like TBC_Test_Suite.sv (by the injector's run)
wire       hdrift_eff = err_on;                        // Hue Shift = Drift
wire [2:0] blevel_eff = err_on ? 3'd4 : 3'd0;          // Burst = Flicker
wire [2:0] sc_eff     = err_on ? 3'd6 : 3'd0;          // Subcarrier = Drift
wire [1:0] cnoise_eff = err_on ? 2'd3 : 2'd0;          // Chroma Noise = Severe

wire [7:0] enc_y, enc_c;
yc_encoder yc_enc (
	.clk(clk), .reset(reset), .pal(1'b0), .cvbs(1'b0),
	.r(8'd128), .g(8'd64), .b(8'd192), .burst_window(burst_window),
	.new_line(new_line), .seed(seed), .reload(prng_reseed),
	.new_field(new_field), .hue_offset(8'd0), .hue_drift(hdrift_eff),
	.burst_level(blevel_eff), .sc_mode(sc_eff),
	.chroma_delay(8'd0), .noise_mode(cnoise_eff), .chroma_bw(1'b0),
	.chroma_force(1'b0), .chroma_u(10'sd0), .y_out(enc_y), .c_out(enc_c)
);

assign h_off    = err_h_offset;
assign llm      = err_line_length_mod;
assign roll     = err_roll_shift;
assign noise    = yc_enc.noise_step;
assign flick    = yc_enc.flick;
assign hue      = yc_enc.hue_eff;
assign sc_drift = yc_enc.sc_drift_acc;
assign sc_phase = yc_enc.phase_accum[39:32];
assign pal_flip = yc_enc.pal_flip;

endmodule

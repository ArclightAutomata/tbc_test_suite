// SPDX-License-Identifier: GPL-2.0-or-later
// Custom NTSC/PAL Y/C encoder with encoding-level error injection.
//
// Datapath cloned from the framework's yc_out.sv (Mike Simone) so that
// luma/chroma levels and burst amplitude match what the MikeS11 adapter
// already expects, with these differences:
//   - PHASE_INC hardcoded for our 57.272727 MHz clock (NTSC 16 clk/cycle
//     = 2^36; PAL via DDS), so the core does not depend on yc.txt / ARM
//     detection.
//   - Burst gated by ntsc_timing's burst_window, so the burst tracks
//     injected timing errors instead of an ARM-supplied fixed window.
//   - Error hooks the framework encoder can never provide:
//       hue_offset:   burst phase offset, 1 LUT step = 1.40625 degrees.
//                     Receivers lock hue to burst, so shifting only the
//                     burst rotates decoded hue by -offset.
//       burst_level:  burst amplitude 100/50/25/0% or per-line flicker
//       sc_mode:      subcarrier frequency offset / drift
//       chroma_delay: delays C relative to Y (Y/C misalignment smear)
//       noise_step:   per-line random burst phase jitter (hue flicker)
//       chroma_bw:    optional broadcast-style U/V low-pass
//   - Optional composite (cvbs) output and a forced-chroma input for
//     the waveform-monitor patterns.
//
// Y = luma only, 0-255, no sync/setup: composite sync is summed into the
// green channel by the IO board's sync-on-green hardware (vga_sog=1),
// identical to how the framework yc_out output is wired.
//
// Output mapping (mister.ini [TBC_TEST_SUITE] vga_mode=rgb):
//   VGA_G = y_out -> MikeS11 Y,  VGA_R = c_out -> MikeS11 C

module yc_encoder (
	input        clk,           // 57.272727 MHz
	input        reset,

	input  [7:0] r,
	input  [7:0] g,
	input  [7:0] b,
	input        burst_window,  // from ntsc_timing
	input        new_line,      // for per-line noise sampling
	input  [7:0] seed,          // OSD seed (private random stream, see enc_rng)
	input        reload,        // restart the stream (seed change / OSD close)

	// Encoding error controls
	input        pal,           // 0=NTSC (3.579545 MHz), 1=PAL (4.43361875 MHz, V-switch, swinging burst)
	input        cvbs,          // 0=S-Video (Y and C separate), 1=composite (Y+C summed on Y, half scale)
	input        new_field,     // for the drift generators
	input  [7:0] hue_offset,    // 0-255 = 0-360 degrees burst phase shift
	input        hue_drift,     // Hue Shift = Drift: hue_offset ignored, rotates 1 step/field
	input  [2:0] burst_level,   // 0=100% 1=50% 2=25% 3=off 4=flicker (per-line random)
	input  [2:0] sc_mode,       // subcarrier freq error: 0=off 1..5=+/-250Hz/+/-1kHz/+5kHz 6=drift
	input  [7:0] chroma_delay,  // C delay in clk samples (17.5 ns each, up to 4.5 us)
	input  [1:0] noise_mode,    // 0=off 1=+/-6deg 2=+/-11deg 3=+/-45deg
	input        chroma_bw,     // 0=sharp (unfiltered UV), 1=broadcast low-pass

	// Test-signal hook: bypass the RGB->UV math and modulate a forced U
	// amplitude (V=0). Textbook WFM signals (modulated staircase/ramp,
	// the 12.5T pulse) need constant/enveloped chroma on arbitrary luma,
	// which RGB cannot express without gamut clipping.
	input        chroma_force,
	input signed [9:0] chroma_u,

	output reg [7:0] y_out,
	output reg [7:0] c_out,
	output reg [7:0] y_lum      // luma alone, aligned with y_out (= y_out in S-Video)
);

// Subcarrier DDS. NTSC: 2^36 = exactly 16 clk/cycle. PAL: 4.43361875 MHz
// from the same 57.272727 MHz clock (12.918 clk/cycle - the accumulator
// synthesizes any ratio, exactly like the framework yc_out with an
// arbitrary yc.txt PHASE_INC).
//
// Subcarrier frequency error: the increment gets a signed offset
// (~19198 counts/Hz = 2^40 / 57272727). Burst and picture chroma share
// the accumulator, so both shift together - correct physics for an
// off-frequency oscillator. A decoder that samples its reference from
// each line's burst accumulates phase error across the line: a
// left-to-right HUE GRADIENT (~23 deg/kHz across the active line);
// beyond the decoder's PLL pull-in range the color rolls (rainbow).
// Drift wanders +/-1 kHz sinusoidally over ~5 s (aging crystal /
// heterodyne color-under error).
wire [39:0] phase_inc_base = pal ? 40'd85115823899 : 40'h10_0000_0000;

// (Both drift generators restart whenever their mode is off - including
// while the OSD is open, where the top level gates the modes - so a run
// always starts the drift from the same point.)
reg [23:0] sc_drift_acc;
always @(posedge clk) begin
	if (reset || sc_mode != 3'd6) sc_drift_acc <= 24'd0;
	else if (new_line)            sc_drift_acc <= sc_drift_acc + 24'd213;  // ~5 s/cycle
end

// Hue Shift = Drift: 1 LUT step per field, a full rotation every ~4.3 s
reg [7:0] hue_drift_acc;
always @(posedge clk) begin
	if (reset || !hue_drift) hue_drift_acc <= 8'd0;
	else if (new_field)      hue_drift_acc <= hue_drift_acc + 8'd1;
end
wire [7:0] hue_eff = hue_drift ? hue_drift_acc : hue_offset;
wire signed [10:0] sc_sin;
sine_lut sc_lut (.addr(sc_drift_acc[23:16]), .data(sc_sin));
wire signed [27:0] sc_drift_off = sc_sin * $signed(17'd75286);  // +/-255 -> +/-1 kHz

reg signed [27:0] sc_off;
always @(*) begin
	case (sc_mode)
		3'd1:    sc_off =  28'sd4799479;   // +250 Hz
		3'd2:    sc_off = -28'sd4799479;   // -250 Hz
		3'd3:    sc_off =  28'sd19197916;  // +1 kHz
		3'd4:    sc_off = -28'sd19197916;  // -1 kHz
		3'd5:    sc_off =  28'sd95989581;  // +5 kHz
		3'd6:    sc_off = sc_drift_off;    // Drift
		default: sc_off = 28'sd0;
	endcase
end
wire [39:0] phase_inc = phase_inc_base + {{12{sc_off[27]}}, sc_off};

reg  [39:0] phase_accum;
// Subcarrier phase loaded at the run start (see pal_flip below). This
// makes SC-H constant run to run; its absolute value is not yet
// calibrated to the standard's 0 deg (needs the encoder vs csync
// pipeline offset measured - ROADMAP.md).
localparam [39:0] SCH_INIT = 40'd0;
wire [7:0]  chroma_LUT = phase_accum[39:32];

// PAL V-switch: the V component and burst phase alternate every line.
// Both it and the subcarrier phase restart at the run start (`reload`,
// a fixed point of the first frame): timing errors change the clock
// count per field, so a free-running subcarrier entered each run at a
// history-dependent SC-H phase and a seed did not replay bit-exactly.
reg pal_flip;
always @(posedge clk) begin
	if (reset || reload) pal_flip <= 1'b0;
	else if (new_line)   pal_flip <= ~pal_flip;
end

// Private random stream for the encoder's per-line draws (Burst Flicker,
// Chroma Noise). The shared error_injector stream already feeds the
// timing errors, whose bits overlap these: on a shared word the Tearing
// trigger (rng[7:0] < threshold) pinned every torn line's hue noise to
// a small positive value, and the tear offset's low bits fixed the
// flicker level. Same seed (XOR a constant) and same reload points as
// the shared stream, so a given OSD seed still reproduces exactly.
wire [31:0] rng;
prng enc_rng (
	.clk(clk), .reset(reset), .seed(seed ^ 8'h96), .reload(reload),
	.advance(new_line), .rng_value(rng)
);

// Burst Flicker: per-line random burst amplitude (100/100/50/25% with
// p = 1/2, 1/4, 1/4) - exercises the decoder's chroma AGC *dynamics*
// rather than its static operating point
reg [1:0] flick;
always @(posedge clk) begin
	if (reset)         flick <= 2'd0;
	else if (new_line) flick <= (rng[12:11] == 2'd3) ? 2'd0 : rng[12:11];
end
wire [1:0] eff_blevel = (burst_level == 3'd4) ? flick : burst_level[1:0];

// Per-line burst phase noise, sampled from the PRNG at line start
reg signed [7:0] noise_step;
always @(posedge clk) begin
	if (reset || noise_mode == 2'd0)
		noise_step <= 8'sd0;
	else if (new_line) begin
		case (noise_mode)
			2'd1:    noise_step <= $signed(rng[7:0]) >>> 5; // +/-4  steps (~6 deg)
			2'd2:    noise_step <= $signed(rng[7:0]) >>> 4; // +/-8  steps (~11 deg)
			default: noise_step <= $signed(rng[7:0]) >>> 2; // +/-32 steps (~45 deg)
		endcase
	end
end

// Sine LUTs (table identical to yc_out's)
// NTSC burst = subcarrier + 180 degrees; PAL swings +/-135 (LUT +96/+160)
wire [7:0] burst_base     = pal ? (pal_flip ? 8'd160 : 8'd96) : 8'd128;
wire [7:0] lut_sin_addr   = chroma_LUT;
wire [7:0] lut_cos_addr   = chroma_LUT + 8'd64;
wire [7:0] lut_burst_addr = chroma_LUT + burst_base + hue_eff + {noise_step[7], noise_step[6:0]};
wire signed [10:0] sin_val, cos_val, burst_val;
sine_lut lut_sin_i   (.addr(lut_sin_addr),   .data(sin_val));
sine_lut lut_cos_i   (.addr(lut_cos_addr),   .data(cos_val));
sine_lut lut_burst_i (.addr(lut_burst_addr), .data(burst_val));

// ---- Pipeline (mirrors yc_out stage structure) ----
// Stage 0: luma products; delay r/b to align with computed Y
reg [17:0] y_prod;
reg [7:0]  r_1, b_1, r_2, b_2;
reg        bw_0, bw_1, bw_2, bw_3;

// Stage 1: color difference, scaled U=504x, V=898x
reg signed [9:0]  u_diff, v_diff;
reg signed [20:0] u_scaled, v_scaled;

// Broadcast chroma bandwidth: 16-tap boxcar on U/V before modulation.
// At 57.27 MHz that is -3 dB around 1.6 MHz with the first null exactly
// on the 3.58 MHz subcarrier, so color transitions spread over ~0.3 us
// like a real broadcast encoder instead of stepping instantaneously
// (and the edge energy that causes cross-color tinting is notched out).
reg signed [9:0]  u_sr [0:15];
reg signed [9:0]  v_sr [0:15];
reg signed [13:0] u_acc, v_acc;
integer k;
always @(posedge clk) begin
	if (reset) begin
		u_acc <= 14'sd0;
		v_acc <= 14'sd0;
		for (k = 0; k <= 15; k = k + 1) begin
			u_sr[k] <= 10'sd0;
			v_sr[k] <= 10'sd0;
		end
	end else begin
		u_acc <= u_acc + u_diff - u_sr[15];
		v_acc <= v_acc + v_diff - v_sr[15];
		u_sr[0] <= u_diff;
		v_sr[0] <= v_diff;
		for (k = 1; k <= 15; k = k + 1) begin
			u_sr[k] <= u_sr[k-1];
			v_sr[k] <= v_sr[k-1];
		end
	end
end

// Forced-chroma pipeline alignment (pattern output -> u_diff stage)
reg        cf_1, cf_2, cf_3;
reg signed [9:0] cu_1, cu_2, cu_3;

wire signed [9:0] u_sel = cf_3 ? cu_3   : (chroma_bw ? u_acc[13:4] : u_diff);
wire signed [9:0] v_sel = cf_3 ? 10'sd0 : (chroma_bw ? v_acc[13:4] : v_diff);

// Y/C misalignment: delay the color-difference signals BEFORE the
// modulator. The delayed U/V are then modulated by the current
// subcarrier, so a flat field keeps its hue - only the color content
// moves right of its luma, as with a real Y/C delay. (Delaying the
// already-modulated C instead rotates hue by 22.5 deg per sample
// against the undelayed burst.) The burst is generated downstream from
// the burst window and is never delayed, so it stays inside the
// decoder's burst gate.
//
// BRAM, up to 255 clk = 4.5 us. The registered read taps
// (wr - delay + 1), which lands exactly `chroma_delay` samples behind
// the undelayed path; delay 1 uses a plain register because that tap
// would collide with the write address.
reg [19:0] uv_dly [0:255];
reg  [7:0] uv_wr;
reg [19:0] uv_q, uv_1;
always @(posedge clk) begin
	uv_dly[uv_wr] <= {u_sel, v_sel};
	uv_wr <= uv_wr + 8'd1;
	uv_q  <= uv_dly[uv_wr - chroma_delay + 8'd1];
	uv_1  <= {u_sel, v_sel};
end
wire [19:0] uv_d = (chroma_delay == 8'd0) ? {u_sel, v_sel} :
                   (chroma_delay == 8'd1) ? uv_1 : uv_q;
wire signed [9:0] u_mod = uv_d[19:10];
wire signed [9:0] v_mod = uv_d[9:0];

// Stage 2: modulated products
reg signed [20:0] p2_u, p2_v;

// Stage 3: scaled to 8-bit range
reg signed [12:0] p3_u, p3_v;

// Y delay line to match chroma latency (the boxcar adds ~8 clk of group
// delay in broadcast mode, so Y takes a correspondingly longer tap)
reg [7:0] y_1, y_2, y_3, y_4, y_5, y_6, y_7, y_8, y_9, y_10, y_11, y_12;

reg [7:0] c_raw;
reg [7:0] c_pre;

wire [7:0] y_now = y_prod[17:10];

always @(posedge clk) begin
	if (reset) begin
		phase_accum <= 40'd0;
		y_out <= 8'd0;
		y_lum <= 8'd0;
		c_out <= 8'd128;
		c_raw <= 8'd128;
	end else begin
		phase_accum <= reload ? SCH_INIT : phase_accum + phase_inc;

		// Stage 0
		y_prod <= r * 9'd306 + g * 10'd601 + b * 7'd117;
		r_1 <= r;   b_1 <= b;
		r_2 <= r_1; b_2 <= b_1;
		bw_0 <= burst_window;
		bw_1 <= bw_0; bw_2 <= bw_1; bw_3 <= bw_2;
		cf_1 <= chroma_force; cf_2 <= cf_1; cf_3 <= cf_2;
		cu_1 <= chroma_u;     cu_2 <= cu_1; cu_3 <= cu_2;

		// Stage 1: U/V color difference against aligned Y. b_2/r_2 are
		// two registers deep, so the matching luma tap is y_1 (also two
		// deep via y_prod) - subtracting y_now here pairs B(t) with
		// Y(t+1), which is zero on flat color but a full-amplitude
		// chroma impulse at every luma EDGE: grayscale detail leaked
		// into chroma (seen as a green wash on the finest multiburst
		// packet until this was fixed).
		u_diff <= $signed({2'b0, b_2}) - $signed({2'b0, y_1});
		v_diff <= $signed({2'b0, r_2}) - $signed({2'b0, y_1});
		u_scaled <= 21'($signed({u_mod, 8'd0}) + $signed({u_mod, 7'd0}) + $signed({u_mod, 6'd0})
		          + $signed({u_mod, 5'd0}) + $signed({u_mod, 4'd0}) + $signed({u_mod, 3'd0}));   // x504
		v_scaled <= 21'($signed({v_mod, 9'd0}) + $signed({v_mod, 8'd0}) + $signed({v_mod, 7'd0})
		          + $signed({v_mod, 1'd0}));                                                      // x898

		// Stage 2: modulate (or burst)
		if (bw_1) begin
			p2_u <= $signed({burst_val, 5'd0});
			p2_v <= 21'sd0;
		end else begin
			p2_u <= $signed(u_scaled >>> 10) * sin_val;
			p2_v <= $signed(v_scaled >>> 10) * cos_val;
		end

		// Stage 3: shift-add scaling (same constants as yc_out)
		if (bw_2) begin
			// burst amplitude, scaled by burst_level (or the flicker)
			case (eff_blevel)
				2'd0: p3_u <= $signed(p2_u[20:8]) + $signed(p2_u[20:11]) + $signed(p2_u[20:12]) + $signed(p2_u[20:13]);
				2'd1: p3_u <= ($signed(p2_u[20:8]) + $signed(p2_u[20:11]) + $signed(p2_u[20:12]) + $signed(p2_u[20:13])) >>> 1;
				2'd2: p3_u <= ($signed(p2_u[20:8]) + $signed(p2_u[20:11]) + $signed(p2_u[20:12]) + $signed(p2_u[20:13])) >>> 2;
				default: p3_u <= 13'sd0;
			endcase
			p3_v <= 13'sd0;
		end else begin
			p3_u <= $signed(p2_u[20:9]) + $signed(p2_u[20:10]) + $signed(p2_u[20:14]);
			p3_v <= $signed(p2_v[20:9]) + $signed(p2_v[20:10]) + $signed(p2_v[20:14]);
		end

		// Stage 4: compose chroma around the 128 reference
		// (PAL V-switch subtracts V on alternate lines)
		c_raw <= (pal && pal_flip) ? (8'd128 + p3_u[7:0] - p3_v[7:0])
		                           : (8'd128 + p3_u[7:0] + p3_v[7:0]);

		// Luma alignment (Y has 4 fewer pipeline stages than C)
		y_1 <= y_now; y_2 <= y_1; y_3 <= y_2; y_4 <= y_3;
		y_5 <= y_4; y_6 <= y_5; y_7 <= y_6; y_8 <= y_7;
		y_9 <= y_8; y_10 <= y_9; y_11 <= y_10; y_12 <= y_11;
		// Composite: sum luma and chroma at half scale onto the Y channel
		// (same convention as the framework yc_out CVBS mode); the C
		// output idles at its reference level.
		if (cvbs)
			y_out <= ((chroma_bw ? y_12 : y_4) >> 1) + c_pre[7:1];
		else
			y_out <= chroma_bw ? y_12 : y_4;
		// the out stage splits Composite back into luma + chroma with it
		y_lum <= chroma_bw ? y_12 : y_4;

		// (Y/C misalignment is applied to U/V ahead of the modulator -
		// see uv_dly above.)
		c_pre <= c_raw;
		c_out <= cvbs ? 8'd128 : c_pre;
	end
end

endmodule

// SPDX-License-Identifier: GPL-2.0-or-later
//============================================================================
//
//  TBC Test Suite - MiSTer FPGA Core
//  Generates NTSC/PAL video with intentional timing and encoding errors
//  for testing analog time base correctors and frame synchronizers.
//
//  Output: S-Video/Composite via the MikeS11 adapter. The core encodes
//  Y/C itself (rtl/yc_encoder.sv): Y on VGA_G, C on VGA_R, with sync
//  added by the IO board (composite_sync=1, vga_sog=1, per-core
//  vga_mode=rgb). HDMI shows a clean framebuffer copy of the pattern.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign DDRAM_CLK = clk_sys;

assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 0;
assign AUDIO_L   = 0;
assign AUDIO_R   = 0;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;

assign VIDEO_ARX = 12'd4;
assign VIDEO_ARY = 12'd3;

//////////////////////////////////////////////////////////////////
// OSD Configuration
//////////////////////////////////////////////////////////////////

// Status-bit map (128-bit OSD status word), grouped by menu page. Each
// field keeps headroom bits directly above it so it can grow later by
// widening its range in place - no field ever has to move. sim/status_map
// checks this table against CONF_STR and every status[] slice below.
//
//   0 Reset (T/R)          1 Factory Defaults (T)   2 Channel Banner
//   Test Pattern:  3-7 Pattern (32 values)   8 Level   9-11 Solid Color [12]
//                  13 Window [14]   [15-16] CIRC overlay (planned)
//   Timing Errors: 17-19 VCR Preset [20]   21-23 Picture Roll [24]
//                  25-27 Tearing   28-30 Jitter   31-33 Flagwaving   34-36 Skew
//                  37-39 Wow   40-41 Flutter [42]   43-45 Dropouts
//                  46-48 Head Switch   49-51 Sweep [52]
//                  98-100 Video Heads [101]   102 Dropout Comp [103]
//   Encoding:      53 Encoder   54-56 Hue Shift [57]   58-60 Burst Level
//                  61-62 Chroma Noise [63]   64-66 Subcarrier [67]
//                  68-70 Chroma Delay [71]   72 Chroma BW [73]
//                  [74-76] SC-H Error (planned)
//   Advanced:      77-80 Seed Hi   81-84 Seed Lo   85 Standard [86]   87 Output
//                  88 VBI Captions [89]   90-91 Pulse Cross   92 Interlace
//                  93-94 Video Level   95 HDMI View   96-97 V Position
//   104-127 free.   [n] = reserved headroom, listed for the checker:
// STATUS-RESERVED: 12 14 15 16 20 24 42 52 57 63 67 71 73 74 75 76 86 89 101 103
// (No field may cross the 63/64 word boundary.)

`include "build_id.v"
`include "build_id.v"
localparam CONF_STR = {
	"TBC_TEST_SUITE;;",
	"-;",
	"P1,Test Pattern;",
	"P1-;",
	"P1O[7:3],Pattern,Logo,Color Bars,Crosshatch,Grayscale,Multiburst,Solid Color,Checker,PLUGE,Convergence,Motion,Custom Video,Analysis,Mod Staircase,Mod Ramp,Pulse & Bar,Window,Mandelbrot;",
	"H3P1O[13],Window,Static,Bounce;",
	"H2P1O[11:9],Color,White,Yellow,Cyan,Green,Magenta,Red,Blue,Black;",
	"H0P1O[8],Level,75%,100%;",
	"H1P1F1,BIN,Load Video;",
	"-;",
	"P2,Timing Errors;",
	"P2-;",
	"P2O[19:17],VCR Preset,Off (Manual),Good VHS,Worn VHS,EP Rental,Failing Deck,Damaged;",
	"P2-;",
	"P2O[23:21],Picture Roll,Off,Slow Up,Slow Down,Fast Up,Fast Down,Drift;",
	"P2O[27:25],Tearing,Off,Mild,Moderate,Severe,Burst;",
	"P2O[30:28],Jitter,Off,Faint,Light,Typical,Heavy;",
	"P2O[33:31],Flagwaving,Off,Subtle,Moderate,Severe,Fast,Slow;",
	"P2O[36:34],Skew Error,Off,Top Heavy,Bot Heavy,Moderate,Severe;",
	"P2O[39:37],Wow,Off,Gentle,Slow,Typical,Deep;",
	"P2O[41:40],Flutter,Off,Typical,Fast;",
	"P2O[45:43],Dropouts,Off,Light,Moderate,Heavy,Stress,Crease;",
	"P2O[102],Dropout Comp,Off,On;",
	"P2O[48:46],Head Switch,Off,Subtle,Typical,Severe,Unstable;",
	"P2O[100:98],Video Heads,Clean,Dirty,Very Dirty,One Clogged,Both Clogged;",
	"P2O[51:49],Sweep,Off,Wow Depth,Tear Amp,Flagwave Amp,Jitter RMS;",
	"-;",
	"P3,Encoding Errors;",
	"P3-;",
	"P3O[53],Encoder,Custom,Framework Clone;",
	"P3O[56:54],Hue Shift,Off,+11deg,+45deg,+90deg,180deg,-45deg,Drift;",
	"P3O[60:58],Burst Level,100%,50%,25%,Off,Flicker;",
	"P3O[66:64],Subcarrier,Off,+250 Hz,-250 Hz,+1 kHz,-1 kHz,+5 kHz,Drift;",
	"P3O[70:68],Chroma Delay,Off,100ns,250ns,500ns,1us,2us,4.5us;",
	"P3O[62:61],Chroma Noise,Off,Mild,Moderate,Severe;",
	"P3O[72],Chroma BW,Sharp,Broadcast;",
	"-;",
	"P4,Advanced;",
	"P4-;",
	"P4O[80:77],Seed Hi,0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F;",
	"P4O[84:81],Seed Lo,0,1,2,3,4,5,6,7,8,9,A,B,C,D,E,F;",
	"P4O[85],Standard,NTSC,PAL;",
	"P4O[87],Output,S-Video,Composite;",
	"P4O[88],VBI Captions,Off,On;",
	"P4O[91:90],Pulse Cross,Off,Enhanced,Raw;",
	"P4O[92],Interlace,On,Off;",
	"P4O[94:93],Video Level,Full (255),Limited (235),Medium (192),Low (128);",
	"P4O[95],HDMI View,Clean,Encoded Raw;",
	"P4O[97:96],V Position,Default,Down 2,Down 4;",
	"-;",
	"O[2],Channel Banner,Off,On;",
	"-;",
	"T[1],Factory Defaults;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"J1,A,B,Start;",
	"jn,A,B,Start;",
	"V,v",`BUILD_DATE
};

//////////////////////////////////////////////////////////////////
// HPS IO
//////////////////////////////////////////////////////////////////

wire forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0;

wire        ioctl_download;
wire        ioctl_wr;
wire [15:0] ioctl_dout;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_in(status_in_r),
	.status_set(status_set_r),
	// Dynamic row visibility (H#-prefixed CONF_STR rows hide while the
	// bit is set): [0] Level for Color Bars/Motion/Solid Color,
	// [1] Load Video only for Custom Video, [2] Color only for Solid
	// Color, [3] Window mode only for Window.
	.status_menumask({12'd0,
		(pattern_sel != 5'd15),
		(pattern_sel != 5'd5),
		(pattern_sel != 5'd10),
		(pattern_sel != 5'd1) && (pattern_sel != 5'd9) && (pattern_sel != 5'd5)}),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_dout(ioctl_dout),

	.ps2_key(ps2_key),
	.joystick_0(joystick_0)
);

//////////////////////////////////////////////////////////////////
// Clock Generation
//////////////////////////////////////////////////////////////////

wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

//////////////////////////////////////////////////////////////////
// Status Register Decoding
//////////////////////////////////////////////////////////////////

wire [4:0] pattern_sel   = status[7:3];
wire       smpte_100     = status[8];
wire [2:0] roll_mode     = status[23:21];
wire [2:0] tear_mode     = status[27:25];
wire [2:0] flagwave_mode = status[33:31];
wire [2:0] skew_mode     = status[36:34];
wire [7:0] prng_seed     = {status[80:77], status[84:81]}; // Hi nibble, Lo nibble
wire       interlace_en  = ~status[92]; // default (0) = On = interlaced
wire [1:0] video_level   = status[94:93];
wire [2:0] wow_mode      = status[39:37];
wire [1:0] flutter_mode  = status[41:40];
wire [2:0] vcr_preset    = status[19:17];
wire [2:0] hue_mode      = status[56:54];
wire [2:0] burst_level   = status[60:58];
wire [2:0] sc_mode       = status[66:64];
wire [2:0] cdelay_mode   = status[70:68];
wire [1:0] cnoise_mode   = status[62:61];
wire       pal_mode      = status[85];

//////////////////////////////////////////////////////////////////
// Status write-back: Factory Defaults + VCR preset write-through
//
// The core can push a whole new status word to the ARM (edge-triggered
// status_in/status_set), which updates the OSD rows. Two users:
//   - "Factory Defaults" (T[1]): every option's default is value 0, so
//     pushing all-zeros restores the entire menu.
//   - VCR presets: selecting one stamps its curated values into the
//     individual error rows, so the rows show exactly what runs and can
//     be tweaked afterward; cycling back to Off stamps them all Off.
//////////////////////////////////////////////////////////////////

function [127:0] apply_preset(input [127:0] s, input [2:0] p);
	reg [2:0] roll_v, tear_v, flag_v, skew_v, wow_v, drop_v, hsw_v, jit_v, head_v;
	reg [1:0] flut_v;
	reg       doc_v;
	begin
		case (p)
			// Levels follow the real mechanisms: VHS line timing comes from the
			// head drum (heads sweep ~4.85 m/s vs ~33 mm/s tape on SP), so a
			// working deck shows almost no wow - only small smooth jitter,
			// flutter and the head-switch hook. Tearing and real wow mean a
			// failing deck, and are kept out of the tape-wear presets. Every
			// working deck has a dropout compensator, so the tape presets
			// run with Dropout Comp on; only Damaged shows raw dropouts.
			3'd1: begin // Good VHS (SP, healthy deck): subtle head switch, flutter, faint jitter
				roll_v=3'd0; tear_v=3'd0; flag_v=3'd0; skew_v=3'd0; wow_v=3'd0; flut_v=2'd1; drop_v=3'd0; hsw_v=3'd1; jit_v=3'd1; head_v=3'd0; doc_v=1'b1;
			end
			3'd2: begin // Worn VHS: typical head switch, subtle flagwave, flutter, faint jitter, rare dropouts
				roll_v=3'd0; tear_v=3'd0; flag_v=3'd1; skew_v=3'd0; wow_v=3'd0; flut_v=2'd1; drop_v=3'd1; hsw_v=3'd2; jit_v=3'd1; head_v=3'd0; doc_v=1'b1;
			end
			3'd3: begin // EP Rental: Worn VHS + mild tear, bottom-heavy skew, more dropouts
				// (Light jitter breaks verticals into dots on a CRT - far
				// rougher than a rental tape - so it stays Faint here)
				roll_v=3'd0; tear_v=3'd1; flag_v=3'd1; skew_v=3'd2; wow_v=3'd0; flut_v=2'd1; drop_v=3'd2; hsw_v=3'd2; jit_v=3'd1; head_v=3'd0; doc_v=1'b1;
			end
			3'd4: begin // Failing Deck (the old EP Rental mix): moderate tear, skew, typical wow, flutter, typical jitter, dirty heads
				roll_v=3'd0; tear_v=3'd2; flag_v=3'd1; skew_v=3'd2; wow_v=3'd3; flut_v=2'd1; drop_v=3'd1; hsw_v=3'd2; jit_v=3'd3; head_v=3'd1; doc_v=1'b1;
			end
			3'd5: begin // Damaged: everything strong, unstable head switch, vertical drift, dirty head, no dropout comp
				roll_v=3'd5; tear_v=3'd3; flag_v=3'd2; skew_v=3'd4; wow_v=3'd4; flut_v=2'd2; drop_v=3'd3; hsw_v=3'd4; jit_v=3'd4; head_v=3'd1; doc_v=1'b0;
			end
			default: begin // Off: all errors off
				roll_v=3'd0; tear_v=3'd0; flag_v=3'd0; skew_v=3'd0; wow_v=3'd0; flut_v=2'd0; drop_v=3'd0; hsw_v=3'd0; jit_v=3'd0; head_v=3'd0; doc_v=1'b0;
			end
		endcase
		apply_preset = s;
		apply_preset[23:21]   = roll_v;
		apply_preset[27:25] = tear_v;
		apply_preset[33:31] = flag_v;
		apply_preset[36:34] = skew_v;
		apply_preset[39:37] = wow_v;
		apply_preset[41:40] = flut_v;
		apply_preset[45:43] = drop_v;
		apply_preset[48:46] = hsw_v;
		apply_preset[30:28] = jit_v;
		apply_preset[100:98] = head_v;
		apply_preset[102]    = doc_v;
	end
endfunction

// The preset-managed error fields, as one vector (excludes Sweep and
// the encoding errors, which presets do not own)
function [29:0] watched_of(input [127:0] s);
	watched_of = {s[23:21], s[27:25], s[33:31], s[36:34],
	              s[39:37], s[41:40], s[45:43], s[48:46], s[30:28],
	              s[100:98], s[102]};
endfunction
wire [29:0] watched = watched_of(status);

// Boot grace: the ARM restores saved settings shortly after core load,
// which looks like a preset "change". Arming after ~1 s keeps a saved
// configuration from being re-stamped on every load.
//
// Settle state: after any push, detection is suppressed until the ARM
// reflects the pushed values back (or a ~0.27 s timeout) — otherwise
// the core's own write-back would read as a user edit.
reg [127:0] status_in_r;
reg         status_set_r;
reg   [2:0] preset_prev;
reg  [29:0] watched_prev;
reg         t1_prev;
reg   [6:0] arm_cnt;
wire        armed = arm_cnt[6]; // 64 fields ~ 1.1 s

reg         pending;
reg  [32:0] pend_expect;
reg   [4:0] pend_cnt;
wire [32:0] managed = {vcr_preset, watched};

always @(posedge clk_sys) begin
	if (reset) begin
		status_set_r <= 1'b0;
		preset_prev  <= vcr_preset;
		watched_prev <= watched;
		t1_prev      <= 1'b0;
		arm_cnt      <= 7'd0;
		pending      <= 1'b0;
		pend_cnt     <= 5'd0;
	end else begin
		status_set_r <= 1'b0;
		t1_prev      <= status[1];
		if (new_field && !armed) arm_cnt <= arm_cnt + 7'd1;

		if (!armed) begin
			preset_prev  <= vcr_preset;
			watched_prev <= watched;
		end else if (pending) begin
			if (new_field) pend_cnt <= pend_cnt + 5'd1;
			if (managed == pend_expect) begin
				// reflection landed: re-sync and re-arm detection
				pending      <= 1'b0;
				preset_prev  <= vcr_preset;
				watched_prev <= watched;
			end else if (pend_cnt[4]) begin
				// timeout: re-arm WITHOUT syncing, so a change that
				// raced our push (e.g. rapid preset cycling) is
				// re-detected and handled on the next pass
				pending <= 1'b0;
			end
		end else if (status[1] && !t1_prev) begin
			// Factory Defaults
			status_in_r  <= 128'd0;
			status_set_r <= 1'b1;
			preset_prev  <= 3'd0;
			pending      <= 1'b1;
			pend_cnt     <= 5'd0;
			pend_expect  <= 33'd0;
		end else if (vcr_preset != preset_prev) begin
			// user changed the preset row: stamp its values
			preset_prev  <= vcr_preset;
			status_in_r  <= apply_preset(status, vcr_preset);
			status_set_r <= 1'b1;
			pending      <= 1'b1;
			pend_cnt     <= 5'd0;
			pend_expect  <= {vcr_preset, watched_of(apply_preset(status, vcr_preset))};
		end else if (watched != watched_prev) begin
			// user edited an error row directly
			watched_prev <= watched;
			if (vcr_preset != 3'd0) begin
				// the running mix is custom now: preset -> Off (Manual),
				// keeping every row (including the fresh edit) as-is
				status_in_r         <= status;
				status_in_r[19:17]  <= 3'd0;
				status_set_r        <= 1'b1;
				preset_prev         <= 3'd0;
				pending             <= 1'b1;
				pend_cnt            <= 5'd0;
				pend_expect         <= {3'd0, watched};
			end
		end
	end
end

//////////////////////////////////////////////////////////////////
// Test Mode Control
//////////////////////////////////////////////////////////////////

// Test mode is active when OSD is closed
wire test_active = ~OSD_STATUS;

// While the OSD is open, force progressive timing (constant field
// length): interlaced mode's alternating 263/262 fields make OSD text
// bob slightly on some CRTs. The configured interlace returns when the
// OSD closes - same convention as the paused errors.
wire interlace_eff = interlace_en & test_active;

// User can press Button B to exit test and reopen OSD. The virtual OSD
// button is held until the OSD opens (the ARM polls it in software, so
// a one-clock pulse would be missed) - see rtl/osd_button.sv.
wire osd_trigger;
osd_button osd_btn (
	.clk(clk_sys),
	.osd_open(OSD_STATUS),
	.btn(joystick_0[5]),
	.press(osd_trigger)
);

assign BUTTONS = {1'b0, osd_trigger};

//////////////////////////////////////////////////////////////////
// Error Injection
//////////////////////////////////////////////////////////////////

wire signed [12:0] err_h_offset;
wire signed [12:0] err_line_length_mod;
wire [8:0]         err_roll_shift;
wire [31:0] rng_value;
wire        prng_reseed;

// Errors run from the first frame start after the OSD closes (see
// error_injector): the encoding errors use the same gate, so they
// start - and their drifts and random streams restart - on the same
// line as the timing errors.
wire err_active;

error_injector error_inj (
	.clk(clk_sys),
	.reset(reset),
	.test_active(test_active),
	.pal(pal_mode),
	.v_count(v_count),
	.field(field),
	.new_line(new_line),
	.new_field(new_field),
	.roll_mode(roll_mode),
	.tear_mode(tear_mode),
	.flagwave_mode(flagwave_mode),
	.skew_mode(skew_mode),
	.wow_mode(wow_mode),
	.flutter_mode(flutter_mode),
	.dropout_mode(status[45:43]),
	.headsw_mode(status[48:46]),
	.jitter_mode(status[30:28]),
	.sweep_sel(status[51:49]),
	.prng_seed(prng_seed),
	.h_offset_out(err_h_offset),
	.line_length_mod_out(err_line_length_mod),
	.roll_shift_out(err_roll_shift),
	.dropout_eff(dropout_eff),
	.ramp_level(ramp_level),
	.rng_out(rng_value),
	.reseed_out(prng_reseed),
	.err_active(err_active)
);

wire [7:0] ramp_level;

wire [2:0] dropout_eff;
wire       drop_act;
wire [4:0] drop_mix;
wire [7:0] drop_luma;

error_dropout dropout (
	.clk(clk_sys),
	.reset(reset),
	.mode(dropout_eff),
	.h_pos(h_pos),
	.v_count(v_count),
	.new_line(new_line),
	.new_field(new_field),
	.seed(prng_seed),
	.reload(prng_reseed),
	.act(drop_act),
	.body(),
	.mix(drop_mix),
	.luma(drop_luma)
);

// Video head condition (rtl/error_head.sv): dirty / clogged heads. Runs
// with the other errors (paused while the OSD is open).
wire              hd_head_b, hd_snow, hd_cmute, hd_soft, hd_nosync;
wire signed [8:0] hd_noise;
wire        [7:0] hd_snow_luma;
error_head heads (
	.clk(clk_sys),
	.reset(reset),
	.mode(err_active ? status[100:98] : 3'd0),
	.v_count(v_count),
	.new_line(new_line),
	.seed(prng_seed),
	.reload(prng_reseed),
	.head_b(hd_head_b),
	.noise(hd_noise),
	.snow(hd_snow),
	.snow_luma(hd_snow_luma),
	.cmute(hd_cmute),
	.soften(hd_soft),
	.nosync(hd_nosync)
);

//////////////////////////////////////////////////////////////////
// NTSC Timing Generator
//////////////////////////////////////////////////////////////////

wire [11:0] h_count;
wire [8:0]  v_count;
wire        field;
wire        hsync, vsync, hblank, vblank, csync;
wire        burst_window, active_video;
wire        new_line, new_field;

ntsc_timing timing (
	.clk(clk_sys),
	.reset(reset),
	.pal(pal_mode),
	.interlace_en(interlace_eff),
	.v_shift(status[97:96]),
	.pulse_cross(pc_view),
	.pc_enhanced(pc_enh),
	.line_length_mod(err_line_length_mod),
	.h_offset(err_h_offset),
	.roll_shift(err_roll_shift),
	.h_count(h_count),
	.v_count(v_count),
	.field(field),
	.hsync(hsync),
	.vsync(vsync),
	.hblank(hblank),
	.vblank(vblank),
	.burst_window(burst_window),
	.active_video(active_video),
	.new_line(new_line),
	.new_field(new_field),
	.pc_blank(pc_blank),
	.disp_sync(disp_sync),
	.csync(csync)
);

// pulse cross pauses with the OSD open so menus stay readable.
// Enhanced (default when on) adds a relocated burst (color), a luma
// lift, and ghost marks at the true sync positions. Raw = pure sync
// relocation, nothing synthetic in the picture (B&W: the decoder's
// burst gate follows the relocated sync and finds no burst).
wire pc_view = (status[91:90] != 2'd0) & test_active;
wire pc_enh  = (status[91:90] == 2'd1) & test_active;
wire pc_blank;
wire disp_sync;

//////////////////////////////////////////////////////////////////
// Test Pattern Generator
//////////////////////////////////////////////////////////////////

// Horizontal position within active video region
// Active video starts at sample 668 in the line (at 57.272 MHz)
localparam H_ACTIVE_START = 12'd668;
wire [11:0] h_pos = (h_count >= H_ACTIVE_START) ? (h_count - H_ACTIVE_START) : 12'd0;

wire [7:0] pat_r, pat_g, pat_b;
wire       pat_cforce;
wire signed [9:0] pat_cu;

pattern_gen patterns (
	.clk(clk_sys),
	.reset(reset),
	.h_pos(h_pos),
	.v_pos(v_count),
	.active(active_video),
	.new_field(new_field),
	.pattern_sel(pattern_sel),
	.solid_color(status[11:9]),
	.window_bounce(status[13]),
	.chroma_force(pat_cforce),
	.chroma_u(pat_cu),
	.sweep_active(status[51:49] != 3'd0),
	.ramp_level(ramp_level),
	.smpte_100(smpte_100),
	.r(pat_r),
	.g(pat_g),
	.b(pat_b)
);

//////////////////////////////////////////////////////////////////
// Video Output
//
// Pixel clock, level clamp, and content muxing ahead of the custom
// Y/C encoder below. Configure mister.ini:
//   composite_sync=1
//   vga_sog=1
//   [TBC_TEST_SUITE]
//   vga_mode=rgb
//
//////////////////////////////////////////////////////////////////

assign CLK_VIDEO = clk_sys;

// Pixel clock enable: pulse every 4th clock for 14.318 MHz effective
// pixel rate (standard NTSC pixel clock = 4x color subcarrier).
// This gives 910 pixels per line (3640/4).
reg [1:0] ce_div;
always @(posedge clk_sys) begin
	if (reset)
		ce_div <= 2'd0;
	else
		ce_div <= ce_div + 2'd1;
end
assign CE_PIXEL = (ce_div == 2'd0);

// Scanlines disabled
assign VGA_SL = 2'b00;

// Video level clamping — diagnostic tool to find the Y threshold
// where constant-color patterns stop causing vertical roll on S-Video.
// Y from RGB: White(255)=255, Green(255)=150, Red(255)=76, Blue(255)=29
wire [7:0] max_level = (video_level == 2'd0) ? 8'd255 :  // Full
                        (video_level == 2'd1) ? 8'd235 :  // Limited (Y: W=235, G=138)
                        (video_level == 2'd2) ? 8'd192 :  // Medium  (Y: W=192, G=113)
                                                8'd128;   // Low     (Y: W=128, G=75)

// Custom video playback: pattern index 10 replaces the generated
// pattern with the DDRAM clip; all downstream error paths apply.
wire [7:0] vid_r, vid_g, vid_b;
wire       video_sel = (pattern_sel == 5'd10);

// Mandelbrot (pattern 16): a live zoom computed in the FPGA
// (rtl/mandel_gen.sv); restarts with every error run, so a seeded run
// replays the same frames.
wire       mandel_sel = (pattern_sel == 5'd16);
wire [7:0] man_r, man_g, man_b;
mandel_gen mandel (
	.clk(clk_sys),
	.reset(reset),
	.restart(prng_reseed),
	.new_line(new_line),
	.v_count(v_count),
	.field(field),
	.interlace(interlace_eff),
	.h_pos(h_pos),
	.active(active_video),
	.r(man_r), .g(man_g), .b(man_b)
);

wire [7:0] src_r = video_sel ? vid_r : mandel_sel ? man_r : pat_r;
wire [7:0] src_g = video_sel ? vid_g : mandel_sel ? man_g : pat_g;
wire [7:0] src_b = video_sel ? vid_b : mandel_sel ? man_b : pat_b;

// Channel ident banner: stamped into the video (rides through the DUT
// into captured footage, unlike the OSD). Suppressed on the Analysis
// pattern so the machine-read geometry stays intact.
wire       bn_act;
wire [7:0] bn_r, bn_g, bn_b;
ident_banner banner (
	.clk(clk_sys),
	.reset(reset),
	// suppressed on Analysis and the WFM measurement patterns
	.enable(status[2] && ((pattern_sel < 5'd11) || mandel_sel)),
	.px(h_pos[11:2]),
	.py(v_count),
	.active(active_video),
	.act(bn_act),
	.r(bn_r), .g(bn_g), .b(bn_b)
);

wire [7:0] ovl_r = bn_act ? bn_r : src_r;
wire [7:0] ovl_g = bn_act ? bn_g : src_g;
wire [7:0] ovl_b = bn_act ? bn_b : src_b;

wire [7:0] clamp_pre_r = (ovl_r > max_level) ? max_level : ovl_r;
wire [7:0] clamp_pre_g = (ovl_g > max_level) ? max_level : ovl_g;
wire [7:0] clamp_pre_b = (ovl_b > max_level) ? max_level : ovl_b;

// VBI closed captions: an EIA-608 "TBC TEST" caption on line 21 of
// field 1. Feeding the level into R=G=B makes both encoders emit it as
// pure luma (Y exact, U=V=0), riding the blanking interval where the
// pattern is black anyway. A DUT that regenerates blanking strips it —
// a decodable pass/fail VBI transparency test.
wire [7:0] cc_level;
wire       cc_act;
vbi_cc vbi (
	.clk(clk_sys),
	.reset(reset),
	.enable(status[88] && !pal_mode),
	.h_count(h_count),
	.v_count(v_count),
	.field(field),
	.v_shift(status[97:96]),
	.new_field(new_field),
	.level(cc_level),
	.act(cc_act)
);

// pc_blank (pulse cross) overrides everything: the relocated sync
// needs a clean blanking pedestal under it
wire [7:0] clamp_r = pc_blank ? 8'd0 : (cc_act ? cc_level : clamp_pre_r);
wire [7:0] clamp_g = pc_blank ? 8'd0 : (cc_act ? cc_level : clamp_pre_g);
wire [7:0] clamp_b = pc_blank ? 8'd0 : (cc_act ? cc_level : clamp_pre_b);

//////////////////////////////////////////////////////////////////
// Custom Y/C Encoder with encoding-level errors
//
// Requires mister.ini [TBC_TEST_SUITE] vga_mode=rgb (framework yc_out
// bypassed; sync still arrives via composite_sync=1 + vga_sog=1).
// With HDMI View = Encoded Raw, HDMI shows Y-as-green/C-as-red false color.
//////////////////////////////////////////////////////////////////

// Hue Shift control: fixed offsets, or Drift (generated in the encoder,
// 1 LUT step/field, full 360-degree rotation every ~4.3 s)
reg [7:0] hue_offset;
always @(*) begin
	case (hue_mode)
		3'd1:    hue_offset = 8'd8;    // +11 deg
		3'd2:    hue_offset = 8'd32;   // +45 deg
		3'd3:    hue_offset = 8'd64;   // +90 deg
		3'd4:    hue_offset = 8'd128;  // 180 deg
		3'd5:    hue_offset = 8'd224;  // -45 deg
		default: hue_offset = 8'd0;
	endcase
end

wire [7:0] chroma_delay = (cdelay_mode == 3'd1) ? 8'd6   :   // ~100 ns
                          (cdelay_mode == 3'd2) ? 8'd14  :   // ~250 ns
                          (cdelay_mode == 3'd3) ? 8'd29  :   // ~500 ns
                          (cdelay_mode == 3'd4) ? 8'd57  :   // ~1 us
                          (cdelay_mode == 3'd5) ? 8'd115 :   // ~2 us
                          (cdelay_mode >= 3'd6) ? 8'd255 :   // ~4.5 us
                                                  8'd0;

// Encoding errors pause while the OSD is open, like the timing errors,
// and start with them at the run start
wire [7:0] hue_eff    = err_active ? hue_offset   : 8'd0;
wire       hdrift_eff = err_active && (hue_mode == 3'd6);
wire [2:0] blevel_eff = err_active ? burst_level  : 3'd0;
wire [2:0] sc_eff     = err_active ? sc_mode      : 3'd0;
wire [7:0] cdelay_eff = err_active ? chroma_delay : 8'd0;
wire [1:0] cnoise_eff = err_active ? cnoise_mode  : 2'd0;

wire [7:0] enc_y, enc_c, enc_lum;
yc_encoder yc_enc (
	.clk(clk_sys),
	.reset(reset),
	.pal(pal_mode),
	.cvbs(status[87]),
	.r(clamp_r), .g(clamp_g), .b(clamp_b),
	.burst_window(burst_window),
	.new_line(new_line),
	.seed(prng_seed),
	.reload(prng_reseed),
	.new_field(new_field),
	.hue_offset(hue_eff),
	.hue_drift(hdrift_eff),
	.burst_level(blevel_eff),
	.sc_mode(sc_eff),
	.chroma_delay(cdelay_eff),
	.noise_mode(cnoise_eff),
	.chroma_bw(status[72]),
	.chroma_force(pat_cforce && !video_sel),
	.chroma_u(pat_cu),
	.y_out(enc_y),
	.c_out(enc_c),
	.y_lum(enc_lum)
);

// A/B reference: the framework's own yc_out instantiated in-core on the
// same clock and pins, PHASE_INC/COLORBURST_RANGE hardcoded to the values
// the ARM would send (2^36; burst window 40-240 clks after hsync).
wire [23:0] ycref_dout;
yc_out yc_ref (
	.clk(clk_sys),
	.PHASE_INC(pal_mode ? 40'd85115823899 : 40'd68719476736),
	.PAL_EN(pal_mode),
	.CVBS(1'b0),
	// Exact values the ARM computes (start = 3.7 cycles after hsync end,
	// 9 cycles long): NTSC 16 clk/cycle, PAL 12.92 clk/cycle
	.COLORBURST_RANGE(pal_mode ? {7'd48, 10'd164} : {7'd59, 10'd203}),
	.hsync(hsync),
	.vsync(vsync),
	.csync(1'b0),
	.de(~(hblank | vblank)),
	.din({clamp_r, clamp_g, clamp_b}),
	.dout(ycref_dout),
	.hsync_o(),
	.vsync_o(),
	.csync_o(),
	.de_o()
);

wire use_ref = status[53];
// Dropouts gate the ENCODED signals (they are an RF/demodulation defect,
// not picture content): luma collapses to bright FM noise, chroma dies,
// and long events run straight through hsync/burst like real tape.
wire [7:0] out_y = use_ref ? ycref_dout[15:8]  : enc_y;
wire [7:0] out_c = use_ref ? ycref_dout[23:16] : enc_c;

// Dropout insertion + pulse-cross viewing aids (rtl/out_stage.sv)
out_stage out_stg (
	.clk(clk_sys),
	.out_y(out_y),
	.out_c(out_c),
	.lum(use_ref ? out_y : enc_lum),
	.cvbs(status[87] && !use_ref),   // the framework reference never runs CVBS
	.pal(pal_mode),
	.drop_act(drop_act),
	.drop_mix(drop_mix),
	.drop_luma(drop_luma),
	.doc_en(status[102]),
	.hd_noise(hd_noise),
	.hd_snow(hd_snow),
	.hd_snow_luma(hd_snow_luma),
	.hd_cmute(hd_cmute),
	.hd_soft(hd_soft),
	.pc_enh(pc_enh),
	.pc_blank(pc_blank),
	.disp_sync(disp_sync),
	.y(VGA_G),                        // MikeS11 Y
	.c(VGA_R)                         // MikeS11 C
);
assign VGA_B  = 8'd0;

//////////////////////////////////////////////////////////////////
// Clean-HDMI framebuffer
//
// The HDMI scaler reads a DDRAM framebuffer holding the clean RGB
// pattern (written by position, so it is immune to timing errors),
// while the analog output carries the custom Y/C. "HDMI View:
// Encoded Raw" disables the framebuffer to expose the raw Y/C
// channels on HDMI for debugging.
//////////////////////////////////////////////////////////////////

`ifdef MISTER_FB
assign FB_EN          = ~status[95];
assign FB_FORMAT      = 5'b10100;      // 16bpp 565, BGR flag set to match packing
assign FB_WIDTH       = 12'd724;
assign FB_HEIGHT      = 12'd240;
assign FB_BASE        = 32'h3F80_0000;
assign FB_STRIDE      = 14'd2048;
assign FB_FORCE_BLANK = 0;
`endif

wire        fbw_wr, fbw_ack;
wire [28:0] fbw_addr;
wire [63:0] fbw_din;

// The framebuffer takes the pattern BEFORE the pulse-cross blanking:
// HDMI is the clean reference, and pc_blank's relocated-sync pedestal
// otherwise showed up on it as black stripes through the picture.
fb_writer fb_wr (
	.clk(clk_sys),
	.reset(reset),
	.r(clamp_pre_r), .g(clamp_pre_g), .b(clamp_pre_b),
	.h_pos(h_pos),
	.v_pos(v_count),
	.active(active_video),
	.ddram_write(fbw_wr),
	.ddram_addr(fbw_addr),
	.ddram_din(fbw_din),
	.ddram_be(),
	.ddram_burstcnt(),
	.ddram_busy(~fbw_ack)
);

//////////////////////////////////////////////////////////////////
// Custom video: loader (OSD file -> DDR) + player (DDR -> pixels)
//////////////////////////////////////////////////////////////////

wire        ldw_req, ldw_ack;
wire [28:0] ldw_addr;
wire [63:0] ldw_din;
wire        vload_loading;
wire [8:0]  vload_frames;

video_loader vload (
	.clk(clk_sys),
	.reset(reset),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_dout(ioctl_dout),
	.ldw_req(ldw_req),
	.ldw_addr(ldw_addr),
	.ldw_din(ldw_din),
	.ldw_ack(ldw_ack),
	.loading(vload_loading),
	.frame_count(vload_frames)
);

wire        vrd_req, vrd_ack;
wire [28:0] vrd_addr;
wire [7:0]  vrd_burstcnt;
wire        posw_req, posw_ack;
wire [28:0] posw_addr;
wire [63:0] posw_din;

video_player vplay (
	.clk(clk_sys),
	.reset(reset),
	.enable(video_sel),
	.h_pos(h_pos),
	.v_count(v_count),
	.field(field),
	.active(active_video),
	.new_line(new_line),
	.new_field(new_field),
	.frame_count(vload_frames),
	.loading(vload_loading),
	.rd_req(vrd_req),
	.rd_addr(vrd_addr),
	.rd_burstcnt(vrd_burstcnt),
	.rd_ack(vrd_ack),
	.ddram_dout(DDRAM_DOUT),
	.ddram_dout_ready(DDRAM_DOUT_READY),
	.posw_req(posw_req),
	.posw_addr(posw_addr),
	.posw_din(posw_din),
	.posw_ack(posw_ack),
	.r(vid_r), .g(vid_g), .b(vid_b)
);

ddram_mux dmux (
	.clk(clk_sys),
	.reset(reset),
	.rd_req(vrd_req),
	.rd_addr(vrd_addr),
	.rd_burstcnt(vrd_burstcnt),
	.rd_ack(vrd_ack),
	.ldw_req(ldw_req),
	.ldw_addr(ldw_addr),
	.ldw_din(ldw_din),
	.ldw_ack(ldw_ack),
	.fbw_req(fbw_wr),
	.fbw_addr(fbw_addr),
	.fbw_din(fbw_din),
	.fbw_ack(fbw_ack),
	.posw_req(posw_req),
	.posw_addr(posw_addr),
	.posw_din(posw_din),
	.posw_ack(posw_ack),
	.ddram_read(DDRAM_RD),
	.ddram_write(DDRAM_WE),
	.ddram_addr(DDRAM_ADDR),
	.ddram_din(DDRAM_DIN),
	.ddram_burstcnt(DDRAM_BURSTCNT),
	.ddram_be(DDRAM_BE),
	.ddram_busy(DDRAM_BUSY)
);
// Standard composite sync (equalizing + serrated broad pulses, half-line
// interlace) from ntsc_timing; framework mod #3 passes it through the
// csync combiner unchanged. VGA_VS still drives the OSD/scaler.
// A clogged head's fields carry no sync at all (the enhanced pulse-cross
// scaffold keeps its sync so the monitor stays locked).
assign VGA_HS = csync & ~(hd_nosync & ~pc_enh);
assign VGA_VS = vsync;
assign VGA_DE = ~(hblank | vblank);
assign VGA_F1 = interlace_eff & field;

//////////////////////////////////////////////////////////////////
// LED: breathing pattern to show core is active
//////////////////////////////////////////////////////////////////

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];

endmodule

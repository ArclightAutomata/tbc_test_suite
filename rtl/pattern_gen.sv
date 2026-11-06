// SPDX-License-Identifier: GPL-2.0-or-later
// Test Pattern Generator
// Generates standard video test patterns as 8-bit RGB
// Active area: 2900 samples wide x 240 lines tall (at 57.272 MHz)

module pattern_gen (
	input        clk,
	input        reset,
	input [11:0] h_pos,        // horizontal position within active video (0-2899)
	input [8:0]  v_pos,        // vertical position within active video (0-239)
	input        active,       // high during active video region
	input        new_field,    // for Motion pattern animation
	input [4:0]  pattern_sel,  // pattern selection from OSD
	input [2:0]  solid_color,  // Solid Color pattern: color select
	input        window_bounce, // Window pattern: 0=static, 1=bounce (~1 s APL slam)
	input        smpte_100,    // 0 = 75% bars, 1 = 100% bars
	input        sweep_active, // severity sweep running: draw the gauge overlay
	input [7:0]  ramp_level,   // current sweep severity for the gauge

	output reg [7:0] r,
	output reg [7:0] g,
	output reg [7:0] b,

	// Forced-chroma side channel for the WFM measurement patterns
	// (modulated staircase/ramp, 12.5T pulse): the encoder modulates
	// this U amplitude directly instead of deriving UV from RGB
	output reg        chroma_force,
	output reg signed [9:0] chroma_u
);

// Pattern indices
localparam PAT_LOGO         = 5'd0;
localparam PAT_COLORBARS    = 5'd1;
localparam PAT_CROSSHATCH   = 5'd2;
localparam PAT_GRAYSCALE    = 5'd3;
localparam PAT_MULTIBURST   = 5'd4;
localparam PAT_SOLID        = 5'd5;
localparam PAT_CHECKERBOARD = 5'd6;
localparam PAT_PLUGE        = 5'd7;
localparam PAT_CONVERGENCE  = 5'd8;
localparam PAT_MOTION       = 5'd9;
localparam PAT_ANALYSIS     = 5'd11;   // 10 = Custom Video (handled upstream)
localparam PAT_MODSTAIR     = 5'd12;
localparam PAT_MODRAMP      = 5'd13;
localparam PAT_PULSEBAR     = 5'd14;
localparam PAT_WINDOW       = 5'd15;

// Window: centered 100 IRE box on black - DC restoration / clamp and
// field-tilt test (shading above/below the box exposes a bad clamp).
// Bounce: every ~1 s the background slams black<->white while the box
// stays inverted against it - maximum APL step for AGC/clamp recovery
// measurement (the box remains as a constant reference element).
wire win_box = (h_pos >= 12'd967) && (h_pos < 12'd1933) &&
               (v_pos >= 9'd80)   && (v_pos < 9'd160);
reg       bounce_ph;
reg [5:0] bounce_cnt;
always @(posedge clk) begin
	if (reset) begin
		bounce_ph  <= 1'b0;
		bounce_cnt <= 6'd0;
	end else if (new_field) begin
		if (bounce_cnt == 6'd59) begin
			bounce_cnt <= 6'd0;
			bounce_ph  <= ~bounce_ph;
		end else begin
			bounce_cnt <= bounce_cnt + 6'd1;
		end
	end
end
wire [7:0] win_y = (win_box ^ (window_bounce && bounce_ph)) ? 8'd255 : 8'd0;

// ---- Waveform-monitor measurement patterns (Tek-style) ----
// Modulated staircase: 5 luma steps (0/20/40/60/80 IRE) with constant
// 40 IRE p-p chroma on every step -> differential gain/phase.
// Modulated ramp: 0-100 IRE luma ramp, same chroma -> finer DG/DP.
// Pulse & Bar: 100 IRE bar with raised-cosine edges, 2T sine-squared
// pulse (K-factor / transient response), 12.5T chroma-modulated pulse
// (chroma-to-luma delay and gain by the standard method).
wire [7:0] stair_y = (h_pos < 12'd580)  ? 8'd0   :
                     (h_pos < 12'd1160) ? 8'd51  :
                     (h_pos < 12'd1740) ? 8'd102 :
                     (h_pos < 12'd2320) ? 8'd153 : 8'd204;
wire [18:0] ramp_prod = h_pos * 7'd90;
wire [7:0]  ramp_y    = ramp_prod[17:10];   // 0..254 across the line

// Pulse & Bar regions (sample units within the active line)
wire [11:0] pb_bar_r = h_pos - 12'd290;
wire [11:0] pb_bar_f = h_pos - 12'd1281;
wire [11:0] pb_d2t   = h_pos - 12'd1736;
wire [11:0] pb_d125  = h_pos - 12'd2030;
wire pb_bar_rise = (h_pos >= 12'd290)  && (h_pos < 12'd319);
wire pb_bar_body = (h_pos >= 12'd319)  && (h_pos < 12'd1281);
wire pb_bar_fall = (h_pos >= 12'd1281) && (h_pos < 12'd1310);
wire pb_in_2t    = (h_pos >= 12'd1736) && (h_pos < 12'd1765);   // 29 samples = 2T base
wire pb_in_125t  = (h_pos >= 12'd2030) && (h_pos < 12'd2209);   // 179 samples = 12.5T base

// One shared sine LUT evaluates every sine-squared shape:
// s = (1 - cos(theta))/2 scaled to 0..255
// (products computed in explicitly wide wires - inside the 8-bit
// wfm_addr expression they would be evaluated at 8 bits and wrap)
wire [12:0] wfm_p2t  = pb_d2t[4:0]   * 8'd141;   // full cycle over 29 samples
wire [16:0] wfm_p125 = pb_d125[7:0]  * 9'd366;   // full cycle over 179 samples
wire [11:0] wfm_pbr  = pb_bar_r[4:0] * 7'd71;    // half cycle over 29 samples
wire [11:0] wfm_pbf  = pb_bar_f[4:0] * 7'd71;
reg [7:0] wfm_addr;
always @(*) begin
	wfm_addr = 8'd64;                                        // cos(0): s = 0
	if (pb_in_2t)         wfm_addr = 8'd64 + wfm_p2t[11:4];
	else if (pb_in_125t)  wfm_addr = 8'd64 + wfm_p125[15:8];
	else if (pb_bar_rise) wfm_addr = 8'd64 + {1'b0, wfm_pbr[10:4]};
	else if (pb_bar_fall) wfm_addr = 8'd64 + {1'b0, wfm_pbf[10:4]};
end
// Pipeline stage: register the LUT address and region flags so the
// multiply -> LUT -> combine cone spans two cycles (the WFM patterns
// land one sample later than the others - irrelevant)
reg [7:0] wfm_addr_q;
reg       pb_body_q, pb_rise_q, pb_fall_q, pb_2t_q, pb_125_q;
reg [7:0] stair_q, ramp_q;
always @(posedge clk) begin
	wfm_addr_q <= wfm_addr;
	pb_body_q  <= pb_bar_body;
	pb_rise_q  <= pb_bar_rise;
	pb_fall_q  <= pb_bar_fall;
	pb_2t_q    <= pb_in_2t;
	pb_125_q   <= pb_in_125t;
	stair_q    <= stair_y;
	ramp_q     <= ramp_y;
end

wire signed [10:0] wfm_c;
sine_lut wfm_lut (.addr(wfm_addr_q), .data(wfm_c));
wire signed [11:0] wfm_diff = 12'sd255 - wfm_c;
wire [7:0] wfm_s = wfm_diff[8:1];

reg [7:0] pb_y;
always @(*) begin
	pb_y = 8'd0;
	if (pb_body_q)      pb_y = 8'd255;
	else if (pb_rise_q) pb_y = wfm_s;
	else if (pb_fall_q) pb_y = 8'd255 - wfm_s;
	else if (pb_2t_q)   pb_y = wfm_s;
	else if (pb_125_q)  pb_y = {1'b0, wfm_s[7:1]};   // 50 IRE pedestal under the chroma
end

// Forced chroma: |u| 104 ~ 40 IRE p-p (burst amplitude, verified by
// sim/modstair); the 12.5T envelope peaks at ~260 ~ 100 IRE p-p so the
// composite spans 0-100 IRE. The staircase/ramp subcarrier sits at
// BURST phase (-U, as NTC-7 / Tek generators do, so a vectorscope shows
// it on the burst vector); +104 had put it 180 deg away.
wire wfm_chroma = (pattern_sel == PAT_MODSTAIR) || (pattern_sel == PAT_MODRAMP) ||
                  ((pattern_sel == PAT_PULSEBAR) && pb_125_q);
wire signed [9:0] wfm_u = (pattern_sel == PAT_PULSEBAR)
                        ? ({2'd0, wfm_s} + {8'd0, wfm_s[7:6]})
                        : -10'sd104;

// Solid Color pattern: primaries/secondaries at the selected Level
// (75% = broadcast red-field practice, 100% = max-chroma stress),
// plus black. Shares the Level control with Color Bars/Motion.
reg [2:0] solid_bits;
always @(*) begin
	case (solid_color)
		3'd0:    solid_bits = 3'b111;  // White
		3'd1:    solid_bits = 3'b110;  // Yellow
		3'd2:    solid_bits = 3'b011;  // Cyan
		3'd3:    solid_bits = 3'b010;  // Green
		3'd4:    solid_bits = 3'b101;  // Magenta
		3'd5:    solid_bits = 3'b100;  // Red
		3'd6:    solid_bits = 3'b001;  // Blue
		default: solid_bits = 3'b000;  // Black
	endcase
end
wire [23:0] solid_rgb = {solid_bits[2] ? bar_max : 8'd0,
                         solid_bits[1] ? bar_max : 8'd0,
                         solid_bits[0] ? bar_max : 8'd0};

// Fixed thresholds for 7 color bars (2900 / 7 ≈ 414 pixels each)
wire [2:0] bar_index = (h_pos < 12'd414)  ? 3'd0 :
                       (h_pos < 12'd828)  ? 3'd1 :
                       (h_pos < 12'd1243) ? 3'd2 :
                       (h_pos < 12'd1657) ? 3'd3 :
                       (h_pos < 12'd2071) ? 3'd4 :
                       (h_pos < 12'd2486) ? 3'd5 :
                                            3'd6;

// 75% and 100% color bar values
wire [7:0] bar_max = smpte_100 ? 8'd255 : 8'd191;

// Color bar RGB: White, Yellow, Cyan, Green, Magenta, Red, Blue
reg [7:0] bar_r, bar_g, bar_b;
always @(*) begin
	case (bar_index)
		3'd0: begin bar_r = bar_max; bar_g = bar_max; bar_b = bar_max; end
		3'd1: begin bar_r = bar_max; bar_g = bar_max; bar_b = 8'd0;   end
		3'd2: begin bar_r = 8'd0;   bar_g = bar_max; bar_b = bar_max; end
		3'd3: begin bar_r = 8'd0;   bar_g = bar_max; bar_b = 8'd0;   end
		3'd4: begin bar_r = bar_max; bar_g = 8'd0;   bar_b = bar_max; end
		3'd5: begin bar_r = bar_max; bar_g = 8'd0;   bar_b = 8'd0;   end
		3'd6: begin bar_r = 8'd0;   bar_g = 8'd0;   bar_b = bar_max; end
		default: begin bar_r = 8'd0; bar_g = 8'd0;   bar_b = 8'd0;   end
	endcase
end

// SMPTE vertical sections: top 67% (0-159), middle 8% (160-179), bottom 25% (180-239)
wire in_top    = (v_pos < 9'd160);
wire in_middle = (v_pos >= 9'd160) && (v_pos < 9'd180);

// Reverse + complement bars for middle section
wire [2:0] rev_bar_index = 3'd6 - bar_index;
reg [7:0] rev_r, rev_g, rev_b;
always @(*) begin
	case (rev_bar_index)
		3'd0: begin rev_r = 8'd0;   rev_g = 8'd0;   rev_b = bar_max; end
		3'd1: begin rev_r = 8'd0;   rev_g = 8'd0;   rev_b = 8'd0;   end
		3'd2: begin rev_r = bar_max; rev_g = 8'd0;   rev_b = bar_max; end
		3'd3: begin rev_r = 8'd0;   rev_g = 8'd0;   rev_b = 8'd0;   end
		3'd4: begin rev_r = 8'd0;   rev_g = bar_max; rev_b = bar_max; end
		3'd5: begin rev_r = 8'd0;   rev_g = 8'd0;   rev_b = 8'd0;   end
		3'd6: begin rev_r = bar_max; rev_g = bar_max; rev_b = bar_max; end
		default: begin rev_r = 8'd0; rev_g = 8'd0;   rev_b = 8'd0;   end
	endcase
end

// PLUGE section (bottom 25%)
reg [7:0] pluge_r, pluge_g, pluge_b;
always @(*) begin
	if (h_pos < 12'd483) begin       // Sub-black reference
		pluge_r = 8'd0; pluge_g = 8'd0; pluge_b = 8'd0;
	end else if (h_pos < 12'd644) begin // Just above black (+4 IRE)
		pluge_r = 8'd12; pluge_g = 8'd12; pluge_b = 8'd12;
	end else if (h_pos < 12'd1933) begin // Black
		pluge_r = 8'd0; pluge_g = 8'd0; pluge_b = 8'd0;
	end else if (h_pos < 12'd2416) begin // White reference
		pluge_r = 8'd255; pluge_g = 8'd255; pluge_b = 8'd255;
	end else begin                        // Black
		pluge_r = 8'd0; pluge_g = 8'd0; pluge_b = 8'd0;
	end
end

// Pixel index at the 14.318 MHz pixel rate (4 samples per pixel, 0-724).
// Fine pattern features must be whole pixels wide: the HDMI scaler samples
// once per CE_PIXEL, so features narrower than 4 samples can fall between
// sample points and vanish from HDMI entirely (analog shows them fine).
wire [9:0] px = h_pos[11:2];

// Crosshatch: 1-px vertical line every 32 px, horizontal line every 32 lines
wire cross_vline = (px[4:0] == 5'd0) || (px >= 10'd724);
wire cross_hline = (v_pos[4:0] == 5'd0) || (v_pos >= 9'd239);
wire crosshatch = cross_vline || cross_hline;

// Grayscale ramp: h_pos/12 gives 0-241, close to full 8-bit range
// Use multiply-shift: (h_pos * 22) >> 8 ≈ h_pos * 0.086 ≈ 0..249
wire [19:0] gray_product = h_pos * 12'd22;
wire [7:0] gray_level = (gray_product[15:8] > 8'd255) ? 8'd255 : gray_product[15:8];

// Multiburst: alternating B/W at increasing frequencies
reg multiburst_on;
always @(*) begin
	if      (h_pos < 12'd483)  multiburst_on = h_pos[7];  // ~0.25 MHz
	else if (h_pos < 12'd966)  multiburst_on = h_pos[6];  // ~0.5 MHz
	else if (h_pos < 12'd1449) multiburst_on = h_pos[5];  // ~1 MHz
	else if (h_pos < 12'd1933) multiburst_on = h_pos[4];  // ~2 MHz
	else if (h_pos < 12'd2416) multiburst_on = h_pos[3];  // ~3.58 MHz
	else                        multiburst_on = h_pos[2];  // ~7 MHz
end

// Checkerboard: 32x16 pixel squares
wire checker_on = h_pos[5] ^ v_pos[4];

// Convergence dots: 1 px wide x 2 lines tall, every 32 px x 32 lines
wire conv_dot = (px[4:0] == 5'd0) && (v_pos[4:0] < 5'd2);

// Motion pattern (testsrc2-inspired): animated elements over the color
// bars, all inside the CRT-safe area. Motion makes field/frame handling
// errors visible in a way no static pattern can; the progress bar and
// blinker (0.53 s on/off) expose dropped or repeated fields.
reg [15:0] frm;
always @(posedge clk) begin
	if (reset) frm <= 16'd0;
	else if (new_field) frm <= frm + 16'd1;
end

// scrolling diagonal band
wire [11:0] band_sum = h_pos + {3'd0, v_pos} * 12'd8 + {frm[6:0], 5'd0};
wire mot_band = (band_sum[10:0] < 11'd128);

// bouncing box (triangle-wave X and Y)
wire [7:0] tri_x = frm[8] ? ~frm[7:0] : frm[7:0];
wire [6:0] tri_y = frm[7] ? ~frm[6:0] : frm[6:0];
wire [11:0] box_x = 12'd160 + {1'd0, tri_x, 3'd0};      // 160-2200 samples
wire [8:0]  box_y = 9'd60 + {2'd0, tri_y};              // lines 60-187
wire mot_box = (h_pos >= box_x) && (h_pos < box_x + 12'd192) &&
               (v_pos >= box_y) && (v_pos < box_y + 9'd40);

// field-counter progress bar (top, safe area) and 0.53 s blinker
wire [11:0] bar_end = 12'd168 + {frm[7:0], 3'd0} + {frm[7:0], 1'd0};  // 168 + frm*10
wire mot_bar   = (v_pos >= 9'd16) && (v_pos < 9'd24) &&
                 (h_pos >= 12'd168) && (h_pos < bar_end);
wire mot_blink = (v_pos >= 9'd16) && (v_pos < 9'd24) &&
                 (h_pos >= 12'd2600) && (h_pos < 12'd2732) && frm[5];

// static checker patch (bottom right)
wire mot_check = (h_pos >= 12'd2200) && (h_pos < 12'd2732) &&
                 (v_pos >= 9'd176) && (v_pos < 9'd224) &&
                 (h_pos[6] ^ v_pos[3]);

// Analysis pattern: machine-readable elements for tools/tbc_analyze.py.
// Geometry contract (pattern px = h_pos/4, line = v_pos) is documented
// in the script header - keep the two in sync.
wire ana_border = (px >= 10'd44 && px <= 10'd680) &&
                  (v_pos >= 9'd18 && v_pos <= 9'd222) &&
                  (px <= 10'd45 || px >= 10'd679 || v_pos <= 9'd19 || v_pos >= 9'd221);

// per-field ID barcode: 20 blocks of 28 px from x=64, lines 28-43
// [1][0][16-bit field count MSB first][even parity][field LSB]
wire [9:0]  ana_bx  = px - 10'd64;
wire [4:0]  ana_blk = ana_bx / 10'd28;
wire [19:0] ana_bits = {1'b1, 1'b0, frm[15:0], ^frm[15:0], frm[0]};
wire ana_barcode_zone = (v_pos >= 9'd28) && (v_pos < 9'd44) &&
                        (px >= 10'd64) && (ana_blk < 5'd20);
wire ana_barcode_on = ana_bits[5'd19 - ana_blk];

// jitter rulers: 2 px white verticals on black, x = 180/362/544, lines 56-200
wire ana_ruler_zone = (v_pos >= 9'd56) && (v_pos <= 9'd200) &&
                      (px >= 10'd64) && (px <= 10'd676);
wire ana_ruler = (px == 10'd180) || (px == 10'd181) ||
                 (px == 10'd362) || (px == 10'd363) ||
                 (px == 10'd544) || (px == 10'd545);

// color strip: 7 bars of 75% colors, lines 204-217, x 64-675
wire ana_cstrip = (v_pos >= 9'd204) && (v_pos < 9'd218) &&
                  (px >= 10'd64) && (px < 10'd676);
wire [2:0] ana_cbar = (px < 10'd151) ? 3'd0 : (px < 10'd239) ? 3'd1 :
                      (px < 10'd326) ? 3'd2 : (px < 10'd414) ? 3'd3 :
                      (px < 10'd501) ? 3'd4 : (px < 10'd589) ? 3'd5 : 3'd6;
reg [23:0] ana_crgb;
always @(*) begin
	case (ana_cbar)
		3'd0: ana_crgb = 24'hBFBFBF;
		3'd1: ana_crgb = 24'hBFBF00;
		3'd2: ana_crgb = 24'h00BFBF;
		3'd3: ana_crgb = 24'h00BF00;
		3'd4: ana_crgb = 24'hBF00BF;
		3'd5: ana_crgb = 24'hBF0000;
		default: ana_crgb = 24'h0000BF;
	endcase
end

// Severity gauge overlay (drawn on every pattern while a sweep runs):
// growing white bar with yellow 25% ticks, plus the level as an 8-bit
// mini-barcode so captures are machine-readable. Lines 224-231.
wire gauge_zone = sweep_active && (v_pos >= 9'd224) && (v_pos < 9'd232) &&
                  (px >= 10'd60) && (px < 10'd672);
wire gauge_bar  = (px >= 10'd64) && (px < 10'd64 + {2'd0, ramp_level, 1'b0});
wire gauge_tick = (px == 10'd192) || (px == 10'd320) ||
                  (px == 10'd447) || (px == 10'd575);
wire [2:0] gbit = 3'd7 - ((px - 10'd600) >> 3);
wire gauge_code_zone = (px >= 10'd600) && (px < 10'd664);
wire gauge_code_on   = ramp_level[gbit];

// Logo pattern ROM (project ident / landing screen)
wire [7:0] logo_r, logo_g, logo_b;
logo_rom logo (
	.clk(clk),
	.px(px),
	.py(v_pos),
	.r(logo_r), .g(logo_g), .b(logo_b)
);

// Pattern output mux
always @(posedge clk) begin
	// forced chroma rides alongside the RGB, aligned with it
	chroma_force <= active && wfm_chroma;
	chroma_u     <= wfm_u;

	if (!active) begin
		r <= 8'd0; g <= 8'd0; b <= 8'd0;
	end else begin
		case (pattern_sel)
			PAT_LOGO: begin
				r <= logo_r; g <= logo_g; b <= logo_b;
			end
			PAT_COLORBARS: begin
				if (in_top)         begin r <= bar_r;   g <= bar_g;   b <= bar_b;   end
				else if (in_middle) begin r <= rev_r;   g <= rev_g;   b <= rev_b;   end
				else                begin r <= pluge_r; g <= pluge_g; b <= pluge_b; end
			end
			PAT_CROSSHATCH: begin
				{r, g, b} <= crosshatch ? 24'hFFFFFF : 24'h000000;
			end
			PAT_GRAYSCALE: begin
				r <= gray_level; g <= gray_level; b <= gray_level;
			end
			PAT_MULTIBURST: begin
				{r, g, b} <= multiburst_on ? 24'hFFFFFF : 24'h000000;
			end
			PAT_SOLID:       {r, g, b} <= solid_rgb;
			PAT_CHECKERBOARD: begin
				{r, g, b} <= checker_on ? 24'hFFFFFF : 24'h000000;
			end
			PAT_PLUGE: begin
				r <= pluge_r; g <= pluge_g; b <= pluge_b;
			end
			PAT_CONVERGENCE: begin
				{r, g, b} <= conv_dot ? 24'hFFFFFF : 24'h000000;
			end
			PAT_MOTION: begin
				if (mot_bar)        {r, g, b} <= 24'hFFFFFF;
				else if (mot_blink) {r, g, b} <= 24'hFFFF00;
				else if (mot_box)   {r, g, b} <= 24'h808080;
				else if (mot_band)  {r, g, b} <= 24'hE0E0E0;
				else if (mot_check) {r, g, b} <= 24'h40E0E0;
				else                begin r <= bar_r; g <= bar_g; b <= bar_b; end
			end
			PAT_MODSTAIR: begin r <= stair_q; g <= stair_q; b <= stair_q; end
			PAT_MODRAMP:  begin r <= ramp_q;  g <= ramp_q;  b <= ramp_q;  end
			PAT_PULSEBAR: begin r <= pb_y;    g <= pb_y;    b <= pb_y;    end
			PAT_WINDOW:   begin r <= win_y;   g <= win_y;   b <= win_y;   end
			PAT_ANALYSIS: begin
				if (ana_border)            {r, g, b} <= 24'hFFFFFF;
				else if (ana_barcode_zone) {r, g, b} <= ana_barcode_on ? 24'hFFFFFF : 24'h000000;
				else if (ana_ruler_zone)   {r, g, b} <= ana_ruler ? 24'hFFFFFF : 24'h000000;
				else if (ana_cstrip)       {r, g, b} <= ana_crgb;
				else                       {r, g, b} <= 24'h808080;
			end
			default: begin r <= 8'd0; g <= 8'd0; b <= 8'd0; end
		endcase
		// gauge overrides whatever the pattern drew in its zone
		if (gauge_zone) begin
			if (gauge_code_zone)  {r, g, b} <= gauge_code_on ? 24'hFFFFFF : 24'h000000;
			else if (gauge_tick)  {r, g, b} <= 24'hFFFF00;
			else if (gauge_bar)   {r, g, b} <= 24'hFFFFFF;
			else                  {r, g, b} <= 24'h202020;
		end
	end
end

endmodule

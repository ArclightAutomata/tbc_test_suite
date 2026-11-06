// SPDX-License-Identifier: GPL-2.0-or-later
// NTSC/PAL Timing Generator
// Generates horizontal and vertical counters with sync, blanking, and burst windows
// Clock: 57.272727 MHz (16x NTSC color subcarrier)
// NTSC: 3640 samples per line, 262 lines per field (progressive) or
// 262.5 (interlaced: 263/262 whole lines with the 263-line field's
// vertical interval starting mid-line). PAL: 3665/3666 samples (exactly
// 64 us on average), 312 or 312.5 lines.
//
// Composite sync (csync) is generated here to the standard: NTSC 6
// equalizing + 6 serrated broad + 6 equalizing pulses at half-line
// spacing, PAL 5 + 5 + 5, with the burst blanked through the vertical
// interval. The top level drives it on VGA_HS; the framework's csync
// combiner is set to pass it through (framework mod #3).

module ntsc_timing (
	input         clk,          // 57.272727 MHz
	input         reset,
	input         pal,          // 0 = NTSC (3640/line, 262.5), 1 = PAL (3664/line, 312.5)
	input         interlace_en,
	input  [1:0]  v_shift,      // move vsync earlier: picture shifts DOWN on CRT
	                            // 0/1/2 = default / 2 lines / 4 lines

	// Error injection inputs
	input  signed [12:0] line_length_mod, // modification to line length per line
	input  signed [12:0] h_offset,        // horizontal displacement of this line's start
	input  [8:0]  roll_shift,             // vsync phase rotation in lines (picture roll)
	input         pulse_cross,            // relocate sync ~half line/field: blanking shows mid-screen
	input         pc_enhanced,            // add relocated burst + ghost sync marks (viewing aids)

	// Timing outputs
	output reg [11:0] h_count,       // 0 to 3639 (or modified)
	output reg [8:0]  v_count,       // 0 to 261 (or modified)
	output reg        field,         // 0 = odd, 1 = even (for interlace)
	output reg        hsync,         // active during H-sync pulse
	output reg        vsync,         // active during V-sync interval
	output reg        hblank,        // active during horizontal blanking
	output reg        vblank,        // active during vertical blanking
	output reg        burst_window,  // active during colorburst time
	output reg        active_video,  // active during visible picture area
	output reg        new_line,      // single-cycle pulse at start of each line
	output reg        new_field,     // single-cycle pulse at start of each field
	output reg        pc_blank,      // pulse cross: blank content around the relocated sync
	output reg        disp_sync,     // pulse cross: ghost of the signal's true sync positions
	output reg        csync          // standard composite sync (to VGA_HS)
);

// NTSC timing constants at 57.272727 MHz (3640 samples per line)
// Line structure: sync | back porch | burst | back porch | active video | front porch
// Standards-dependent constants. Active video stays 668-3567 in both
// standards (identical pattern/pixel geometry); PAL's extra samples all
// land in the front porch (96 samples = 1.68 us, per spec).
// NTSC burst placement matches what the MiSTer ARM programs into yc_out
// (start 3.7 subcarrier cycles after hsync end, 9 cycles) — proven with
// this adapter/CRT chain. PAL: burst 5.6 us from sync start, 10 cycles.
// PAL line: 64 us = 3665.4545 clocks. Lines are 3665 or 3666 clocks,
// 5 long ones in every 11 (spread evenly), so the line rate averages
// exactly 15625 Hz and no line deviates from ideal by more than half a
// clock (~9 ns). (A fixed 3664 ran at 15631 Hz.)
reg  [3:0]  pal_acc;
reg         pal_long;
wire [11:0] H_TOTAL_NOM  = pal ? (pal_long ? 12'd3666 : 12'd3665) : 12'd3640;
wire [11:0] H_SYNC_END   = pal ? 12'd269  : 12'd267;   // 4.7 us
// Vertical-interval pulses: equalizing 2.3 us (NTSC) / 2.35 us (PAL);
// broad pulses fill each half line except a 4.7 us serration
wire [11:0] EQ_W         = pal ? 12'd135  : 12'd132;
wire [11:0] SERR_W       = H_SYNC_END + 12'd1;
wire [11:0] H_BP_PRE_END = pal ? 12'd319  : 12'd326;
wire [11:0] H_BURST_END  = pal ? 12'd449  : 12'd470;
localparam H_BP_POST_END = 12'd667;    // Post-burst back porch: 560-667
localparam H_ACTIVE_END  = 12'd3567;   // Active video: 668-3567 (2900 samples)
// (nominal line length comes from H_TOTAL_NOM above; front porch is the remainder)

localparam V_ACTIVE_LINES = 9'd240;    // Visible lines per field
localparam V_BLANK_START  = 9'd240;    // Start of vertical blanking
localparam V_TOTAL_PROG   = 9'd262;    // Total lines per field (progressive)

// Vertical sync pulse: 3 lines placed INSIDE the vertical blanking
// interval, after a 5-line post-active gap (lines 240-244, standing in
// for the pre-equalization interval). Placing vsync inside vblank is
// required: if vsync overlaps active video, bright patterns corrupt
// the sync interval and AC-coupled sync separators lose vertical lock.
// PAL fields are 312/313 lines with 72 lines of blanking; placing vsync
// at 276 roughly centers the 240 active lines on a PAL display.
wire [8:0] V_SYNC_START = pal ? 9'd276 : 9'd245;
wire [8:0] V_SYNC_END   = pal ? 9'd278 : 9'd247;

// Calculate effective line length and field height with error injection
// Must use signed arithmetic to handle negative modifications correctly
//
// h_offset shifts where a line STARTS relative to nominal timing. A line
// whose start moves later by N samples is realized by stretching the
// previous line N samples, so we differentiate: this line's length gets
// (h_offset - h_offset_prev). The offset pattern lands one line late,
// which is invisible for tear/skew content.
reg signed [12:0] h_offset_prev;
always @(posedge clk) begin
	if (reset)
		h_offset_prev <= 13'sd0;
	else if (new_line)
		h_offset_prev <= h_offset;
end

always @(posedge clk) begin
	if (reset) begin
		pal_acc  <= 4'd0;
		pal_long <= 1'b0;
	end else if (new_line) begin
		// Bresenham over 11 lines: long when the accumulator wraps
		if (pal_acc + 4'd5 >= 4'd11) begin
			pal_acc  <= pal_acc + 4'd5 - 4'd11;
			pal_long <= 1'b1;
		end else begin
			pal_acc  <= pal_acc + 4'd5;
			pal_long <= 1'b0;
		end
	end
end

wire signed [14:0] h_total_calc = $signed({3'b0, H_TOTAL_NOM}) + line_length_mod
                                + (h_offset - h_offset_prev);
// Clamp to h_count's 12-bit range: worst-case severe tear deltas would
// otherwise wrap and produce garbage line lengths instead of early/late sync
wire [11:0] h_total_eff = (h_total_calc < 15'sd2048) ? 12'd2048 :
                          (h_total_calc > 15'sd4095) ? 12'd4095 :
                          h_total_calc[11:0];

// Interlace: fields of 263 and 262 whole lines (313/312 PAL) carry the
// picture; the 263-line field's vertical interval starts half a line
// late (see csync below), so vsync-to-vsync is 262.5 lines both ways
// and the two fields' scan lines interleave.
// Field 0 (odd) = 263 lines, Field 1 (even) = 262 lines.
wire [8:0] v_total_base = pal ? ((interlace_en && !field) ? 9'd313 : 9'd312)
                              : ((interlace_en && !field) ? 9'd263 : 9'd262);
wire [8:0] v_total_eff  = v_total_base;

// Pulse cross: relocating the sync pulses ~half a line and ~half a
// field away from the (unchanged) picture content makes any monitor
// display the normally-invisible blanking intervals as a centered
// cross - sync pulses, burst, VBI lines (captions), the head-switch
// region. The monitor-side "pulse cross" button does the same thing by
// delaying its deflection; we do it at the source instead.
//
// The relocated pulses need a local blanking pedestal: a sync tip
// riding on active video sits far above the separator's slice level
// and the monitor loses H lock (verified - the picture weaves). The
// pedestal stripes land in the monitor's own retrace, so they cost
// almost nothing visible.
wire [11:0] pc_hc   = pal ? 12'd1832 : 12'd1820;
wire [11:0] hs_off  = pulse_cross ? pc_hc : 12'd0;
wire [8:0]  pc_voff = pulse_cross ? (pal ? 9'd156 : 9'd131) : 9'd0;
// pedestal spans front porch + sync + back porch + a relocated BURST:
// the monitor's burst gate keys off (relocated) hsync, so without a
// burst there the color killer trips and everything shows B&W
wire pc_hzone = (h_count >= pc_hc - 12'd92) && (h_count < pc_hc + 12'd560);
wire pc_burst = pc_enhanced && (h_count >= pc_hc + H_BP_PRE_END + 12'd1) &&
                               (h_count <= pc_hc + H_BURST_END);

// Picture roll: rotate the vsync position through the field (modulo the
// field height). The field rate never changes - the monitor stays
// locked - but the picture-to-vsync phase slides, so the image rolls.
wire [8:0] vs_base = V_SYNC_START - {6'd0, v_shift, 1'b0};
wire signed [10:0] vs_rot   = $signed({2'b0, vs_base}) - $signed({2'b0, roll_shift})
                                                       - $signed({2'b0, pc_voff});
wire signed [10:0] vs_start = (vs_rot < 0) ? vs_rot + $signed({2'b0, v_total_base}) : vs_rot;
wire signed [10:0] vs_delta = $signed({2'b0, v_count}) - vs_start;
wire signed [10:0] vs_dmod  = (vs_delta < 0) ? vs_delta + $signed({2'b0, v_total_base}) : vs_delta;

// Ghost sync for the pulse-cross display: where the signal's sync
// really lives (tracks roll, NOT the pulse-cross relocation) - painted
// into luma by the top level so the pulses are visible in the cross
wire signed [10:0] g_rot = $signed({2'b0, vs_base}) - $signed({2'b0, roll_shift});
wire signed [10:0] g_fix = (g_rot < 0) ? g_rot + $signed({2'b0, v_total_base}) : g_rot;
wire signed [10:0] g_del = $signed({2'b0, v_count}) - g_fix;
wire signed [10:0] g_mod = (g_del < 0) ? g_del + $signed({2'b0, v_total_base}) : g_del;

// ---- Composite sync: half-line slots through the vertical interval ----
// Position within the (possibly pulse-cross relocated) sync line. Uses
// the line length registered one clock late: the combinational length
// (error offsets -> sum -> clamp) feeding this half-line math missed
// timing, and it only changes at line starts, where every pulse type
// starts high anyway.
reg  [11:0] h_total_q;
always @(posedge clk) h_total_q <= h_total_eff;
wire [11:0] half    = h_total_q >> 1;
wire [11:0] hp      = (h_count >= hs_off) ? (h_count - hs_off) : (h_count + h_total_q - hs_off);
wire        hb      = hp >= half;                       // second half of the line
wire [11:0] hq      = hb ? (hp - half) : hp;            // position within the half line
wire [11:0] hlen    = hb ? (h_total_q - half) : half;   // this half line's length
// The vertical slot base for each line is computed DURING the previous
// line, in a short pipeline (its inputs - v_count, field, roll and pulse
// cross offsets - are constant for the whole line; done in one cycle the
// chain from roll_shift to csync missed timing), and latched on the same
// edge that wraps h_count, so it is already valid on the line's first
// sample. (v_count/field themselves only update one clock after the
// wrap; using them there glitched a pulse-cross half-line edge.)
wire        nx_wrap = (v_count >= v_total_eff - 9'd1);
wire [8:0]  v_nx    = nx_wrap ? 9'd0 : v_count + 9'd1;
wire        f_nx    = nx_wrap ? (interlace_en ? ~field : 1'b0) : field;
wire [8:0]  vt_nx   = pal ? ((interlace_en && !f_nx) ? 9'd313 : 9'd312)
                          : ((interlace_en && !f_nx) ? 9'd263 : 9'd262);
reg  signed [10:0] p1_rot, p1_v, p1_vt, p2_start, p2_v, p2_vt, p3_dmod, p3_vt, p4_r;
reg         p1_f, p2_f, p3_f, p4_f;
always @(posedge clk) begin
	// stage 1: the next line's inputs
	p1_rot <= vs_rot;
	p1_v   <= $signed({2'b0, v_nx});
	p1_vt  <= $signed({2'b0, vt_nx});
	p1_f   <= f_nx;
	// stage 2: vsync start line in that field
	p2_start <= (p1_rot < 0) ? p1_rot + p1_vt : p1_rot;
	p2_v     <= p1_v;  p2_vt <= p1_vt;  p2_f <= p1_f;
	// stage 3: lines since the vsync line (mod field height)
	p3_dmod <= ((p2_v - p2_start) < 0) ? (p2_v - p2_start + p2_vt) : (p2_v - p2_start);
	p3_vt   <= p2_vt;  p3_f <= p2_f;
	// stage 4: lines since the start of the pre-equalization interval
	// (3 lines before the vsync line)
	p4_r <= (p3_dmod >= p3_vt - 11'sd3) ? (p3_dmod + 11'sd3 - p3_vt) : (p3_dmod + 11'sd3);
	p4_f <= p3_f;
end
reg  signed [10:0] r_cur;
reg         f_cur;
always @(posedge clk) begin
	if (reset) begin
		r_cur <= 11'sd100;   // outside the interval until the pipeline fills
		f_cur <= 1'b0;
	end else if (h_count >= h_total_eff - 12'd1) begin
		r_cur <= p4_r;
		f_cur <= p4_f;
	end
end
// counted on relocated sync lines (pulse cross: the part of the counter
// line before the relocated sync belongs to the previous sync line)
wire signed [10:0] r_ln  = r_cur - ((h_count < hs_off) ? 11'sd1 : 11'sd0);
// Half-line slot: NTSC 18 slots from line start; PAL 15, starting half a
// line later so its broad pulses still begin on the vsync line. The
// 263/313-line field is delayed another half line (the interlace offset).
wire        fo      = interlace_en && !f_cur;
wire signed [10:0] slot = (r_ln <<< 1) + (hb ? 11'sd1 : 11'sd0) - (fo ? 11'sd1 : 11'sd0)
                          - (pal ? 11'sd1 : 11'sd0);
wire signed [10:0] NE   = pal ? 11'sd5 : 11'sd6;        // pulses per group
wire        in_vi   = (slot >= 11'sd0) && (slot < NE * 11'sd3);
wire        broad   = (slot >= NE) && (slot < NE * 11'sd2);
wire        cs_vi   = broad ? (hq < hlen - SERR_W) : (hq < EQ_W);
wire        cs_line = (hp <= H_SYNC_END);

// Horizontal counter
always @(posedge clk) begin
	if (reset) begin
		h_count   <= 12'd0;
		new_line  <= 1'b0;
	end else begin
		new_line <= 1'b0;
		if (h_count >= h_total_eff - 12'd1) begin
			h_count  <= 12'd0;
			new_line <= 1'b1;
		end else begin
			h_count <= h_count + 12'd1;
		end
	end
end

// Vertical counter
always @(posedge clk) begin
	if (reset) begin
		v_count   <= 9'd0;
		field     <= 1'b0;
		new_field <= 1'b0;
	end else if (new_line) begin
		new_field <= 1'b0;
		if (v_count >= v_total_eff - 9'd1) begin
			v_count   <= 9'd0;
			new_field <= 1'b1;
			// progressive has a single field type: report it as field 0.
			// (Holding the last parity instead left the flag frozen at
			// 1 half the time after the OSD - which forces progressive -
			// closed with Interlace Off, and the error run start, which
			// waits for a field-0 frame start, then never came.)
			field <= interlace_en ? ~field : 1'b0;
		end else begin
			v_count <= v_count + 9'd1;
		end
	end else begin
		new_field <= 1'b0;
	end
end

// Generate timing signals from counters
always @(posedge clk) begin
	if (reset) begin
		hsync        <= 1'b0;
		csync        <= 1'b0;
		vsync        <= 1'b0;
		hblank       <= 1'b1;
		vblank       <= 1'b1;
		burst_window <= 1'b0;
		active_video <= 1'b0;
	end else begin
		hsync        <= (h_count >= hs_off) && (h_count <= hs_off + {3'd0, H_SYNC_END});
		csync        <= in_vi ? cs_vi : cs_line;
		// no burst through the vertical interval (equalizing/broad pulses)
		burst_window <= (((h_count >= H_BP_PRE_END + 12'd1) && (h_count <= H_BURST_END)) && !in_vi) || pc_burst;
		hblank       <= (h_count <= H_BP_POST_END) || (h_count > H_ACTIVE_END);
		active_video <= (h_count > H_BP_POST_END) && (h_count <= H_ACTIVE_END) &&
		                (v_count < V_ACTIVE_LINES);

		// V Position: an earlier vsync lengthens the vsync-to-active gap,
		// pushing the picture down on a CRT (helps content clear the top
		// overscan). Range is bounded by the vblank front porch: vsync
		// must stay inside vblank (see the placement note above).
		// Picture roll rotates the same window through the field.
		vsync  <= (vs_dmod <= 10'sd2);
		vblank <= (v_count >= V_BLANK_START);

		// Blanking pedestal around the relocated sync (3 lines before
		// the vsync window through 3 after; porch-shaped stripe around
		// the relocated hsync)
		pc_blank <= pulse_cross &&
		            (pc_hzone ||
		             (vs_dmod <= 10'sd6) ||
		             (vs_dmod >= $signed({2'b0, v_total_base}) - 10'sd3));

		// Ghost sync marks: the true hsync column and the 3-line vsync
		// block, shown at unlifted black in the lifted display
		disp_sync <= pc_enhanced &&
		             ((h_count <= {3'd0, H_SYNC_END}) || (g_mod <= 10'sd2));
	end
end

endmodule

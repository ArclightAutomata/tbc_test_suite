// SPDX-License-Identifier: GPL-2.0-or-later
// Analog output stage: the RF-domain defects (dropouts, head condition,
// dropout compensation) and the pulse-cross viewing aids, ahead of the
// MikeS11 Y (VGA_G) and C (VGA_R) pins.
//
// These defects live in the DEMODULATED signal, not picture content,
// so they act on the encoded Y/C. Everything is computed on the luma
// alone and the chroma alone, then recombined: in Composite the encoder
// puts y = luma/2 + chroma/2 on the Y pin (chroma centered at 128, so
// black is 64 and white ~191), and `lum` (the encoder's luma before the
// sum) lets this stage split the two exactly - out_y - lum/2 is the
// chroma half. With no defect active the output is bit-identical to
// the encoder's.
//
//   head condition (rtl/error_head.sv): snow and specks are added to the
//     luma; Very Dirty softens it (4-sample average) and mutes chroma;
//     a clogged head replaces the luma with snow and mutes chroma (the
//     top level also removes its sync)
//   dropouts (rtl/error_dropout.sv): blend luma toward the dropout level
//     (sparkle body, black tail) by mix/16 and chroma toward neutral
//   Dropout Comp: the deck's dropout compensator - a fixed 1H delay line
//     (like the glass delay line in a real deck: 63.56 us NTSC, 64 us
//     PAL, not locked to the incoming sync, so timebase errors misalign
//     the patch). During a dropout the luma comes from the line above
//     instead of the sparkle, and the delay line recirculates, so a long
//     dropout keeps repeating the last good line. Chroma still drops
//     out (the compensator works on luma only, like VHS).
//
// Pulse-cross viewing aids:
//  - all defects are masked inside the relocated-sync pedestal (the
//    viewing scaffold must keep the monitor locked; everywhere else,
//    including the displayed blanking cross, they stay authentic)
//  - the luma is lifted ~25 IRE so blanking reads as gray instead of
//    clamping to black (the washed-out pro pulse-cross look), with the
//    signal's true sync positions painted at unlifted black so the
//    pulses are visible and error deformation can be watched
//  - in Composite both use the Composite scale: black is 64 there, so
//    the marks are painted AT 64 and the lift is +32 (half scale). At
//    Y=0 the marks were blacker than black and the TV's sync separator
//    read them as sync - the picture rolled (seen on the CRT).
module out_stage (
	input        clk,
	input  [7:0] out_y,      // encoded luma (or composite) from the encoder
	input  [7:0] out_c,      // encoded chroma
	input  [7:0] lum,        // encoded luma alone (= out_y in S-Video)
	input        cvbs,       // Output = Composite (custom encoder)
	input        pal,        // delay-line length
	input        drop_act,
	input  [4:0] drop_mix,   // 0-16 sixteenths toward drop_luma
	input  [7:0] drop_luma,  // dropout level (S-Video luma scale)
	input        doc_en,     // Dropout Comp
	input  signed [8:0] hd_noise,
	input        hd_snow,
	input  [7:0] hd_snow_luma,
	input        hd_cmute,
	input        hd_soft,
	input        pc_enh,
	input        pc_blank,
	input        disp_sync,
	output [7:0] y,
	output [7:0] c
);

wire       mask = pc_enh && pc_blank;
wire       drop_vis = drop_act && !mask;

// ---- split into luma and chroma ----
wire [7:0] ch_in   = cvbs ? (out_y - {1'b0, lum[7:1]}) : out_c;   // cvbs: 0-127 around 64
wire [7:0] neutral = cvbs ? 8'd64 : 8'd128;

// ---- head condition ----
reg [7:0] l1, l2, l3;
always @(posedge clk) begin l1 <= lum; l2 <= l1; l3 <= l2; end
wire [9:0] l_avg = ({2'b0, lum} + {2'b0, l1} + {2'b0, l2} + {2'b0, l3} + 10'd2) >> 2;
wire [7:0] l_soft = (hd_soft && !mask) ? l_avg[7:0] : lum;
wire signed [10:0] l_noisy = $signed({3'b0, l_soft}) + (mask ? 11'sd0 : {{2{hd_noise[8]}}, hd_noise});
wire [7:0] l_head = (hd_snow && !mask) ? hd_snow_luma :
                    (l_noisy < 0)      ? 8'd0 :
                    (l_noisy > 255)    ? 8'd255 : l_noisy[7:0];
wire [7:0] ch_head = ((hd_cmute || hd_snow) && !mask) ? neutral : ch_in;

// ---- dropout compensator delay line: 4096 x 8, fixed 1H ----
wire [7:0] l_out;
reg  [11:0] wptr = 12'd0;
reg  [7:0]  dline [0:4095];
reg  [7:0]  delayed;
// read one ahead so the registered output lands on the sample 1H back
wire [11:0] rptr = wptr - (pal ? 12'd3665 : 12'd3640) + 12'd1;
always @(posedge clk) begin
	wptr <= wptr + 12'd1;
	dline[wptr] <= l_out;
	delayed <= dline[rptr];
end

// ---- dropouts ----
wire [7:0] target = doc_en ? delayed : drop_luma;
wire signed [9:0] d_l  = $signed({2'b0, target})  - $signed({2'b0, l_head});
wire signed [9:0] d_c  = $signed({2'b0, neutral}) - $signed({2'b0, ch_head});
wire signed [14:0] p_l = d_l * $signed({1'b0, drop_mix});
wire signed [14:0] p_c = d_c * $signed({1'b0, drop_mix});
// mix 16 lands exactly on the target (no rounding left over)
assign l_out = drop_vis ? 8'($signed({2'b0, l_head}) + (p_l >>> 4)) : l_head;
wire [7:0] ch_out = drop_vis ? 8'($signed({2'b0, ch_head}) + (p_c >>> 4)) : ch_head;

// ---- recombine ----
wire [7:0] y_pre  = cvbs ? ({1'b0, l_out[7:1]} + ch_out) : l_out;
wire [8:0] y_lift = {1'b0, y_pre} + (cvbs ? 9'd32 : 9'd64);

assign y = !pc_enh    ? y_pre :
           disp_sync  ? (cvbs ? 8'd64 : 8'd0) :
           y_lift[8]  ? 8'd255 : y_lift[7:0];
assign c = cvbs ? 8'd128 : ch_out;

endmodule

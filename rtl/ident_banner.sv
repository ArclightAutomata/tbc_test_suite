// SPDX-License-Identifier: GPL-2.0-or-later
// Channel ident banner: a lower-third "SUBSCRIBE / ARCLIGHT AUTOMATA"
// overlay with a YouTube-style play button, stamped into the test video
// itself (not the OSD) so it survives the DUT chain and appears in
// captured footage. Menu-toggleable; the top level suppresses it on the
// Analysis and waveform-monitor patterns so it cannot disturb
// measurements.
//
// Glyphs are a 14-letter 8x8 font. Text is drawn at 4x horizontal /
// 2x vertical scale, which lands near-square on a 4:3 display given the
// core's tall 724x240-per-field pixels.

module ident_banner (
	input clk,
	input reset,
	input enable,
	input  [9:0] px,   // active pixel 0..723
	input  [8:0] py,   // active line 0..239
	input        active,
	output reg       act,
	output reg [7:0] r,
	output reg [7:0] g,
	output reg [7:0] b
);

// Glyph codes
localparam SP=4'd0, A=4'd1, B=4'd2, C=4'd3, E=4'd4, G=4'd5, H=4'd6, I=4'd7,
           L=4'd8, M=4'd9, O=4'd10, R=4'd11, S=4'd12, T=4'd13, U=4'd14;

function [7:0] glyph_row(input [3:0] ch, input [2:0] row);
	case (ch)
		A: case (row) 0:glyph_row=8'h38; 1:glyph_row=8'h44; 2:glyph_row=8'h44; 3:glyph_row=8'h7C; 4:glyph_row=8'h44; 5:glyph_row=8'h44; 6:glyph_row=8'h44; default:glyph_row=8'h00; endcase
		B: case (row) 0:glyph_row=8'h78; 1:glyph_row=8'h44; 2:glyph_row=8'h44; 3:glyph_row=8'h78; 4:glyph_row=8'h44; 5:glyph_row=8'h44; 6:glyph_row=8'h78; default:glyph_row=8'h00; endcase
		C: case (row) 0:glyph_row=8'h38; 1:glyph_row=8'h44; 2:glyph_row=8'h40; 3:glyph_row=8'h40; 4:glyph_row=8'h40; 5:glyph_row=8'h44; 6:glyph_row=8'h38; default:glyph_row=8'h00; endcase
		E: case (row) 0:glyph_row=8'h7C; 1:glyph_row=8'h40; 2:glyph_row=8'h40; 3:glyph_row=8'h78; 4:glyph_row=8'h40; 5:glyph_row=8'h40; 6:glyph_row=8'h7C; default:glyph_row=8'h00; endcase
		G: case (row) 0:glyph_row=8'h38; 1:glyph_row=8'h44; 2:glyph_row=8'h40; 3:glyph_row=8'h5C; 4:glyph_row=8'h44; 5:glyph_row=8'h44; 6:glyph_row=8'h3C; default:glyph_row=8'h00; endcase
		H: case (row) 0:glyph_row=8'h44; 1:glyph_row=8'h44; 2:glyph_row=8'h44; 3:glyph_row=8'h7C; 4:glyph_row=8'h44; 5:glyph_row=8'h44; 6:glyph_row=8'h44; default:glyph_row=8'h00; endcase
		I: case (row) 0:glyph_row=8'h38; 1:glyph_row=8'h10; 2:glyph_row=8'h10; 3:glyph_row=8'h10; 4:glyph_row=8'h10; 5:glyph_row=8'h10; 6:glyph_row=8'h38; default:glyph_row=8'h00; endcase
		L: case (row) 0:glyph_row=8'h40; 1:glyph_row=8'h40; 2:glyph_row=8'h40; 3:glyph_row=8'h40; 4:glyph_row=8'h40; 5:glyph_row=8'h40; 6:glyph_row=8'h7C; default:glyph_row=8'h00; endcase
		M: case (row) 0:glyph_row=8'h44; 1:glyph_row=8'h6C; 2:glyph_row=8'h54; 3:glyph_row=8'h54; 4:glyph_row=8'h44; 5:glyph_row=8'h44; 6:glyph_row=8'h44; default:glyph_row=8'h00; endcase
		O: case (row) 0:glyph_row=8'h38; 1:glyph_row=8'h44; 2:glyph_row=8'h44; 3:glyph_row=8'h44; 4:glyph_row=8'h44; 5:glyph_row=8'h44; 6:glyph_row=8'h38; default:glyph_row=8'h00; endcase
		R: case (row) 0:glyph_row=8'h78; 1:glyph_row=8'h44; 2:glyph_row=8'h44; 3:glyph_row=8'h78; 4:glyph_row=8'h50; 5:glyph_row=8'h48; 6:glyph_row=8'h44; default:glyph_row=8'h00; endcase
		S: case (row) 0:glyph_row=8'h3C; 1:glyph_row=8'h40; 2:glyph_row=8'h40; 3:glyph_row=8'h38; 4:glyph_row=8'h04; 5:glyph_row=8'h04; 6:glyph_row=8'h78; default:glyph_row=8'h00; endcase
		T: case (row) 0:glyph_row=8'h7C; 1:glyph_row=8'h10; 2:glyph_row=8'h10; 3:glyph_row=8'h10; 4:glyph_row=8'h10; 5:glyph_row=8'h10; 6:glyph_row=8'h10; default:glyph_row=8'h00; endcase
		U: case (row) 0:glyph_row=8'h44; 1:glyph_row=8'h44; 2:glyph_row=8'h44; 3:glyph_row=8'h44; 4:glyph_row=8'h44; 5:glyph_row=8'h44; 6:glyph_row=8'h38; default:glyph_row=8'h00; endcase
		default: glyph_row = 8'h00;
	endcase
endfunction

// "SUBSCRIBE"
function [3:0] line1_code(input [3:0] idx);
	case (idx)
		0:line1_code=S; 1:line1_code=U; 2:line1_code=B; 3:line1_code=S; 4:line1_code=C;
		5:line1_code=R; 6:line1_code=I; 7:line1_code=B; 8:line1_code=E;
		default:line1_code=SP;
	endcase
endfunction

// "ARCLIGHT AUTOMATA"
function [3:0] line2_code(input [4:0] idx);
	case (idx)
		0:line2_code=A; 1:line2_code=R; 2:line2_code=C; 3:line2_code=L; 4:line2_code=I;
		5:line2_code=G; 6:line2_code=H; 7:line2_code=T; 8:line2_code=SP;
		9:line2_code=A; 10:line2_code=U; 11:line2_code=T; 12:line2_code=O; 13:line2_code=M;
		14:line2_code=A; 15:line2_code=T; 16:line2_code=A;
		default:line2_code=SP;
	endcase
endfunction

// Geometry (all inside the CRT safe area)
localparam BAND_Y0 = 9'd172, BAND_Y1 = 9'd219;
localparam BAND_X0 = 10'd60, BAND_X1 = 10'd663;
localparam BTN_X0  = 10'd199, BTN_X1 = 10'd228;   // red play button
localparam BTN_Y0  = 9'd175,  BTN_Y1 = 9'd192;
localparam TRI_X0  = 10'd208;                     // white triangle
localparam TRI_Y0  = 9'd179;                      // 10 rows
localparam L1_X0   = 10'd237, L1_Y0 = 9'd176;     // 9 chars x 32 px
localparam L2_X0   = 10'd90,  L2_Y0 = 9'd198;     // 17 chars x 32 px

wire band = (py >= BAND_Y0) && (py <= BAND_Y1) && (px >= BAND_X0) && (px <= BAND_X1);
wire btn  = (px >= BTN_X0) && (px <= BTN_X1) && (py >= BTN_Y0) && (py <= BTN_Y1);

// Right-pointing triangle: every row starts at TRI_X0, run length peaks
// mid-height (2,4,6,8,10,10,8,6,4,2)
wire [8:0] tri_dy = py - TRI_Y0;
wire [3:0] tri_t = tri_dy[3:0];
wire [4:0] tri_2t9 = {tri_t, 1'b0} > 5'd9 ? ({tri_t, 1'b0} - 5'd9) : (5'd9 - {tri_t, 1'b0});
wire [4:0] tri_w = 5'd11 - tri_2t9;
wire tri_pix = (py >= TRI_Y0) && (py < TRI_Y0 + 9'd10) &&
               (px >= TRI_X0) && (px < TRI_X0 + {5'd0, tri_w});

// Text pixel lookup: 32 px/char (4x), 16 rows/char (2x)
wire [9:0] l1_dx = px - L1_X0;
wire [8:0] l1_dy = py - L1_Y0;
wire l1_zone = (py >= L1_Y0) && (py < L1_Y0 + 9'd16) && (px >= L1_X0) && (px < L1_X0 + 10'd288);
wire [7:0] l1_bits = glyph_row(line1_code(l1_dx[8:5]), l1_dy[3:1]);
wire l1_pix = l1_zone && l1_bits[3'd7 - l1_dx[4:2]];

wire [9:0] l2_dx = px - L2_X0;
wire [8:0] l2_dy = py - L2_Y0;
wire l2_zone = (py >= L2_Y0) && (py < L2_Y0 + 9'd16) && (px >= L2_X0) && (px < L2_X0 + 10'd544);
wire [7:0] l2_bits = glyph_row(line2_code(l2_dx[9:5]), l2_dy[3:1]);
wire l2_pix = l2_zone && l2_bits[3'd7 - l2_dx[4:2]];

always @(posedge clk) begin
	if (reset || !enable || !active || !band) begin
		act <= 1'b0;
		r <= 8'd0; g <= 8'd0; b <= 8'd0;
	end else begin
		act <= 1'b1;
		if (tri_pix || l1_pix || l2_pix) begin
			r <= 8'd255; g <= 8'd255; b <= 8'd255;   // white text/triangle
		end else if (btn) begin
			r <= 8'd191; g <= 8'd0; b <= 8'd0;       // 75%-level red button
		end else begin
			r <= 8'd0; g <= 8'd0; b <= 8'd0;         // black band
		end
	end
end

endmodule

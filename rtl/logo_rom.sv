// SPDX-License-Identifier: GPL-2.0-or-later
// Logo pattern: the project logo (assets/logo.svg) as a 16-color
// paletted ROM, 636x188 field pixels filling the CRT-safe area; the
// surround is painted with the art's own background color so the frame
// reads as full-bleed. Regenerate rtl/logo_rom.mem + rtl/logo_palette.svh
// with tools/make_logo_rom.py (see its header for the Chrome render step).
//
// Addressing uses a 640-px row stride (wy*640 = two shift-adds); the 4
// waste pixels per row are stored as palette entry 0.

module logo_rom (
	input clk,
	input  [9:0] px,   // active pixel 0..723
	input  [8:0] py,   // active line 0..239
	output reg [7:0] r,
	output reg [7:0] g,
	output reg [7:0] b
);

localparam [9:0] X0 = 10'd44;
localparam [8:0] Y0 = 9'd26;
localparam [23:0] BG = 24'h2A2A2A;

wire in_win = (px >= X0) && (px < X0 + 10'd636) &&
              (py >= Y0) && (py < Y0 + 9'd188);
wire [9:0] wx = px - X0;
wire [8:0] wy = py - Y0;
wire [17:0] addr = {wy, 9'd0} + {2'd0, wy, 7'd0} + {8'd0, wx}; // wy*640 + wx

reg [3:0] mem [0:120319];
initial $readmemh("rtl/logo_rom.mem", mem);

// Two-stage read: ROM index, then palette. The extra clock versus the
// other patterns shifts the logo right by one sample (1/4 pixel).
reg [3:0] idx;
reg       win_q;
always @(posedge clk) begin
	idx   <= mem[addr[16:0]];
	win_q <= in_win;

	if (!win_q) begin
		{r, g, b} <= BG;
	end else begin
		case (idx)
`include "logo_palette.svh"
			default: {r, g, b} <= BG;
		endcase
	end
end

endmodule

// SPDX-License-Identifier: GPL-2.0-or-later
// Clean-HDMI framebuffer writer.
//
// Renders the clean RGB test pattern into a DDRAM framebuffer that the
// HDMI scaler displays instead of the live video, while the analog path
// carries the custom-encoded (and deliberately mangled) Y/C. Pixels are
// indexed by pattern position (pixel column, line), not by time, so the
// HDMI image is immune to injected timing errors by construction: a torn
// or wowing line still deposits its pixels at their nominal coordinates.
//
// Format: RGB565 little-endian, 724 x 240 (725th pixel dropped so the
// width packs evenly into 64-bit words), stride 2048 bytes,
// base 0x3F800000 (top-of-DDR region conventionally used by cores).
// One 64-bit word carries 4 pixels; one single-beat write per word.

module fb_writer (
	input         clk,           // 57.272727 MHz
	input         reset,

	input  [7:0]  r, g, b,       // clean pattern RGB
	input  [11:0] h_pos,         // 0-2899 sample position within active video
	input  [8:0]  v_pos,         // line 0-239
	input         active,        // active_video

	output reg         ddram_write,
	output reg  [28:0] ddram_addr,
	output reg  [63:0] ddram_din,
	output      [7:0]  ddram_be,
	output      [7:0]  ddram_burstcnt,
	input              ddram_busy
);

assign ddram_be       = 8'hFF;
assign ddram_burstcnt = 8'd1;

// 0x3F800000 byte address >> 3 = 0x07F00000 in 64-bit words
localparam [28:0] FB_BASE_W = 29'h07F0_0000;
localparam [28:0] STRIDE_W  = 29'd256;          // 2048 bytes / 8

wire [15:0] pix565 = {r[7:3], g[7:2], b[7:3]};
wire [9:0]  px     = h_pos[11:2];               // pixel column 0-724

reg [47:0] pack;                                 // pixel slots 0-2 of the word
reg [28:0] waddr;

always @(posedge clk) begin
	if (reset) begin
		ddram_write <= 1'b0;
	end else begin
		// Avalon write handshake: hold write until accepted
		if (ddram_write && !ddram_busy)
			ddram_write <= 1'b0;

		// one capture per pixel (4 samples each); px[1:0] = slot in word
		if (active && h_pos[1:0] == 2'd0 && px < 10'd724) begin
			case (px[1:0])
				2'd0: pack[15:0]  <= pix565;
				2'd1: pack[31:16] <= pix565;
				2'd2: begin
					pack[47:32] <= pix565;
					// precompute the word address while pixel 3 arrives
					waddr <= FB_BASE_W + v_pos * STRIDE_W + {21'd0, px[9:2]};
				end
				2'd3: begin
					ddram_din   <= {pix565, pack};
					ddram_addr  <= waddr;
					ddram_write <= 1'b1;
				end
			endcase
		end
	end
end

endmodule

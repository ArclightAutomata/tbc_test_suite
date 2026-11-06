// SPDX-License-Identifier: GPL-2.0-or-later
// Video file loader: hps_io ioctl download -> DDRAM.
//
// Receives the OSD-selected raw video file (RGB565LE, 724x480 frames)
// as a 16-bit ioctl stream, packs 4 words into 64-bit beats, and writes
// them to the video region at 0x30000000. Keeps its own 32-bit counter
// (ioctl_addr is only 27 bits, the ARM streams to EOF regardless), so
// clips up to the full 248 MB region (~12 s at 29.97 fps) are usable.
// Counts whole frames during the download; playback loops over them.

module video_loader (
	input             clk,
	input             reset,

	input             ioctl_download,
	input             ioctl_wr,
	input      [15:0] ioctl_dout,

	// arbiter write port
	output reg        ldw_req,
	output reg [28:0] ldw_addr,
	output reg [63:0] ldw_din,
	input             ldw_ack,

	output reg        loading,      // download in progress (drop a pending word)
	output reg [8:0]  frame_count   // whole frames available (0 = none)
);

// 0x30000000 byte address >> 3
localparam [28:0] VIDEO_BASE_W   = 29'h0600_0000;
localparam [28:0] VIDEO_LIMIT_W  = 29'h07F0_0000; // start of HDMI framebuffer
localparam [24:0] FRAME_WORDS    = 25'd86880;     // 724*480*2/8

reg [31:0] word_cnt;    // 16-bit words received
reg [47:0] shift;
reg [28:0] waddr;
reg [24:0] frame_word;

wire [28:0] next_waddr = VIDEO_BASE_W + word_cnt[31:2];

always @(posedge clk) begin
	if (reset) begin
		ldw_req     <= 1'b0;
		loading     <= 1'b0;
		frame_count <= 9'd0;
		word_cnt    <= 32'd0;
	end else begin
		if (ldw_ack) ldw_req <= 1'b0;

		if (ioctl_download && !loading) begin
			// download starting: also invalidate any streaming session by
			// clearing the control-block magic (clip and ring share DDR)
			loading     <= 1'b1;
			word_cnt    <= 32'd0;
			frame_count <= 9'd0;
			frame_word  <= 25'd0;
			ldw_addr    <= 29'h07EFE000;   // 0x3F7F0000 >> 3
			ldw_din     <= 64'd0;
			ldw_req     <= 1'b1;
		end
		if (!ioctl_download && loading) loading <= 1'b0;

		if (ioctl_download && ioctl_wr) begin
			case (word_cnt[1:0])
				2'd0: shift[15:0]  <= ioctl_dout;
				2'd1: shift[31:16] <= ioctl_dout;
				2'd2: begin shift[47:32] <= ioctl_dout; waddr <= next_waddr; end
				2'd3: begin
					if (waddr < VIDEO_LIMIT_W) begin
						ldw_din  <= {ioctl_dout, shift};
						ldw_addr <= waddr;
						ldw_req  <= 1'b1;
					end
				end
			endcase
			word_cnt <= word_cnt + 32'd1;

			// count completed frames (4 x 16-bit words per 64-bit beat;
			// frame_word counts 64-bit beats)
			if (word_cnt[1:0] == 2'd3) begin
				if (frame_word == FRAME_WORDS - 1) begin
					frame_word  <= 25'd0;
					if (~&frame_count) frame_count <= frame_count + 9'd1;
				end else begin
					frame_word <= frame_word + 25'd1;
				end
			end
		end
	end
end

endmodule

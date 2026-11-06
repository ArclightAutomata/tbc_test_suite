// SPDX-License-Identifier: GPL-2.0-or-later
// Four-client DDRAM arbiter (rd, ldw, fbw, posw).
//
// Clients, in priority order:
//   rd  : video_player line-burst reads (latency-critical: must finish
//         within horizontal blanking)
//   ldw : video_loader single writes (only active during file download)
//   fbw : fb_writer single writes (one every 16 clocks, tolerant)
//
// Single outstanding transaction at a time; a client holds the bus until
// its transaction completes (bursts included).

module ddram_mux (
	input             clk,
	input             reset,

	// client: player burst read
	input             rd_req,        // pulse: start burst read
	input      [28:0] rd_addr,
	input      [7:0]  rd_burstcnt,
	output reg        rd_ack,        // read accepted (address phase done)
	// read data flows to the player directly from DDRAM_DOUT/READY

	// client: loader write
	input             ldw_req,
	input      [28:0] ldw_addr,
	input      [63:0] ldw_din,
	output reg        ldw_ack,

	// client: fb write
	input             fbw_req,
	input      [28:0] fbw_addr,
	input      [63:0] fbw_din,
	output reg        fbw_ack,

	// client: player reader-position write (once per field)
	input             posw_req,
	input      [28:0] posw_addr,
	input      [63:0] posw_din,
	output reg        posw_ack,

	// DDRAM
	output reg         ddram_read,
	output reg         ddram_write,
	output reg  [28:0] ddram_addr,
	output reg  [63:0] ddram_din,
	output reg  [7:0]  ddram_burstcnt,
	output      [7:0]  ddram_be,
	input              ddram_busy
);

assign ddram_be = 8'hFF;

always @(posedge clk) begin
	if (reset) begin
		ddram_read  <= 1'b0;
		ddram_write <= 1'b0;
		rd_ack      <= 1'b0;
		ldw_ack     <= 1'b0;
		fbw_ack     <= 1'b0;
		posw_ack    <= 1'b0;
	end else begin
		rd_ack   <= 1'b0;
		ldw_ack  <= 1'b0;
		fbw_ack  <= 1'b0;
		posw_ack <= 1'b0;

		// clear accepted commands
		if (!ddram_busy) begin
			ddram_read  <= 1'b0;
			ddram_write <= 1'b0;
		end

		// issue next command when the bus is free
		if (!ddram_busy && !ddram_read && !ddram_write) begin
			if (rd_req) begin
				ddram_addr     <= rd_addr;
				ddram_burstcnt <= rd_burstcnt;
				ddram_read     <= 1'b1;
				rd_ack         <= 1'b1;
			end else if (ldw_req) begin
				ddram_addr     <= ldw_addr;
				ddram_din      <= ldw_din;
				ddram_burstcnt <= 8'd1;
				ddram_write    <= 1'b1;
				ldw_ack        <= 1'b1;
			end else if (posw_req) begin
				ddram_addr     <= posw_addr;
				ddram_din      <= posw_din;
				ddram_burstcnt <= 8'd1;
				ddram_write    <= 1'b1;
				posw_ack       <= 1'b1;
			end else if (fbw_req) begin
				ddram_addr     <= fbw_addr;
				ddram_din      <= fbw_din;
				ddram_burstcnt <= 8'd1;
				ddram_write    <= 1'b1;
				fbw_ack        <= 1'b1;
			end
		end
	end
end

endmodule

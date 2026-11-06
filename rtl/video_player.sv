// SPDX-License-Identifier: GPL-2.0-or-later
// Custom video playback from DDRAM: looping clip or SD stream.
//
// Clip mode (OSD "Load Video"): plays the loader's RGB565 724x480
// frames from 0x30000000, looping. Limited by DDR size (~12 s).
//
// Stream mode: an ARM-side daemon (tools/tbc_stream.sh) paces frames
// from a pre-converted file on the SD card into a ring buffer at
// 0x30000000 and maintains a control block at 0x3F7F0000:
//   word0 = magic 0x54424353_00000001 ("TBCS" v1)
//   word1[15:0] = frame width (360 or 724; 360 is pixel-doubled)
//   word2 = total frames (unused by the core)
//   word3 = ring size in frames (power of two)
//   word4 = writer frame index (monotonic)
//   word5 = reader frame index (written back BY THE CORE, for pacing)
// The core polls the control block each field (vblank line 241), plays
// frame N from ring slot N & (ring-1) while writer > N+1 (holding the
// last frame on underrun), and writes its position to word5 (line 243).
// If its position leaves the ring's valid window - ahead of the writer
// (a new daemon session) or more than a ring behind - it resyncs
// instead of waiting. Duration is unlimited; pacing is closed-loop so
// clocks cannot drift. (Word6 is the daemon's session id, unused here.)
//
// Either way one line is fetched per scanline as a single burst during
// horizontal blanking into a double line buffer; the pixel path never
// touches DDR. Frames advance every two fields (29.97 fps). Mid-gray
// when nothing is loaded/streaming.

module video_player (
	input             clk,
	input             reset,
	input             enable,        // pattern "Custom Video" selected

	input      [11:0] h_pos,         // 0-2899 sample position
	input      [8:0]  v_count,       // line within field
	input             field,
	input             active,        // active_video
	input             new_line,
	input             new_field,

	input      [8:0]  frame_count,   // from video_loader (clip mode)
	input             loading,

	// arbiter read port
	output reg        rd_req,
	output reg [28:0] rd_addr,
	output reg [7:0]  rd_burstcnt,
	input             rd_ack,
	input      [63:0] ddram_dout,
	input             ddram_dout_ready,

	// arbiter write port (reader position write-back)
	output reg        posw_req,
	output     [28:0] posw_addr,
	output reg [63:0] posw_din,
	input             posw_ack,

	output reg [7:0]  r,
	output reg [7:0]  g,
	output reg [7:0]  b
);

localparam [28:0] VIDEO_BASE_W = 29'h0600_0000;  // 0x30000000 >> 3
localparam [28:0] CTRL_W       = 29'h07EFE000;   // 0x3F7F0000 >> 3
localparam [63:0] MAGIC        = 64'h5442435300000001;

assign posw_addr = CTRL_W + 29'd5;

// ---- control block state (stream mode) ----
reg        stream_ok;      // magic seen this field
reg [15:0] s_width;
reg [31:0] s_ring;         // ring size in frames (power of two)
reg [31:0] s_writer;
wire       narrow = (s_width == 16'd360);

// per-mode geometry
wire [7:0]  line_words  = (stream_ok && narrow) ? 8'd90 : 8'd181;
wire [24:0] frame_words = (stream_ok && narrow) ? 25'd43200 : 25'd86880;

// ---- frame sequencing ----
reg [31:0] cur_frame;      // monotonic in stream mode, wraps in clip mode
reg        half;
wire       clip_ok  = !loading && (frame_count != 0);
wire       want_video = enable && !loading && (stream_ok || clip_ok);

// Stream position vs the daemon's writer. Valid frames are the last
// `ring` ones written (writer-ring .. writer-1); the reader must stay in
// that window. It can leave it two ways, and both used to stall:
//   - ahead (lag <= 0): a new daemon session restarted the writer at 0
//     while the reader kept its old position. The core waited for the
//     writer to pass it while the daemon waited for the reader to catch
//     up - a deadlock. Now: restart from frame 0 if the ring still holds
//     it (fresh session), else jump to the newest frame.
//   - stale (lag > ring): frames the reader points at were overwritten.
//     Now: jump to the newest complete frame.
wire [31:0] lag       = s_writer - cur_frame;
wire        ahead     = $signed(lag) <= 32'sd0;
wire        stale     = !ahead && (lag > s_ring);
wire [31:0] newest    = s_writer - 32'd1;
wire        fresh_run = s_writer <= {1'b0, s_ring[31:1]};

always @(posedge clk) begin
	if (reset || loading) begin
		cur_frame <= 32'd0;
		half      <= 1'b0;
	end else if (!enable) begin
		// Custom Video deselected: a clip restarts from its first frame
		// when reselected, but a stream HOLDS its position (resetting it
		// to 0 used to replay stale ring slots and stall the daemon,
		// which saw a reader thousands of frames behind its writer)
		if (!stream_ok) cur_frame <= 32'd0;
		half <= 1'b0;
	end else if (new_field) begin
		half <= ~half;
		if (half) begin
			if (stream_ok) begin
				if (ahead)
					cur_frame <= fresh_run ? 32'd0 : newest;
				else if (stale)
					cur_frame <= newest;
				else if (lag > 32'd1)      // advance only when the writer is safely ahead
					cur_frame <= cur_frame + 32'd1;
			end else if (clip_ok) begin
				cur_frame <= (cur_frame >= {23'd0, frame_count} - 32'd1) ? 32'd0 : cur_frame + 32'd1;
			end
		end
	end
end

// ring slot (stream) or frame index (clip)
wire [31:0] slot = stream_ok ? (cur_frame & (s_ring - 32'd1)) : cur_frame;

// ---- line prefetch / control poll / position write ----
reg  [63:0] lbuf [0:511];
reg         bank;
reg  [7:0]  widx;
reg  [2:0]  state;          // 0 idle, 1 line ack, 2 line data, 3 ctrl ack, 4 ctrl data

wire [16:0] content_line = {7'd0, v_count} * 17'd2 + {16'd0, field};
reg  [2:0]  ctrl_idx;

always @(posedge clk) begin
	if (reset) begin
		state     <= 3'd0;
		rd_req    <= 1'b0;
		posw_req  <= 1'b0;
		bank      <= 1'b0;
		stream_ok <= 1'b0;
	end else begin
		if (posw_ack) posw_req <= 1'b0;

		case (state)
			3'd0: begin
				if (new_line && want_video && v_count < 9'd240) begin
					rd_addr     <= VIDEO_BASE_W + slot[16:0] * frame_words
					             + content_line * {12'd0, line_words};
					rd_burstcnt <= line_words;
					rd_req      <= 1'b1;
					widx        <= 8'd0;
					bank        <= ~bank;
					state       <= 3'd1;
				end else if (new_line && v_count == 9'd241 && !loading) begin
					// poll control block during vblank - every field, even
					// while another pattern is shown, so the stream state
					// (and the position write-back below) stays current
					rd_addr     <= CTRL_W;
					rd_burstcnt <= 8'd5;
					rd_req      <= 1'b1;
					ctrl_idx    <= 3'd0;
					state       <= 3'd3;
				end else if (new_line && v_count == 9'd243 && stream_ok) begin
					// publish reader position for daemon pacing
					posw_din <= {32'd0, cur_frame};
					posw_req <= 1'b1;
				end
			end
			3'd1: if (rd_ack) begin rd_req <= 1'b0; state <= 3'd2; end
			3'd2: if (ddram_dout_ready) begin
				lbuf[{bank, widx}] <= ddram_dout;
				widx <= widx + 8'd1;
				// end on the length latched at the request: stream_ok
				// (and with it line_words) can drop mid-burst when a clip
				// load starts, and a changed count would wait forever
				if (widx == rd_burstcnt - 8'd1) state <= 3'd0;
			end
			3'd3: if (rd_ack) begin rd_req <= 1'b0; state <= 3'd4; end
			3'd4: if (ddram_dout_ready) begin
				case (ctrl_idx)
					3'd0: stream_ok <= (ddram_dout == MAGIC);
					3'd1: s_width   <= ddram_dout[15:0];
					3'd3: s_ring    <= ddram_dout[31:0];
					3'd4: s_writer  <= ddram_dout[31:0];
					default: ;
				endcase
				ctrl_idx <= ctrl_idx + 3'd1;
				if (ctrl_idx == 3'd4) state <= 3'd0;
			end
			default: state <= 3'd0;
		endcase

		// a clip download owns the DDR region: drop the stream at once
		// rather than at the next poll, so the first field after the
		// load never shows the half-overwritten ring as a stream (after
		// the case, so it also beats a poll that was already in flight)
		if (loading) stream_ok <= 1'b0;
	end
end

// ---- pixel output (724 native or 360 pixel-doubled) ----
wire [9:0] px = (stream_ok && narrow) ? {1'b0, h_pos[11:3]} : h_pos[11:2];
wire       px_valid = (stream_ok && narrow) ? (px < 10'd360) : (px < 10'd724);

reg [63:0] word_q;
reg  [1:0] slot_q;
reg        act_q;

reg [15:0] pix;
always @(*) begin
	case (slot_q)
		2'd0: pix = word_q[15:0];
		2'd1: pix = word_q[31:16];
		2'd2: pix = word_q[47:32];
		default: pix = word_q[63:48];
	endcase
end

always @(posedge clk) begin
	word_q <= lbuf[{bank, px[9:2]}];
	slot_q <= px[1:0];
	act_q  <= active && px_valid;

	if (!want_video) begin
		{r, g, b} <= {8'd128, 8'd128, 8'd128};   // mid-gray placeholder
	end else if (act_q) begin
		r <= {pix[15:11], pix[15:13]};
		g <= {pix[10:5],  pix[10:9]};
		b <= {pix[4:0],   pix[4:2]};
	end else begin
		{r, g, b} <= 24'd0;
	end
end

endmodule

// SPDX-License-Identifier: GPL-2.0-or-later
// EIA-608 line-21 closed-caption generator (VBI transparency test).
//
// Emits a spec-timed caption waveform on line 21 of field 1 (our v_count
// 262 in the 263-line field, 17 lines after vsync start = broadcast line
// 21 with vsync occupying lines 4-6). The payload cycles a valid pop-on
// caption that spells "TBC TEST" every ~2 s, so a DUT chain that
// preserves the VBI yields a *decodable* caption on any CC-equipped set
// or VBI-aware capture — a pass/fail transparency test for TBCs and
// frame synchronizers that regenerate blanking.
//
// Waveform (per EIA-608): clock run-in of 7 sine cycles at 32x fH
// (503.5 kHz, 50 IRE p-p centered on 25 IRE) starting 10.5 us after the
// hsync leading edge, then start bits 0-0-1, then two 7-bit+odd-parity
// bytes LSB-first as 0/50 IRE NRZ. Bit cells are 3640/32 = 113.75
// samples, tracked with a fractional accumulator. Edges are square
// (spec wants 240 ns raised-cosine; the DAC and adapter filtering
// smooth them enough for real decoders).
//
// The output is pure luma: the top level feeds level into R=G=B at the
// encoder inputs, so Y carries the waveform exactly and U=V=0 — no
// chroma on line 21, and CVBS mode scales it with the rest of the
// signal. NTSC only (PAL VBI would be teletext/WSS, out of scope);
// requires interlace (a 262-line progressive field has no line 262).

module vbi_cc (
	input        clk,
	input        reset,
	input        enable,
	input [11:0] h_count,
	input  [8:0] v_count,
	input        field,      // 0 = the 263-line field = broadcast field 1
	input  [1:0] v_shift,    // vsync moved earlier: CC line tracks it
	input        new_field,
	output reg [7:0] level,
	output reg       act
);

// 17 lines after vsync start (which V Position moves earlier in pairs)
wire [8:0] cc_line = 9'd262 - {6'd0, v_shift, 1'b0};

// Caption sequence, one byte pair per frame, odd parity included.
// Control pairs doubled per spec; pop-on (RCL..EOC) redraws without
// blanking, nulls pad the loop to ~2.1 s.
reg [5:0]  seq;
reg [15:0] pair;
always @(*) begin
	case (seq)
		6'd0, 6'd1: pair = 16'h9420;  // RCL (resume caption loading)
		6'd2, 6'd3: pair = 16'h9470;  // PAC: row 15, white
		6'd4:       pair = 16'h54C2;  // "TB"
		6'd5:       pair = 16'h4320;  // "C "
		6'd6:       pair = 16'h5445;  // "TE"
		6'd7:       pair = 16'hD354;  // "ST"
		6'd8, 6'd9: pair = 16'h942F;  // EOC (display the loaded caption)
		default:    pair = 16'h8080;  // nulls
	endcase
end

// Advance once per frame, entering the short field (just after the CC
// line of the long field has been emitted)
always @(posedge clk) begin
	if (reset)
		seq <= 6'd0;
	else if (new_field && field)
		seq <= seq + 6'd1;
end

// Line engine: bit cells via fractional accumulator (32/3640 per
// sample); run-in sine via its own DDS (2.25 LUT steps/sample = 503.3
// kHz, 0.02% off nominal - far inside decoder PLL range).
localparam CC_START = 12'd601;  // 10.5 us after hsync leading edge

reg        running;
reg [11:0] cell_acc;
reg [4:0]  bit_idx;             // 0-6 run-in, 7-9 start bits, 10-25 data
reg [15:0] run_phase;

wire on_line = enable && !field && (v_count == cc_line);

// LUT amplitude is +/-255; x64 >> 8 gives +/-64 around the 25 IRE
// center = 50 IRE p-p run-in
wire signed [10:0] sin_val;
sine_lut cc_sin (.addr(run_phase[15:8]), .data(sin_val));
wire signed [18:0] sin_prod = sin_val * $signed(8'd64);
wire [7:0] run_level = 8'd64 + {sin_prod[18], sin_prod[14:8]};

reg data_bit;
always @(*) begin
	if (bit_idx == 5'd9)
		data_bit = 1'b1;                        // start bit S3
	else if (bit_idx >= 5'd10 && bit_idx <= 5'd17)
		data_bit = pair[4'd8 + (bit_idx - 5'd10)];  // byte 1, LSB first
	else if (bit_idx >= 5'd18)
		data_bit = pair[bit_idx - 5'd18];           // byte 2, LSB first
	else
		data_bit = 1'b0;                        // S1, S2
end

always @(posedge clk) begin
	if (reset) begin
		running   <= 1'b0;
		cell_acc  <= 12'd0;
		bit_idx   <= 5'd0;
		run_phase <= 16'd0;
		level     <= 8'd0;
		act       <= 1'b0;
	end else begin
		if (on_line && h_count == CC_START) begin
			running   <= 1'b1;
			cell_acc  <= 12'd0;
			bit_idx   <= 5'd0;
			run_phase <= 16'd0;
		end else if (!on_line) begin
			running <= 1'b0;
		end else if (running) begin
			run_phase <= run_phase + 16'd576;
			if (cell_acc >= 12'd3608) begin
				cell_acc <= cell_acc + 12'd32 - 12'd3640;
				if (bit_idx == 5'd25)
					running <= 1'b0;
				else
					bit_idx <= bit_idx + 5'd1;
			end else begin
				cell_acc <= cell_acc + 12'd32;
			end
		end

		act   <= running;
		level <= !running          ? 8'd0 :
		         (bit_idx <= 5'd6) ? run_level :
		         data_bit          ? 8'd128 : 8'd0;
	end
end

endmodule

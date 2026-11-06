// SPDX-License-Identifier: GPL-2.0-or-later
// Tearing Error Generator
// Adds abrupt horizontal displacement to PRNG-selected lines
// Simulates horizontal sync instability

module error_tear (
	input        clk,
	input        reset,
	input  [2:0] mode,         // 0=Off, 1=Mild, 2=Moderate, 3=Severe, 4=Random Burst, 7=Ramp
	input  [7:0] ramp,         // sweep level for mode 7 (0..255 -> 0..~±9 us at 16% of lines)
	input        new_line,     // pulse at start of each line
	input [31:0] rng_value,    // from PRNG

	output reg signed [12:0] h_offset  // horizontal offset for this line
);

// Ramp mode: amplitude scales continuously with the sweep level at a
// fixed 16% line-hit rate. level 255 -> ~±510 samples (~±9 us).
wire signed [12:0] rnd_off   = $signed(rng_value[20:8]) >>> 3;
wire signed [21:0] ramp_prod = rnd_off * $signed({1'b0, ramp});
wire signed [12:0] tear_ramp = ramp_prod >>> 8;

// Burst state
reg [4:0] burst_remaining;
reg signed [12:0] burst_offset;

always @(posedge clk) begin
	if (reset) begin
		h_offset       <= 13'sd0;
		burst_remaining <= 5'd0;
		burst_offset    <= 13'sd0;
	end else if (new_line) begin
		case (mode)
			3'd0: begin  // Off (also drops any burst in progress, so a run
			             // never inherits one from before the OSD opened)
				h_offset        <= 13'sd0;
				burst_remaining <= 5'd0;
			end

			3'd1: begin  // Mild: rare, small offsets
				if (rng_value[7:0] < 8'd5) begin  // ~2% of lines
					h_offset <= $signed(rng_value[20:8]) >>> 6; // +/- ~64 samples
				end else begin
					h_offset <= 13'sd0;
				end
			end

			3'd2: begin  // Moderate: occasional, medium offsets
				if (rng_value[7:0] < 8'd20) begin  // ~8% of lines
					h_offset <= $signed(rng_value[20:8]) >>> 4; // +/- ~256 samples
				end else begin
					h_offset <= 13'sd0;
				end
			end

			3'd3: begin  // Severe: frequent, large offsets — brutal but structured.
				// (Was 23% of lines at +/-1024 samples = +/-18 us: total sync
				// chaos nothing could correct. +/-512 samples = +/-9 us on ~16%
				// of lines still far exceeds bad tape, but leaves a TBC
				// something to lock onto.)
				if (rng_value[7:0] < 8'd40) begin  // ~16% of lines
					h_offset <= $signed(rng_value[20:8]) >>> 3; // +/- ~512 samples
				end else begin
					h_offset <= 13'sd0;
				end
			end

			3'd7: begin  // Ramp: sweep-scaled amplitude, fixed occurrence
				if (rng_value[7:0] < 8'd40) begin  // ~16% of lines
					h_offset <= tear_ramp;
				end else begin
					h_offset <= 13'sd0;
				end
			end

			3'd4: begin  // Random Burst: consecutive displaced lines
				if (burst_remaining > 5'd0) begin
					h_offset <= burst_offset;
					burst_remaining <= burst_remaining - 5'd1;
				end else if (rng_value[7:0] < 8'd8) begin  // ~3% chance to start burst
					burst_remaining <= rng_value[12:8] + 5'd5;  // 5-36 lines
					burst_offset    <= $signed(rng_value[24:12]) >>> 4;
					h_offset        <= $signed(rng_value[24:12]) >>> 4;
				end else begin
					h_offset <= 13'sd0;
				end
			end

			default: h_offset <= 13'sd0;
		endcase
	end
end

endmodule

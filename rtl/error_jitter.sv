// SPDX-License-Identifier: GPL-2.0-or-later
// Timebase Jitter Error Generator
//
// White per-line horizontal displacement: EVERY line lands a random
// amount early or late (uniform distribution), unlike tearing's sparse
// large events or wow/flutter's periodic modulation. This is the
// textbook VCR impairment, and jitter attenuation (input vs output
// residual RMS, measured with the Analysis pattern's rulers) is the
// most fundamental line-TBC specification.
//
// Peak amplitudes (uniform, so RMS = peak/sqrt(3)):
//   Faint   +/-4 samples  (~0.07 us peak, ~0.04 us RMS) - healthy deck
//   Light   +/-16 samples (~0.28 us peak, ~0.16 us RMS)
//   Typical +/-32 samples (~0.56 us peak, ~0.32 us RMS)
//   Heavy   +/-64 samples (~1.1 us peak,  ~0.65 us RMS)

module error_jitter (
	input         clk,
	input         reset,
	input  [2:0]  mode,      // 0=Off 1=Faint 2=Light 3=Typical 4=Heavy 7=Ramp (sweep)
	input  [7:0]  ramp,      // sweep level for mode 7 (0..255 -> 0..~Heavy)
	input         new_line,
	input  [31:0] rng,

	output reg signed [12:0] h_offset
);

wire signed [12:0] draw = $signed(rng[28:16]);   // +/-4096 uniform

// Ramp: peak scales continuously with the sweep level (255 ~ Heavy)
wire signed [20:0] ramp_prod = draw * $signed({1'b0, ramp});
wire signed [12:0] jit_ramp  = ramp_prod >>> 14;

always @(posedge clk) begin
	if (reset || mode == 3'd0) begin
		h_offset <= 13'sd0;
	end else if (new_line) begin
		case (mode)
			3'd1:    h_offset <= draw >>> 10;
			3'd2:    h_offset <= draw >>> 8;
			3'd3:    h_offset <= draw >>> 7;
			3'd4:    h_offset <= draw >>> 6;
			3'd7:    h_offset <= jit_ramp;
			default: h_offset <= 13'sd0;
		endcase
	end
end

endmodule

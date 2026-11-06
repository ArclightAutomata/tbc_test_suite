// SPDX-License-Identifier: GPL-2.0-or-later
// Pseudo-Random Number Generator
// 32-bit xorshift LFSR with configurable 8-bit seed
// Produces deterministic sequences for reproducible error patterns

module prng (
	input        clk,
	input        reset,
	input  [7:0] seed,
	input        reload,     // pulse: restart the sequence from the seed
	input        advance,    // pulse to get next value
	output [31:0] rng_value
);

reg [31:0] state;

// Expand 8-bit seed to 32-bit initial state (avoid zero state)
wire [31:0] seed_expanded = {seed, seed ^ 8'hA5, seed ^ 8'h5A, seed ^ 8'hFF};
wire [31:0] initial_state = (seed_expanded == 32'd0) ? 32'd1 : seed_expanded;

// Xorshift32 algorithm
wire [31:0] s1 = state ^ (state << 13);
wire [31:0] s2 = s1 ^ (s1 >> 17);
wire [31:0] s3 = s2 ^ (s2 << 5);

always @(posedge clk) begin
	if (reset || reload) begin
		state <= initial_state;
	end else if (advance) begin
		state <= s3;
	end
end

assign rng_value = state;

endmodule

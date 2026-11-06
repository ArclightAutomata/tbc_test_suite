// SPDX-License-Identifier: GPL-2.0-or-later
// Encoder randomness independence testbench (Verilator).
//
// Chroma Noise and Burst Flicker draw their per-line random values in
// yc_encoder. They must be independent of the timing errors drawn on
// the same line: with Tearing and Chroma Noise both on, a torn line's
// hue error should be as likely negative as positive, and the burst
// flicker level should not be predictable from the tear offset.
//
// Wires the real prng (as error_injector does), error_tear (Severe:
// ~16% of lines) and yc_encoder (Chroma Noise Severe, Burst Flicker),
// with short 64-clock lines (these draws only care about line starts),
// and checks on the torn lines:
//   1  noise direction: 35-65% negative (independent: ~50%)
//   2  flicker vs tear offset: P(flicker = 100% | offset[1:0] = 3)
//      within 35-65% (independent: 50%)
//   3  sanity: noise still spans most of its +/-32-step range
// Plusargs: +lines=N (default 200000), +seed=N (0-255)

module tb_enc_rng (
	input  clk,
	output reg done,
	output reg failed
);

reg [7:0]  rst_cnt = 8'd0;
wire       reset   = (rst_cnt != 8'hFF);
integer    nlines, seed_arg;
reg [7:0]  seed;

initial begin
	if (!$value$plusargs("lines=%d", nlines)) nlines = 200000;
	if (!$value$plusargs("seed=%d", seed_arg)) seed_arg = 0;
	seed   = seed_arg[7:0];
	done   = 1'b0;
	failed = 1'b0;
	$display("tb_enc_rng: %0d lines, seed %0d", nlines, seed);
end

// 64-clock lines
reg [5:0] h = 6'd0;
reg       new_line = 1'b0;
always @(posedge clk) begin
	if (rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 8'd1;
	h        <= h + 6'd1;
	new_line <= (h == 6'd63);
end

// shared PRNG, exactly as error_injector drives it (advance per line;
// reload pulses once when the run starts, like closing the OSD)
reg reseed = 1'b0;
always @(posedge clk) reseed <= (rst_cnt == 8'hFE);
wire [31:0] rng;
prng prng_inst (
	.clk(clk), .reset(reset), .seed(seed), .reload(reseed),
	.advance(new_line), .rng_value(rng)
);

wire signed [12:0] tear_off;
error_tear tear (
	.clk(clk), .reset(reset), .mode(3'd3), .ramp(8'd0),
	.new_line(new_line), .rng_value(rng), .h_offset(tear_off)
);

wire [7:0] y_out, c_out;
yc_encoder enc (
	.clk(clk), .reset(reset),
	.r(8'd128), .g(8'd128), .b(8'd128), .burst_window(1'b0),
	.new_line(new_line), .seed(seed), .reload(reseed),
	.new_field(1'b0), .hue_drift(1'b0),
	.pal(1'b0), .cvbs(1'b0), .hue_offset(8'd0), .burst_level(3'd4),
	.sc_mode(3'd0), .chroma_delay(8'd0), .noise_mode(2'd3), .chroma_bw(1'b0),
	.chroma_force(1'b0), .chroma_u(10'sd0),
	.y_out(y_out), .c_out(c_out)
);

// both draws register on the new_line edge; sample them one clock later
reg        sample = 1'b0;
integer    lines = 0, torn = 0, torn_neg = 0, n3 = 0, n3_full = 0;
integer    nmin = 999, nmax = -999;

task automatic check(input bit ok, input string what);
	$display("  [%s] %s", ok ? "PASS" : "FAIL", what);
	if (!ok) failed = 1'b1;
endtask

always @(posedge clk) begin
	sample <= new_line && !reset;
	if (sample && !done) begin
		lines++;
		if (int'(enc.noise_step) < nmin) nmin = int'(enc.noise_step);
		if (int'(enc.noise_step) > nmax) nmax = int'(enc.noise_step);
		if (tear_off != 13'sd0) begin
			torn++;
			if (enc.noise_step < 0) torn_neg++;
			if (tear_off[1:0] == 2'd3) begin
				n3++;
				if (enc.flick == 2'd0) n3_full++;
			end
		end
		if (lines == nlines) begin
			$display("%0d lines, %0d torn (%0d%%)", lines, torn, torn * 100 / lines);
			$display("  torn lines with negative hue noise: %0d of %0d (%0d%%)", torn_neg, torn, torn_neg * 100 / torn);
			$display("  torn lines with offset[1:0]=3: %0d, of which flicker=100%%: %0d (%0d%%)", n3, n3_full, n3_full * 100 / n3);
			$display("  hue noise range: %0d..%0d steps (design: +/-32)", nmin, nmax);
			check(torn_neg * 100 >= torn * 35 && torn_neg * 100 <= torn * 65,
			      "1: hue noise direction independent of tearing");
			check(n3_full * 100 >= n3 * 35 && n3_full * 100 <= n3 * 65,
			      "2: burst flicker independent of the tear offset");
			check(nmin <= -28 && nmax >= 28, "3: hue noise spans its range");
			done <= 1'b1;
		end
	end
end

endmodule

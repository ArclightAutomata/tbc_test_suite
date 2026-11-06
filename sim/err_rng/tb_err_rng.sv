// SPDX-License-Identifier: GPL-2.0-or-later
// Timing-error randomness independence testbench (Verilator).
//
// Combined timing errors (e.g. the VCR presets) must draw independent
// random values: one error's draw must not predict another's on the
// same line. Runs the real error_injector (Tearing, Jitter Heavy, Head
// Switch Unstable) and error_dropout (Heavy) over many short fields
// (only line starts matter to these draws) and checks:
//   1  Jitter's direction on lines where a dropout starts: 35-65%
//      negative (independent: ~50%)
//   2  Head Switch Unstable step vs the jitter offset on the switch
//      line: chi-square independence over 8x8 buckets of the bits that
//      used to coincide
//   3  Tear Burst offset vs the jitter offset at burst starts: same test
// The chi-square limit (110 for 63 degrees of freedom) is far above
// independent scatter (~63 +/- 11) and far below a deterministic link.
// Plusargs: +fields=N (default 3000), +seed=N

module tb_err_rng (
	input  clk,
	output reg done,
	output reg failed
);

reg [7:0] rst_cnt = 8'd0;
wire      reset = (rst_cnt != 8'hFF);
integer   nfields, seed_arg;
reg [7:0] seed;
initial begin
	if (!$value$plusargs("fields=%d", nfields)) nfields = 3000;
	if (!$value$plusargs("seed=%d", seed_arg)) seed_arg = 0;
	seed = seed_arg[7:0]; done = 0; failed = 0;
	$display("tb_err_rng: %0d fields, seed %0d", nfields, seed);
end

// 262-line fields of 8-clock lines
reg [2:0] h = 0;
reg [8:0] v = 0;
reg new_line = 0, new_field = 0, field = 0;
always @(posedge clk) begin
	if (rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 8'd1;
	h <= h + 3'd1;
	new_line <= (h == 3'd7);
	new_field <= 1'b0;
	if (h == 3'd7) begin
		if (v == 9'd261) begin v <= 0; new_field <= 1'b1; end
		else v <= v + 9'd1;
	end
end

// tear mode alternates between Severe and Burst every 500 fields
integer fcount = 0;
wire [2:0] tear_mode = ((fcount / 500) % 2) ? 3'd4 : 3'd3;

wire signed [12:0] h_off, llm;
wire [8:0] roll;
wire [2:0] dropout_eff;
wire [7:0] ramp;
wire [31:0] rng;
wire reseed, err_active;
error_injector inj (
	.clk(clk), .reset(reset), .test_active(1'b1), .pal(1'b0),
	.v_count(v), .field(field), .new_line(new_line), .new_field(new_field),
	.roll_mode(3'd0), .tear_mode(tear_mode), .flagwave_mode(3'd0), .skew_mode(3'd0),
	.wow_mode(3'd0), .flutter_mode(2'd0), .dropout_mode(3'd3), .headsw_mode(3'd4),
	.jitter_mode(3'd4), .sweep_sel(3'd0), .prng_seed(seed),
	.h_offset_out(h_off), .line_length_mod_out(llm), .roll_shift_out(roll),
	.dropout_eff(dropout_eff), .ramp_level(ramp), .rng_out(rng),
	.reseed_out(reseed), .err_active(err_active)
);

wire drop_act; wire [7:0] drop_luma;
error_dropout drop (
	.clk(clk), .reset(reset), .mode(dropout_eff), .h_pos(12'd0), .v_count(v),
	.new_line(new_line), .new_field(new_field),
	.seed(seed), .reload(reseed), .act(drop_act), .luma(drop_luma)
);

// per-module outputs (registered on new_line; sampled one clock later)
wire signed [12:0] jit  = inj.jitter_h_offset;
wire signed [12:0] hsw  = inj.headsw_h_offset;
wire signed [12:0] tear = inj.tear_h_offset;

integer drop_lines = 0, drop_neg = 0;
integer hs_n = 0, bt_n = 0;
integer hs_tab [0:63];
integer bt_tab [0:63];
reg sample = 0;
reg trig_q = 0;
reg [4:0] burst_prev = 0;
reg signed [12:0] jit233 = 0;

initial for (int i = 0; i < 64; i++) begin hs_tab[i] = 0; bt_tab[i] = 0; end

function automatic real chi2(input integer tab [0:63], input integer n);
	real rs [0:7], cs [0:7], c, e;
	for (int i = 0; i < 8; i++) begin rs[i] = 0; cs[i] = 0; end
	for (int i = 0; i < 64; i++) begin rs[i / 8] += tab[i]; cs[i % 8] += tab[i]; end
	c = 0;
	for (int i = 0; i < 64; i++) begin
		e = rs[i / 8] * cs[i % 8] / n;
		if (e > 0) c += (tab[i] - e) * (tab[i] - e) / e;
	end
	return c;
endfunction

task automatic check(input bit ok, input string what);
	$display("  [%s] %s", ok ? "PASS" : "FAIL", what);
	if (!ok) failed = 1'b1;
endtask

always @(posedge clk) begin
	sample <= new_line && err_active;
	trig_q <= drop.trig_single;          // trigger as evaluated on this line's draw
	if (new_field) fcount <= fcount + 1;
	burst_prev <= inj.tear_inst.burst_remaining;
	if (sample && !done) begin
		// 1: a dropout triggered on this line's draw
		if (trig_q) begin
			drop_lines++;
			if (jit < 0) drop_neg++;
		end
		// 2: the head switch step is drawn on line 233 and appears on 234;
		// pair it with the jitter drawn on line 233
		if (v == 9'd233) jit233 <= jit;
		if (v == 9'd234) begin
			hs_tab[((hsw - 13'sd57) & 7) * 8 + ((jit233 >>> 2) & 7)]++;
			hs_n++;
		end
		// 3: a tear burst just started on this line
		if (tear_mode == 3'd4 && burst_prev == 0 && inj.tear_inst.burst_remaining != 0) begin
			bt_tab[((tear >>> 6) & 7) * 8 + (jit & 7)]++;
			bt_n++;
		end
		if (fcount == nfields) begin
			real c2, c3;
			c2 = chi2(hs_tab, hs_n); c3 = chi2(bt_tab, bt_n);
			$display("dropout lines: %0d, jitter negative on %0d (%0d%%)", drop_lines, drop_neg, drop_neg * 100 / (drop_lines > 0 ? drop_lines : 1));
			$display("head-switch step vs jitter: chi2 %.0f over %0d fields (independent ~63)", c2, hs_n);
			$display("tear burst offset vs jitter: chi2 %.0f over %0d bursts (independent ~63)", c3, bt_n);
			check(drop_lines > 200 && drop_neg * 100 >= drop_lines * 35 && drop_neg * 100 <= drop_lines * 65,
			      "1: jitter independent of the dropout trigger");
			check(hs_n > 1000 && c2 < 110, "2: head-switch step independent of jitter");
			check(bt_n > 500 && c3 < 110, "3: tear burst offset independent of jitter");
			done <= 1'b1;
		end
	end
end

endmodule

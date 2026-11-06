// SPDX-License-Identifier: GPL-2.0-or-later
// Dropout statistics testbench (Verilator).
//
// Runs the real rtl/error_dropout.sv and rtl/prng.sv against NTSC line
// timing (3640 samples x 262 lines, the same counter structure as
// ntsc_timing) for a configurable stretch of video time, with one DUT
// per mode (Light, Moderate, Heavy, Stress, Crease) sharing one PRNG stream.
//
// Pass criteria come from the module's own design comments:
//   - event rate per mode: Light ~1/s, Moderate ~10/s, Heavy ~100/s,
//     Stress ~1000/s
//   - length is short-weighted: (64..127) << e, e = 0..4 at p = 1/2,
//     1/4, 1/8, 1/16, 1/16 - so half under 128 samples, 7/8 under 512,
//     none over 2032, mean ~286 (~5 us); Stress one octave up: none
//     under 128, half under 256, mean ~480
//   - the sparkle is uncorrelated sample to sample (it was a 1-bit-
//     shift LFSR whose neighbors shared 5 of 6 bits)
//   - every event fades in (mix 1, 2, .. 16 over its first 16 samples)
//     at the sparkle level, then leaves a black tail (len/4 + 16
//     samples) whose last 16 samples fade out (mix 16 .. 1)
//   - the longest events still run through the next line's hsync
//   - creases land on lines 40-167, are 4-11 lines tall, and persist
//     48-96 fields
//
// Plusargs: +seconds=N (video time, default 60), +seed=N (0-255)

module tb_dropout (
	input  clk,
	output reg done,
	output reg failed
);

// ---- reset + run length ----
reg [7:0]  rst_cnt = 8'd0;
wire       reset   = (rst_cnt != 8'hFF);
reg [63:0] cyc     = 64'd0;
reg [63:0] run_cycles;
reg [7:0]  seed;
integer    secs, seed_arg;

initial begin
	if (!$value$plusargs("seconds=%d", secs)) secs = 60;
	if (!$value$plusargs("seed=%d", seed_arg)) seed_arg = 0;
	seed       = seed_arg[7:0];
	run_cycles = 64'd57272727 * secs;
	done       = 1'b0;
	failed     = 1'b0;
	$display("tb_dropout: %0d s of video (%0d cycles), seed %0d", secs, run_cycles, seed);
end

// ---- NTSC timing (mirrors ntsc_timing's counter structure) ----
reg [11:0] h_count  = 12'd0;
reg [8:0]  v_count  = 9'd0;
reg        new_line = 1'b0;
reg        new_field = 1'b0;

always @(posedge clk) begin
	if (rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 8'd1;
	cyc <= cyc + 64'd1;

	new_line <= 1'b0;
	if (h_count >= 12'd3639) begin
		h_count  <= 12'd0;
		new_line <= 1'b1;
	end else begin
		h_count <= h_count + 12'd1;
	end

	new_field <= 1'b0;
	if (new_line) begin
		if (v_count >= 9'd261) begin
			v_count   <= 9'd0;
			new_field <= 1'b1;
		end else begin
			v_count <= v_count + 9'd1;
		end
	end
end

wire [11:0] h_pos = (h_count >= 12'd668) ? (h_count - 12'd668) : 12'd0;

// ---- shared PRNG (advances once per line, like error_injector) ----
wire [31:0] rng;
prng prng_inst (
	.clk(clk), .reset(reset), .seed(seed), .reload(1'b0),
	.advance(new_line), .rng_value(rng)
);

// ---- one probe per mode ----
reg  stop = 1'b0;
wire [4:0] fail;

dropout_probe #(.MODE(1), .NAME("Light"))    p1 (.*, .fail(fail[0]));
dropout_probe #(.MODE(2), .NAME("Moderate")) p2 (.*, .fail(fail[1]));
dropout_probe #(.MODE(3), .NAME("Heavy"))    p3 (.*, .fail(fail[2]));
dropout_probe #(.MODE(4), .NAME("Stress"))   p4 (.*, .fail(fail[3]));
dropout_probe #(.MODE(5), .NAME("Crease"))   p5 (.*, .fail(fail[4]));

// stop: probes report on the stop cycle, verdict the cycle after
always @(posedge clk) begin
	if (!stop && cyc == run_cycles) stop <= 1'b1;
	if (stop) begin
		failed <= |fail;
		done   <= 1'b1;
	end
end

endmodule


module dropout_probe #(
	parameter [2:0] MODE = 3'd1,
	parameter       NAME = "?"
) (
	input        clk,
	input        reset,
	input        stop,
	input  [7:0] seed,
	input [11:0] h_count,
	input [11:0] h_pos,
	input  [8:0] v_count,
	input        new_line,
	input        new_field,
	input [31:0] rng,
	input  integer secs,
	output reg   fail
);

wire       act, body;
wire [4:0] mix;
wire [7:0] luma;

error_dropout dut (
	.clk(clk), .reset(reset), .mode(MODE),
	.h_pos(h_pos), .v_count(v_count),
	.new_line(new_line), .new_field(new_field),
	.seed(seed), .reload(1'b0),
	.act(act), .body(body), .mix(mix), .luma(luma)
);

// ---- event shape: onset ramp, body level, tail length and fade ----
reg  act_p = 1'b0, body_p = 1'b0;
reg [4:0] mix_p = 5'd0;
always @(posedge clk) mix_p <= mix;
int  since = 0;          // samples since a fresh onset
int  tail_n = 0, tail_want = 0;
longint ramp_bad = 0, lvl_bad = 0, tail_ok = 0, tail_bad = 0, fade_bad = 0, onsets = 0;
always @(posedge clk) if (!reset) begin
	act_p <= act; body_p <= body;
	// fresh onset from idle: mix must climb 1..16
	if (act && !act_p) begin since = 0; onsets++; end else if (act) since++;
	if (body && since < 16 && act_p == (since != 0) && mix != 5'(since + 1)) ramp_bad++;
	if (body && (luma < 8'd185 || luma > 8'd248)) lvl_bad++;
	if (act && !body && luma != 8'd0) lvl_bad++;
	// tail: from body end to idle (a new body inside it voids the count)
	if (body_p && !body && act) begin tail_n = 1; tail_want = int'(dut.tail_len); end
	else if (tail_n > 0 && act && !body) tail_n++;
	if (tail_n > 0 && body) tail_n = 0;
	if (tail_n > 0 && !act) begin
		if (tail_n == tail_want) tail_ok++; else tail_bad++;
		tail_n = 0;
	end
	// fade: the tail's last samples count mix down to 1
	if (act_p && !body_p && !act && mix_p != 5'd1) fade_bad++;
	// sparkle texture: neighbors should be unrelated (a 1-bit-shift LFSR
	// makes the next value's top 5 bits equal this one's low 5 bits)
	luma_p <= luma;
	if (body) sp_seen[luma - 8'd185] = 1;
	if (body && body_p) begin
		sp_pairs++;
		if (((luma - 8'd185) >> 1) == ((luma_p - 8'd185) & 8'h1F)) sp_shift++;
	end
end
reg  [7:0] luma_p = 8'd0;
longint    sp_pairs = 0, sp_shift = 0;
bit        sp_seen [0:255];
function automatic int count_sp();
	int c = 0;
	for (int i = 0; i < 256; i++) if (sp_seen[i]) c++;
	return c;
endfunction


// ---- dropout events: a scheduled segment converting to a countdown ----
wire seg_start_now = dut.seg_on && (h_pos == dut.seg_start);

longint ev_n = 0, ev_sum = 0, reach_n = 0;
int     ev_min = 99999, ev_max = 0;
int     hist [0:7];
reg     pending_reach = 1'b0;

// ---- crease events: crease_fields going 0 -> nonzero ----
reg  [6:0] cf_prev = 7'd0;
int        cr_n = 0;
int        cv_min = 999, cv_max = 0;
int        cr_len_min = 99999, cr_len_max = 0;
bit        cv_seen   [0:511];
bit        cl_seen   [0:15];
bit        cf_seen   [0:127];

initial begin
	fail = 1'b0;
	for (int i = 0; i < 8; i++)   hist[i] = 0;
	for (int i = 0; i < 512; i++) cv_seen[i] = 0;
	for (int i = 0; i < 16; i++)  cl_seen[i] = 0;
	for (int i = 0; i < 128; i++) cf_seen[i] = 0;
	for (int i = 0; i < 256; i++) sp_seen[i] = 0;
end

function automatic int count_seen_v();
	int c = 0;
	for (int i = 0; i < 512; i++) if (cv_seen[i]) c++;
	return c;
endfunction
function automatic int count_seen_l();
	int c = 0;
	for (int i = 0; i < 16; i++) if (cl_seen[i]) c++;
	return c;
endfunction
function automatic int count_seen_f();
	int c = 0;
	for (int i = 0; i < 128; i++) if (cf_seen[i]) c++;
	return c;
endfunction

task automatic check(input bit ok, input string what);
	$display("  [%s] %-8s %s", ok ? "PASS" : "FAIL", NAME, what);
	if (!ok) fail = 1'b1;
endtask

always @(posedge clk) begin
	if (!reset) begin
		// every dropout event (singles and crease streaks)
		if (seg_start_now) begin
			int len = int'(dut.seg_len);
			int b   = (len < 128) ? 0 : (len < 256) ? 1 : (len < 512) ? 2 : (len < 1024) ? 3 : (len < 2048) ? 4 : 5;
			ev_n++;
			ev_sum += len;
			if (len < ev_min) ev_min = len;
			if (len > ev_max) ev_max = len;
			hist[(b < 0) ? 0 : (b > 7) ? 7 : b]++;
			pending_reach <= 1'b1;
		end else if (!act) begin
			pending_reach <= 1'b0;
		end
		// still active inside the next line's hsync pulse?
		if (pending_reach && act && h_count == 12'd100) begin
			reach_n++;
			pending_reach <= 1'b0;
		end

		// crease placement
		cf_prev <= dut.crease_fields;
		if (cf_prev == 7'd0 && dut.crease_fields != 7'd0) begin
			cr_n++;
			cv_seen[dut.crease_v] = 1;
			cl_seen[dut.crease_lines] = 1;
			cf_seen[dut.crease_fields] = 1;
			if (int'(dut.crease_v) < cv_min) cv_min = int'(dut.crease_v);
			if (int'(dut.crease_v) > cv_max) cv_max = int'(dut.crease_v);
			if (int'(dut.crease_len) < cr_len_min) cr_len_min = int'(dut.crease_len);
			if (int'(dut.crease_len) > cr_len_max) cr_len_max = int'(dut.crease_len);
		end
	end

	if (stop) begin
		$display("");
		$display("%s (mode %0d): %0d dropout events", NAME, MODE, ev_n);
		if (ev_n > 0) begin
			$display("  rate: %0d.%0d events/s", ev_n * 10 / secs / 10, ev_n * 10 / secs % 10);
			$display("  length: min %0d, max %0d, mean %0d samples  (design: %s)",
			         ev_min, ev_max, ev_sum / ev_n, (MODE == 3'd4) ? "128-2032, mean ~480" : "64-2032, mean ~286");
			$display("  length by octave (<128 <256 <512 <1024 <2048): %0d %0d %0d %0d %0d  (design: %s)",
			         hist[0], hist[1], hist[2], hist[3], hist[4], (MODE == 3'd4) ? "0 1/2 1/4 1/8 1/8" : "1/2 1/4 1/8 1/16 1/16");
			$display("  reached next line's hsync: %0d of %0d", reach_n, ev_n);
			$display("  shape: %0d onsets, ramp errors %0d, level errors %0d; tails %0d exact, %0d off; fade errors %0d",
			         onsets, ramp_bad, lvl_bad, tail_ok, tail_bad, fade_bad);
		end
		check(ramp_bad == 0 && lvl_bad == 0, "onset fades in over 16 samples; sparkle body, black tail");
		check(tail_bad == 0 && fade_bad == 0 && tail_ok > 0, "tail lasts len/4 + 16 samples and fades out");
		if (sp_pairs > 0)
			$display("  sparkle: %0d values seen; shifted-neighbor pairs %0d of %0d (random: ~1/32)",
			         count_sp(), sp_shift, sp_pairs);
		check(count_sp() == 64 && sp_shift * 16 < sp_pairs, "sparkle covers 185-248 with unrelated neighbors");

		if (MODE != 3'd5) begin
			check(ev_n >= 30, "enough events to judge (>= 30)");
			if (ev_n >= 30) begin
				real rate = real'(ev_n) / secs;
				real want = (MODE == 3'd1) ? 0.96 : (MODE == 3'd2) ? 10.08 : (MODE == 3'd3) ? 100.8 : 1008.0;
				// 3 sigma of the Poisson count, at least 10%
				real tol = 3.0 / $sqrt(want * secs);
				if (tol < 0.1) tol = 0.1;
				check(rate > want * (1 - tol) && rate < want * (1 + tol),
				      $sformatf("rate %.2f/s within %.0f%% of %.2f/s", rate, tol * 100, want));
				if (MODE != 3'd4) begin
					check(ev_min >= 64 && ev_max <= 2032, "length within 64-2032");
					check(hist[0] * 100 > ev_n * 40 && hist[0] * 100 < ev_n * 60, "about half the events under 128 samples");
					check((hist[0] + hist[1] + hist[2]) * 100 > ev_n * 82, "about 7/8 under 512 samples");
					check(ev_sum / ev_n >= 230 && ev_sum / ev_n <= 345, "mean length near 286");
				end else begin
					check(ev_min >= 128 && ev_max <= 2032, "length within 128-2032");
					check(hist[0] == 0 && hist[1] * 100 > ev_n * 40 && hist[1] * 100 < ev_n * 60, "none under 128, about half under 256");
					check(ev_sum / ev_n >= 400 && ev_sum / ev_n <= 560, "mean length near 480");
				end
				if (ev_n >= 2000) check(reach_n * 1000 >= ev_n * 8, "the longest events still reach the next hsync (>= 0.8%)");
			end
		end else begin
			$display("  creases: %0d", cr_n);
			if (cr_n > 0) begin
				$display("  first line: %0d-%0d, %0d distinct  (design: 40-167)", cv_min, cv_max, count_seen_v());
				$display("  heights: %0d distinct  (design: 4-11)", count_seen_l());
				$display("  durations: %0d distinct  (design: 48/64/80/96 fields)", count_seen_f());
				$display("  streak length: %0d-%0d samples  (design: 64-2032)", cr_len_min, cr_len_max);
			end
			check(cr_n >= 15, "enough creases to judge (>= 15)");
			if (cr_n >= 15) begin
				check(count_seen_v() >= 10 && (cv_max - cv_min) >= 80, "crease position varies over 40-167");
				check(count_seen_l() >= 5, "crease height varies over 4-11");
				check(count_seen_f() >= 3, "crease duration varies over 48-96 fields");
				check(cr_len_min < 128 && cr_len_max >= 256, "crease streak length varies");
			end
		end
	end
end

endmodule

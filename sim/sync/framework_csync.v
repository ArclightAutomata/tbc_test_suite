// SPDX-License-Identifier: GPL-2.0-or-later
// From the MiSTer framework (Template_MiSTer sys/sys_top.v),
// (c) Alexey Melnikov and contributors.
// Verbatim copy of the framework's csync module (sys/sys_top.v) - the
// composite sync the IO board's sync-on-green receives - renamed so it
// can be simulated on its own.
module framework_csync
(
	input  clk,
	input  hsync,
	input  vsync,

	output csync
);

assign csync = (csync_vs ^ csync_hs);

reg csync_hs, csync_vs;
always @(posedge clk) begin
	reg prev_hs;
	reg [15:0] h_cnt, line_len, hs_len;

	// Count line/Hsync length
	h_cnt <= h_cnt + 1'd1;

	prev_hs <= hsync;
	if (prev_hs ^ hsync) begin
		h_cnt <= 0;
		if (hsync) begin
			line_len <= h_cnt - hs_len;
			csync_hs <= 0;
		end
		else hs_len <= h_cnt;
	end
	
	if (~vsync) csync_hs <= hsync;
	else if(h_cnt == line_len) csync_hs <= 1;
	
	csync_vs <= vsync;
end

endmodule

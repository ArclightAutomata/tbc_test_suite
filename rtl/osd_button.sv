// SPDX-License-Identifier: GPL-2.0-or-later
// Joystick Button B -> virtual OSD button.
//
// Button B closes the test and reopens the OSD by pressing the virtual
// OSD button (BUTTONS[0]). That line reaches the ARM through the gp_in
// register, which Main_MiSTer polls in software about once per
// millisecond - so a one-clock pulse (17 ns) is essentially never seen.
// Instead the button is held down from the B press until the OSD
// actually opens, with a timeout so it can never stick if the ARM does
// not respond. A new press needs a new B edge, so holding B across the
// OSD closing does not re-trigger.
module osd_button #(
	parameter [23:0] TIMEOUT = 24'd14318182   // 250 ms at 57.272727 MHz
) (
	input      clk,
	input      osd_open,   // OSD_STATUS
	input      btn,        // joystick Button B
	output reg press       // -> BUTTONS[0]
);

reg        btn_prev = 1'b0;
reg [23:0] cnt = 24'd0;

initial press = 1'b0;

always @(posedge clk) begin
	btn_prev <= btn;
	if (press) begin
		cnt <= cnt + 24'd1;
		if (osd_open || cnt == TIMEOUT) press <= 1'b0;
	end else if (!osd_open && btn && !btn_prev) begin
		press <= 1'b1;
		cnt   <= 24'd0;
	end
end

endmodule

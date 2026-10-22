--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    VGA Monitor
-- Module Name:    vga_monitor
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Watches the VGA pins the way a monitor would and checks
--                 640x480 at 60 Hz timing independently of the design:
--                 it locks onto the falling edges of the syncs (hsync
--                 falls at h = 656, vsync falls at the start of line 490)
--                 and from then on checks, on every pixel clock, that
--                 hsync is low exactly for h = 656..751, vsync exactly for
--                 lines 490..491, and color is zero outside 640x480.
--                 It outputs the screen position of the pixel on the pins
--                 (hpos_o, vpos_o, visible_o) so a testbench can check
--                 pixel values, and counts whole frames.
--                 If DUMP_FRAME > 0, frame number DUMP_FRAME (counting
--                 from 1 after lock) is written to DUMP_FILE as a binary
--                 PPM (640x480, colors scaled from OUT_BITS to 8 bits).
--                 Sampling is on the falling pixel clock edge, half a
--                 cycle after the design's output registers change.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 std.textio
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

entity vga_monitor is
	generic(
		OUT_BITS: positive := 4;
		DUMP_FRAME: natural := 0; -- Frame to save as PPM, 0 = none
		DUMP_FILE: string := "frame.ppm"
	);
	port(
		clk_pix_i: in std_logic;
		r_i: in std_logic_vector(OUT_BITS - 1 downto 0);
		g_i: in std_logic_vector(OUT_BITS - 1 downto 0);
		b_i: in std_logic_vector(OUT_BITS - 1 downto 0);
		hs_i: in std_logic;
		vs_i: in std_logic;
		locked_o: out boolean; -- Position known
		hpos_o: out natural; -- 0..799 of the pixel now on the pins
		vpos_o: out natural; -- 0..524
		visible_o: out boolean; -- Inside 640x480
		sample_o: out boolean; -- Toggles on every sampled pixel
		frames_o: out natural; -- Whole frames seen since lock
		errors_o: out natural -- Timing errors
	);
end vga_monitor;

architecture arch of vga_monitor is
	type char_file_t is file of character;
	constant PPM_HEADER: string := "P6" & LF & "640 480" & LF & "255" & LF;
begin
	process
		variable h, v: natural := 0;
		variable locked_h, locked_v: boolean := false;
		variable hs_old, vs_old: std_logic := '1';
		variable errs: natural := 0;
		variable frames: natural := 0;
		variable toggle: boolean := false;
		file ppm: char_file_t;
		variable dumping: boolean := false;

		procedure err(msg: string) is
		begin
			errs := errs + 1;
			if (errs <= 10) then
				report "VGA monitor: " & msg & " at h=" & integer'image(h) & " v=" &
					integer'image(v) severity error;
			end if;
		end procedure;

		function scale(c: std_logic_vector) return character is
		begin
			return character'val(to_integer(unsigned(c)) * 255 / (2 ** OUT_BITS - 1));
		end function;
	begin
		wait until falling_edge(clk_pix_i);
		-- Advance the position by one pixel
		if (h = 799) then
			h := 0;
			if (v = 524) then
				v := 0;
			else
				v := v + 1;
			end if;
			if (locked_v and (v = 0)) then
				frames := frames + 1;
				if (dumping) then
					file_close(ppm);
					dumping := false;
				end if;
				if ((DUMP_FRAME > 0) and (frames = DUMP_FRAME)) then
					file_open(ppm, DUMP_FILE, write_mode);
					for c in PPM_HEADER'range loop
						write(ppm, PPM_HEADER(c));
					end loop;
					dumping := true;
				end if;
			end if;
		else
			h := h + 1;
		end if;

		-- Lock onto the sync edges (640 x 480 timing: hsync falls at h = 640 + 16 front
		-- porch, vsync at v = 480 + 10)
		if ((hs_old = '1') and (hs_i = '0')) then
			if (locked_h and (h /= 656)) then
				err("hsync fell early or late");
			end if;
			h := 656;
			locked_h := true;
		end if;
		if ((vs_old = '1') and (vs_i = '0')) then
			if (locked_v and ((v /= 490) or (h /= 0))) then
				err("vsync fell early or late");
			end if;
			v := 490;
			if (locked_h) then
				locked_v := true;
			end if;
		end if;
		hs_old := hs_i;
		vs_old := vs_i;

		-- Check sync widths and blanking
		if (locked_v) then
			if ((hs_i = '0') /= ((h >= 656) and (h < 752))) then
				err("hsync level wrong");
			end if;
			if ((vs_i = '0') /= ((v >= 490) and (v < 492))) then
				err("vsync level wrong");
			end if;
			if (((h >= 640) or (v >= 480)) and
				((unsigned(r_i) /= 0) or (unsigned(g_i) /= 0) or (unsigned(b_i) /= 0))) then
				err("color not zero during blanking");
			end if;
			if (dumping and (h < 640) and (v < 480)) then
				write(ppm, scale(r_i));
				write(ppm, scale(g_i));
				write(ppm, scale(b_i));
			end if;
		end if;

		toggle := not toggle;
		locked_o <= locked_v;
		hpos_o <= h;
		vpos_o <= v;
		visible_o <= locked_v and (h < 640) and (v < 480);
		sample_o <= toggle;
		frames_o <= frames;
		errors_o <= errs;
	end process;
end arch;

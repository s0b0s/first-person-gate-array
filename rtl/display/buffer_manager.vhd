--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Buffer Manager
-- Module Name:    buffer_manager
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Double buffering with a late frame start: the display
--                 shows front_o while the renderer draws back_o.
--                   BUF_WAIT_START  pulse frame_start_o at start_line_i
--                   BUF_RENDERING   until frame_done_i
--                   BUF_DONE        swap at the next vblank
--                 A frame not done by vblank keeps the old front buffer
--                 one more refresh (no tearing), counts as late, and
--                 swaps at the next vblank. frame_done_i in the vblank
--                 cycle counts as in time.
--                 Lines come from the line fetcher (line r is fetched at
--                 scanline 2(r - 1)): start line 115 = scanline 228,
--                 about 8 ms before the swap at scanline 480.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - One-process state machine
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity buffer_manager is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		vblank_i: in std_logic; -- Pulse: start of vertical blanking
		line_start_i: in std_logic; -- Pulse: a line fetch started
		line_i: in std_logic_vector(7 downto 0); -- Line being fetched
		start_line_i: in std_logic_vector(7 downto 0); -- Frame start line (115)
		frame_done_i: in std_logic; -- Pulse: renderer finished the back buffer
		frame_start_o: out std_logic; -- Pulse: start the next frame
		front_o: out std_logic; -- Buffer the display shows
		back_o: out std_logic; -- Buffer the renderer draws
		rendering_o: out std_logic; -- A frame is being drawn
		frame_count_o: out std_logic_vector(15 downto 0); -- Swaps since reset
		late_count_o: out std_logic_vector(15 downto 0) -- Refreshes shown twice
	);
end buffer_manager;

architecture arch of buffer_manager is
	type buf_state_type is (BUF_WAIT_START, BUF_RENDERING, BUF_DONE);
	signal buf_state: buf_state_type := BUF_WAIT_START;
	signal front: std_logic := '0';
	signal frame_count: unsigned(15 downto 0) := (others => '0');
	signal late_count: unsigned(15 downto 0) := (others => '0');
	signal frame_start: std_logic := '0';
begin
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			buf_state <= BUF_WAIT_START;
			front <= '0';
			frame_start <= '0';
			frame_count <= (others => '0');
			late_count <= (others => '0');
		elsif rising_edge(clk_i) then
			frame_start <= '0'; -- One-cycle pulse
			case buf_state is
				when BUF_WAIT_START =>
					if ((line_start_i = '1') and (line_i = start_line_i)) then
						frame_start <= '1';
						buf_state <= BUF_RENDERING;
					end if;
				when BUF_RENDERING =>
					if (vblank_i = '1') then
						if (frame_done_i = '1') then
							-- Done in the same cycle as vblank: still in time
							front <= not front;
							frame_count <= frame_count + 1;
							buf_state <= BUF_WAIT_START;
						elsif (late_count /= x"FFFF") then
							-- Not done: keep the old front buffer, count a late frame
							late_count <= late_count + 1;
						end if;
					elsif (frame_done_i = '1') then
						buf_state <= BUF_DONE;
					end if;
				when BUF_DONE =>
					if (vblank_i = '1') then
						front <= not front;
						frame_count <= frame_count + 1;
						buf_state <= BUF_WAIT_START;
					end if;
			end case;
		end if;
	end process;

	frame_start_o <= frame_start;
	front_o <= front;
	back_o <= not front;
	rendering_o <= '1' when (buf_state = BUF_RENDERING) else '0';
	frame_count_o <= std_logic_vector(frame_count);
	late_count_o <= std_logic_vector(late_count);
end arch;

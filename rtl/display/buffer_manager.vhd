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
-- Description:    Double buffering with a late frame start. The display
--                 shows front_o while the renderer draws back_o.
--                 States:
--                   WAIT_START  waiting for the display to reach
--                               start_line_i; then pulse frame_start_o
--                   RENDERING   renderer busy; frame_done_i -> DONE
--                   DONE        finished; the next vblank swaps the
--                               buffers and goes back to WAIT_START
--                 A frame that is not done by vblank keeps the old front
--                 buffer for one more refresh (no tearing) and counts a
--                 late frame; it swaps at the first vblank after it
--                 finishes. A frame_done_i in the same cycle as vblank_i
--                 counts as done in time.
--                 The display line clock is the line fetcher's
--                 line_start_i / line_i (line r is fetched while line
--                 r - 1 is shown, at scanline 2(r - 1)). With the default
--                 start line 115 the frame starts at scanline 228, about
--                 8 ms before the swap at scanline 480.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
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
	type state_t is (WAIT_START, RENDERING, DONE);
	signal state: state_t := WAIT_START;
	signal state_next: state_t;
	signal front: std_logic := '0';
	signal front_next: std_logic;
	signal start: std_logic;
	signal late: std_logic;
	signal swap: std_logic;
	signal frame_count: unsigned(15 downto 0) := (others => '0');
	signal late_count: unsigned(15 downto 0) := (others => '0');
	signal frame_start: std_logic := '0';
begin
	process(state, front, vblank_i, line_start_i, line_i, start_line_i, frame_done_i)
	begin
		state_next <= state;
		front_next <= front;
		start <= '0';
		late <= '0';
		swap <= '0';
		case state is
			when WAIT_START =>
				if ((line_start_i = '1') and (line_i = start_line_i)) then
					start <= '1';
					state_next <= RENDERING;
				end if;
			when RENDERING =>
				if (vblank_i = '1') then
					if (frame_done_i = '1') then
						swap <= '1';
						front_next <= not front;
						state_next <= WAIT_START;
					else
						late <= '1';
					end if;
				elsif (frame_done_i = '1') then
					state_next <= DONE;
				end if;
			when DONE =>
				if (vblank_i = '1') then
					swap <= '1';
					front_next <= not front;
					state_next <= WAIT_START;
				end if;
		end case;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			state <= WAIT_START;
			front <= '0';
			frame_start <= '0';
			frame_count <= (others => '0');
			late_count <= (others => '0');
		elsif rising_edge(clk_i) then
			state <= state_next;
			front <= front_next;
			frame_start <= start;
			if (swap = '1') then
				frame_count <= frame_count + 1;
			end if;
			if ((late = '1') and (late_count /= x"FFFF")) then
				late_count <= late_count + 1;
			end if;
		end if;
	end process;

	frame_start_o <= frame_start;
	front_o <= front;
	back_o <= not front;
	rendering_o <= '1' when (state = RENDERING) else '0';
	frame_count_o <= std_logic_vector(frame_count);
	late_count_o <= std_logic_vector(late_count);
end arch;

--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Buffer Manager Testbench
-- Module Name:    tb_buffer_manager
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for buffer_manager. A display
--                 process plays the line and vblank events of a frame
--                 (compressed: 10 clocks per line); a renderer process
--                 answers each frame_start with frame_done after a
--                 scripted delay. Cases: frames finishing early, exactly
--                 on the vblank cycle, one refresh late, three refreshes
--                 late, and a frame_done arriving while waiting (ignored).
--                 Checks: front changes only on vblank cycles and only
--                 after a finished frame, back is always the other buffer,
--                 one frame_start per frame, frame and late counters.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std, tb_pkg,
--                 buffer_manager
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
use work.tb_pkg.all;

entity tb_buffer_manager is
end tb_buffer_manager;

architecture arch of tb_buffer_manager is
	component buffer_manager is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			vblank_i: in std_logic;
			line_start_i: in std_logic;
			line_i: in std_logic_vector(7 downto 0);
			start_line_i: in std_logic_vector(7 downto 0);
			frame_done_i: in std_logic;
			frame_start_o: out std_logic;
			front_o: out std_logic;
			back_o: out std_logic;
			rendering_o: out std_logic;
			frame_count_o: out std_logic_vector(15 downto 0);
			late_count_o: out std_logic_vector(15 downto 0)
		);
	end component;

	constant PERIOD: time := 10 ns;
	constant LINE_CLOCKS: natural := 10;
	constant START_LINE: natural := 115;
	-- Lines in a compressed refresh: 240 fetched lines plus vblank time
	constant REFRESH_LINES: natural := 262;
	-- Render time per frame in clocks, counted from the edge that first
	-- sees frame_start. Line 115's event is followed by 124 more lines of
	-- 10 clocks, so frame_done lands exactly on the vblank cycle with
	-- 1249 clocks; 1248 is one cycle early, 1250 one cycle late.
	type delays_t is array (0 to 6) of natural;
	constant DELAYS: delays_t := (300, 1248, 1249, 1250, 1249 + 2 * REFRESH_LINES * LINE_CLOCKS + 1,
		600, 100);
	-- Expected late refreshes for each frame
	constant LATES: delays_t := (0, 0, 0, 1, 3, 0, 0);

	shared variable chk: checker_t;
	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal done: boolean := false;
	signal vblank: std_logic := '0';
	signal line_start: std_logic := '0';
	signal line: std_logic_vector(7 downto 0) := (others => '0');
	signal frame_done: std_logic := '0';
	signal frame_start: std_logic;
	signal front, back, rendering: std_logic;
	signal frame_count, late_count: std_logic_vector(15 downto 0);
	signal starts: natural := 0;
	signal refreshes: natural := 0;
begin
	dut: buffer_manager
		port map (
			clk_i => clk,
			rst_i => rst,
			vblank_i => vblank,
			line_start_i => line_start,
			line_i => line,
			start_line_i => std_logic_vector(to_unsigned(START_LINE, 8)),
			frame_done_i => frame_done,
			frame_start_o => frame_start,
			front_o => front,
			back_o => back,
			rendering_o => rendering,
			frame_count_o => frame_count,
			late_count_o => late_count
		);

	process
	begin
		if (done) then
			wait;
		end if;
		clk <= '0';
		wait for PERIOD / 2;
		clk <= '1';
		wait for PERIOD / 2;
	end process;

	process
	begin
		rst <= '1';
		wait for 10.5 * PERIOD;
		rst <= '0';
		wait;
	end process;

	-- Display: line events for lines 0..239, then vblank, forever
	process
	begin
		wait until (rst = '0');
		while (not done) loop
			for l in 0 to 239 loop
				wait until rising_edge(clk);
				line_start <= '1';
				line <= std_logic_vector(to_unsigned(l, 8));
				wait until rising_edge(clk);
				line_start <= '0';
				for i in 3 to LINE_CLOCKS loop
					wait until rising_edge(clk);
				end loop;
			end loop;
			wait until rising_edge(clk);
			vblank <= '1';
			wait until rising_edge(clk);
			vblank <= '0';
			refreshes <= refreshes + 1;
			for i in 1 to (REFRESH_LINES - 240) * LINE_CLOCKS - 2 loop
				wait until rising_edge(clk);
			end loop;
		end loop;
		wait;
	end process;

	-- Front may change only on the edge after a vblank cycle; back is
	-- always the other buffer
	process(clk)
		variable vblank_old: std_logic := '0';
		variable front_old: std_logic := '0';
	begin
		if rising_edge(clk) then
			if ((front /= front_old) and (vblank_old = '0')) then
				chk.check(false, "front changed outside vblank at " & time'image(now));
			end if;
			chk.check(back = not front, "back is not the other buffer");
			vblank_old := vblank;
			front_old := front;
			if (frame_start = '1') then
				starts <= starts + 1;
			end if;
		end if;
	end process;

	-- Renderer and checks
	process
		variable front_before: std_logic;
		variable late_before: natural;
		variable frames_before: natural;
	begin
		wait until (rst = '0');
		-- A stray frame_done while waiting for the start must be ignored
		wait until rising_edge(clk);
		frame_done <= '1';
		wait until rising_edge(clk);
		frame_done <= '0';
		for f in DELAYS'range loop
			wait until rising_edge(clk) and (frame_start = '1');
			chk.check(rendering = '1', "rendering after frame_start");
			front_before := front;
			late_before := to_integer(unsigned(late_count));
			frames_before := to_integer(unsigned(frame_count));
			for i in 1 to DELAYS(f) - 1 loop
				wait until rising_edge(clk);
			end loop;
			frame_done <= '1';
			wait until rising_edge(clk);
			frame_done <= '0';
			-- The swap happens at the next vblank (or this one)
			while (to_integer(unsigned(frame_count)) = frames_before) loop
				wait until rising_edge(clk);
			end loop;
			chk.check(front = not front_before, "frame " & integer'image(f) & " swapped");
			chk.check(to_integer(unsigned(late_count)) - late_before = LATES(f), "frame " &
				integer'image(f) & " late refreshes " &
				integer'image(to_integer(unsigned(late_count)) - late_before));
		end loop;
		-- One start per frame, none while a late frame was running
		chk.check(starts = DELAYS'length, "frame starts " & integer'image(starts));
		chk.check(to_integer(unsigned(frame_count)) = DELAYS'length, "frame count");
		done <= true;
		tb_finish("tb_buffer_manager", chk.checks, chk.errors);
		wait;
	end process;
end arch;

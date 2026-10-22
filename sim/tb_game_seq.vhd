--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Stage-1 Game Sequencer Testbench
-- Module Name:    tb_game_seq
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for game_seq against the golden
--                 trace of tools/model/game.py (sim/golden/game_trace.txt,
--                 897 frames: walking into a closed door, opening it,
--                 walking through, sliding along walls diagonally,
--                 running into a wall, strafing, backing up while
--                 turning, and the door closing again). The map is level
--                 1 (map_init_pkg) in a RAM model with one clock of read
--                 latency. Each frame: frame_start, the snapshot 2 clocks
--                 later (as ps2_input delivers it), wait for render_start,
--                 then compare position, angle, and every door entry's
--                 state, timer and open amount (x and y when active),
--                 plus the packing of doors_o.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 std.textio, tb_pkg, game_seq, game_pkg, render_types_pkg,
--                 map_init_pkg
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
use work.tb_pkg.all;
use work.game_pkg.all;
use work.render_types_pkg.all;
use work.map_init_pkg.all;

entity tb_game_seq is
	generic(
		TRACE_FILE: string := "../../sim/golden/game_trace.txt" -- Relative to the run directory
	);
end tb_game_seq;

architecture arch of tb_game_seq is
	component game_seq is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			load_i: in std_logic;
			start_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			start_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			start_angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			frame_start_i: in std_logic;
			snapshot_i: in std_logic_vector(SNAP_BITS - 1 downto 0);
			snapshot_valid_i: in std_logic;
			map_addr_o: out std_logic_vector(11 downto 0);
			map_data_i: in std_logic_vector(23 downto 0);
			pos_x_o: out std_logic_vector(POS_BITS - 1 downto 0);
			pos_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
			angle_o: out std_logic_vector(ANGLE_BITS - 1 downto 0);
			eye_o: out std_logic_vector(EYE_BITS - 1 downto 0);
			doors_o: out std_logic_vector(DOORS_BITS - 1 downto 0);
			render_start_o: out std_logic;
			busy_o: out std_logic;
			door_state_o: out std_logic_vector(8 * 2 - 1 downto 0);
			door_timer_o: out std_logic_vector(8 * 8 - 1 downto 0)
		);
	end component;

	constant PERIOD: time := 10 ns;
	shared variable chk: checker_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal load: std_logic := '0';
	signal frame_start: std_logic := '0';
	signal snapshot: std_logic_vector(SNAP_BITS - 1 downto 0) := (others => '0');
	signal snapshot_valid: std_logic := '0';
	signal map_addr: std_logic_vector(11 downto 0);
	signal map_data: std_logic_vector(23 downto 0) := (others => '0');
	signal pos_x, pos_y: std_logic_vector(POS_BITS - 1 downto 0);
	signal angle: std_logic_vector(ANGLE_BITS - 1 downto 0);
	signal eye: std_logic_vector(EYE_BITS - 1 downto 0);
	signal doors: std_logic_vector(DOORS_BITS - 1 downto 0);
	signal render_start, busy: std_logic;
	signal door_state: std_logic_vector(15 downto 0);
	signal door_timer: std_logic_vector(63 downto 0);
begin
	dut: game_seq
		port map (
			clk_i => clk,
			rst_i => rst,
			load_i => load,
			start_x_i => std_logic_vector(to_unsigned(622592, POS_BITS)),
			start_y_i => std_logic_vector(to_unsigned(557056, POS_BITS)),
			start_angle_i => (others => '0'),
			frame_start_i => frame_start,
			snapshot_i => snapshot,
			snapshot_valid_i => snapshot_valid,
			map_addr_o => map_addr,
			map_data_i => map_data,
			pos_x_o => pos_x,
			pos_y_o => pos_y,
			angle_o => angle,
			eye_o => eye,
			doors_o => doors,
			render_start_o => render_start,
			busy_o => busy,
			door_state_o => door_state,
			door_timer_o => door_timer
		);

	-- Level 1 map, one clock of read latency like the BRAM
	process(clk)
	begin
		if rising_edge(clk) then
			map_data <= LEVEL1_TILES(to_integer(unsigned(map_addr)));
		end if;
	end process;

	process
	begin
		if (finished) then
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

	process
		file f: text open read_mode is TRACE_FILE;
		variable l: line;
		variable snap: std_logic_vector(SNAP_BITS - 1 downto 0);
		variable want_x, want_y, want_a: integer;
		variable dx, dy, dopen, dstate, dtimer: integer;
		variable frames, bad, cycles: natural := 0;
		variable ok: boolean;
		variable base: natural;
	begin
		readline(f, l); -- Header
		wait until (rst = '0');
		wait until rising_edge(clk);
		load <= '1';
		wait until rising_edge(clk);
		load <= '0';
		wait until rising_edge(clk);
		while not endfile(f) loop
			-- Trace line: snapshot (hex), x, y, angle, then x y open state timer of 8 doors
			readline(f, l);
			hread(l, snap);
			read(l, want_x);
			read(l, want_y);
			read(l, want_a);
			-- One frame: frame start, snapshot 2 clocks later
			frame_start <= '1';
			wait until rising_edge(clk);
			frame_start <= '0';
			wait until rising_edge(clk);
			snapshot <= snap;
			snapshot_valid <= '1';
			wait until rising_edge(clk);
			snapshot_valid <= '0';
			cycles := 0;
			loop
				wait until rising_edge(clk);
				cycles := cycles + 1;
				exit when (render_start = '1') or (cycles > 1000);
			end loop;
			frames := frames + 1;
			ok := (render_start = '1') and (to_integer(unsigned(pos_x)) = want_x) and
				(to_integer(unsigned(pos_y)) = want_y) and (to_integer(unsigned(angle)) = want_a) and
				(to_integer(unsigned(eye)) = 32);
			for j in 0 to 7 loop
				read(l, dx);
				read(l, dy);
				read(l, dopen);
				read(l, dstate);
				read(l, dtimer);
				base := DOOR_BITS * j;
				if (to_integer(unsigned(door_state(2 * j + 1 downto 2 * j))) /= dstate) or
					(to_integer(unsigned(door_timer(8 * j + 7 downto 8 * j))) /= dtimer) then
					ok := false;
				end if;
				if (dstate /= 0) then
					if (to_integer(unsigned(doors(base + DOOR_X_HI downto base + DOOR_X_LO))) /= dx) or
						(to_integer(unsigned(doors(base + DOOR_Y_HI downto base + DOOR_Y_LO))) /= dy) or
						(to_integer(unsigned(doors(base + DOOR_OPEN_HI downto base + DOOR_OPEN_LO))) /= dopen) then
						ok := false;
					end if;
				elsif (unsigned(doors(base + DOOR_BITS - 1 downto base)) /= 0) or (dopen /= 0) then
					ok := false;
				end if;
			end loop;
			if (not ok) then
				bad := bad + 1;
				if (bad <= 5) then
					report "frame " & integer'image(frames) & ": got x=" &
						integer'image(to_integer(unsigned(pos_x))) & " y=" &
						integer'image(to_integer(unsigned(pos_y))) & " a=" &
						integer'image(to_integer(unsigned(angle))) & " doors " & to_hex(doors) &
						" states " & to_hex(door_state) & " timers " & to_hex(door_timer) &
						"; want x=" & integer'image(want_x) & " y=" & integer'image(want_y) &
						" a=" & integer'image(want_a) severity error;
				end if;
			end if;
			chk.check(busy = '0', "idle after render_start");
			-- Gap between frames
			for k in 1 to 5 loop
				wait until rising_edge(clk);
			end loop;
		end loop;
		chk.check(bad = 0, integer'image(bad) & " of " & integer'image(frames) & " frames differ");
		chk.check(frames = 897, "frames in the trace: " & integer'image(frames));
		finished <= true;
		tb_finish("tb_game_seq", chk.checks, chk.errors);
		wait;
	end process;
end arch;

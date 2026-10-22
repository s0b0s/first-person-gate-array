--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Replay Unit Testbench
-- Module Name:    tb_replay_unit
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for replay_unit with a
--                 behavioral SRAM master port (grants after a random 0..5
--                 clock delay, read data 4 clocks after the grant, in
--                 order). Frames are 400 clocks apart; the game-state CRC
--                 comes 150 clocks after each frame tick.
--                 1. Pass-through: every snapshot comes out unchanged one
--                    clock later.
--                 2. Record 25 frames: pass-through output, and the SRAM
--                    holds each snapshot at REPLAY_BASE + 5 k and each CRC
--                    at 0x75800 + 4 k (little endian); frames_o = 25.
--                 3. Play: the input is ignored; frame k's recorded
--                    snapshot comes out one clock after the tick, all 25,
--                    and the CRCs are written again.
--                 4. Play started on the same clock as a tick: frame 0 is
--                    late (prefetch still running) but arrives within 60
--                    clocks and the rest follow in order.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, tb_pkg, replay_unit, hw_pkg, game_pkg
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
use IEEE.math_real.all;
use work.tb_pkg.all;
use work.hw_pkg.all;
use work.game_pkg.all;

entity tb_replay_unit is
end tb_replay_unit;

architecture arch of tb_replay_unit is
	component replay_unit is
		generic(
			MAX_FRAMES: positive := 3600
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			mode_i: in std_logic_vector(1 downto 0);
			frames_o: out std_logic_vector(15 downto 0);
			snap_in_i: in std_logic_vector(SNAP_BITS - 1 downto 0);
			snap_in_valid_i: in std_logic;
			snap_out_o: out std_logic_vector(SNAP_BITS - 1 downto 0);
			snap_out_valid_o: out std_logic;
			crc_i: in std_logic_vector(31 downto 0);
			crc_valid_i: in std_logic;
			m_req_o: out std_logic;
			m_we_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_wdata_o: out std_logic_vector(7 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0)
		);
	end component;

	constant PERIOD: time := 10 ns;
	constant N_FRAMES: natural := 25;
	constant CRC_BASE: natural := 16#75800#;
	type mem_t is array (0 to 2 ** 19 - 1) of integer range -1 to 255;
	type snaps_t is array (0 to N_FRAMES - 1) of std_logic_vector(SNAP_BITS - 1 downto 0);
	type crcs_t is array (0 to N_FRAMES - 1) of std_logic_vector(31 downto 0);
	shared variable chk: checker_t;

	-- SRAM contents, written by the port model, read by the checks
	type sram_t is protected
		procedure write(a: natural; d: natural);
		impure function read(a: natural) return integer;
	end protected sram_t;
	type sram_t is protected body
		variable mem: mem_t := (others => -1);
		procedure write(a: natural; d: natural) is
		begin
			mem(a) := d;
		end procedure;
		impure function read(a: natural) return integer is
		begin
			return mem(a);
		end function;
	end protected body sram_t;
	shared variable sram: sram_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal mode: std_logic_vector(1 downto 0) := "00";
	signal frames: std_logic_vector(15 downto 0);
	signal snap_in: std_logic_vector(SNAP_BITS - 1 downto 0) := (others => '0');
	signal snap_in_valid: std_logic := '0';
	signal snap_out: std_logic_vector(SNAP_BITS - 1 downto 0);
	signal snap_out_valid: std_logic;
	signal crc: std_logic_vector(31 downto 0) := (others => '0');
	signal crc_valid: std_logic := '0';
	signal m_req, m_we, m_gnt, m_rvalid: std_logic := '0';
	signal m_addr: std_logic_vector(18 downto 0);
	signal m_wdata, m_rdata: std_logic_vector(7 downto 0) := (others => '0');
begin
	dut: replay_unit
		port map (
			clk_i => clk,
			rst_i => rst,
			mode_i => mode,
			frames_o => frames,
			snap_in_i => snap_in,
			snap_in_valid_i => snap_in_valid,
			snap_out_o => snap_out,
			snap_out_valid_o => snap_out_valid,
			crc_i => crc,
			crc_valid_i => crc_valid,
			m_req_o => m_req,
			m_we_o => m_we,
			m_addr_o => m_addr,
			m_wdata_o => m_wdata,
			m_gnt_i => m_gnt,
			m_rvalid_i => m_rvalid,
			m_rdata_i => m_rdata
		);

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

	-- Behavioral SRAM master port: grant after 0..5 clocks, read data 4
	-- clocks after the grant
	process(clk)
		variable s1, s2: positive := 29;
		variable r: real;
		variable wait_left: integer := -1;
		type pipe_t is array (0 to 3) of integer;
		variable pipe: pipe_t := (others => -1);
		variable d: integer;
	begin
		if rising_edge(clk) then
			-- Read return pipeline
			m_rvalid <= '0';
			if (pipe(3) >= 0) then
				m_rvalid <= '1';
				m_rdata <= std_logic_vector(to_unsigned(pipe(3), 8));
			end if;
			pipe(1 to 3) := pipe(0 to 2);
			pipe(0) := -1;
			if ((m_gnt = '1') and (m_req = '1')) then
				if (m_we = '1') then
					sram.write(to_integer(unsigned(m_addr)), to_integer(unsigned(m_wdata)));
				else
					d := sram.read(to_integer(unsigned(m_addr)));
					if (d < 0) then
						d := 0;
					end if;
					pipe(0) := d;
				end if;
			end if;
			m_gnt <= '0';
			if ((m_req = '1') and (m_gnt = '0')) then
				if (wait_left < 0) then
					uniform(s1, s2, r);
					wait_left := integer(trunc(r * 6.0));
				end if;
				if (wait_left = 0) then
					m_gnt <= '1';
					wait_left := -1;
				else
					wait_left := wait_left - 1;
				end if;
			end if;
		end if;
	end process;

	process
		variable s1, s2: positive := 5;
		variable rr: real;
		variable snaps: snaps_t;
		variable crcs: crcs_t;
		variable v: std_logic_vector(SNAP_BITS - 1 downto 0);
		variable w: std_logic_vector(31 downto 0);
		variable n, late: natural;

		impure function random_vec(bits: natural) return std_logic_vector is
			variable x: std_logic_vector(bits - 1 downto 0);
		begin
			for i in 0 to bits - 1 loop
				uniform(s1, s2, rr);
				if (rr < 0.5) then
					x(i) := '0';
				else
					x(i) := '1';
				end if;
			end loop;
			return x;
		end function;

		-- One frame: tick with snapshot s, then the CRC 150 clocks later;
		-- returns the snapshot that came out and the clocks it took
		procedure frame(s: std_logic_vector; c: std_logic_vector; got: out std_logic_vector;
			delay: out natural) is
			variable seen: boolean := false;
		begin
			snap_in <= s;
			snap_in_valid <= '1';
			wait until rising_edge(clk);
			snap_in_valid <= '0';
			delay := 0;
			for i in 1 to 400 loop
				wait until rising_edge(clk);
				if ((snap_out_valid = '1') and (not seen)) then
					seen := true;
					got := snap_out;
					delay := i;
				elsif (snap_out_valid = '1') then
					chk.check(false, "two snapshots in one frame");
				end if;
				if (i = 150) then
					crc <= c;
					crc_valid <= '1';
				elsif (i = 151) then
					crc_valid <= '0';
				end if;
			end loop;
			chk.check(seen, "a snapshot every frame");
		end procedure;
	begin
		for k in 0 to N_FRAMES - 1 loop
			snaps(k) := random_vec(SNAP_BITS);
			crcs(k) := random_vec(32);
		end loop;
		wait until (rst = '0');
		wait until rising_edge(clk);

		-- 1. Pass-through
		for k in 0 to 9 loop
			frame(random_vec(SNAP_BITS), random_vec(32), v, n);
			chk.check(v = snap_in, "pass-through snapshot " & integer'image(k));
			chk.check(n = 1, "pass-through delay " & integer'image(n));
		end loop;
		chk.check(sram.read(REPLAY_BASE) = -1, "pass-through writes nothing");

		-- 2. Record
		mode <= "01";
		wait until rising_edge(clk);
		for k in 0 to N_FRAMES - 1 loop
			frame(snaps(k), crcs(k), v, n);
			chk.check(v = snaps(k), "record passes snapshot " & integer'image(k) & " through");
		end loop;
		chk.check(unsigned(frames) = N_FRAMES, "frames recorded " & integer'image(to_integer(unsigned(frames))));
		-- 5 bytes per snapshot and 4 per CRC, least significant byte first
		for k in 0 to N_FRAMES - 1 loop
			for b in 0 to 4 loop
				chk.check(sram.read(REPLAY_BASE + 5 * k + b) = to_integer(unsigned(snaps(k)(8 * b + 7 downto 8 * b))),
					"recorded snapshot " & integer'image(k) & " byte " & integer'image(b));
			end loop;
			for b in 0 to 3 loop
				chk.check(sram.read(CRC_BASE + 4 * k + b) = to_integer(unsigned(crcs(k)(8 * b + 7 downto 8 * b))),
					"recorded CRC " & integer'image(k) & " byte " & integer'image(b));
			end loop;
		end loop;

		-- 3. Play (mode set well before the first tick)
		mode <= "10";
		for i in 1 to 100 loop
			wait until rising_edge(clk);
		end loop;
		for k in 0 to N_FRAMES - 1 loop
			w := not crcs(k);
			frame(random_vec(SNAP_BITS), w, v, n);
			chk.check(v = snaps(k), "played snapshot " & integer'image(k));
			chk.check(n = 1, "played on time, frame " & integer'image(k) & " delay " & integer'image(n));
		end loop;
		chk.check(unsigned(frames) = N_FRAMES, "frames played");
		chk.check(sram.read(CRC_BASE + 4) = to_integer(unsigned(not crcs(1)(7 downto 0))),
			"play writes the CRCs again");

		-- 4. Play again, mode change on the same clock as the tick
		mode <= "00";
		frame(random_vec(SNAP_BITS), random_vec(32), v, n);
		mode <= "10";
		late := 0;
		for k in 0 to 4 loop
			frame(random_vec(SNAP_BITS), random_vec(32), v, n);
			if (k = 0) then
				late := n;
			end if;
			chk.check(v = snaps(k), "late-start played snapshot " & integer'image(k));
		end loop;
		chk.check((late > 1) and (late < 60), "late first snapshot after " & integer'image(late) & " clocks");

		finished <= true;
		tb_finish("tb_replay_unit", chk.checks, chk.errors);
		wait;
	end process;
end arch;

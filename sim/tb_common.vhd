--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Common Testbench
-- Module Name:    tb_common
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for the common blocks:
--                 synchronizer (latency, INIT value), reset_sync
--                 (asynchronous assert, release after 3 edges),
--                 pulse_sync (every pulse arrives exactly once in the
--                 slower domain) and debounce (glitches rejected, one
--                 rise pulse per press). Clock, reset and stimulus run in
--                 separate processes.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std, tb_pkg,
--                 synchronizer, reset_sync, pulse_sync, debounce
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

entity tb_common is
end tb_common;

architecture arch of tb_common is
	component synchronizer is
		generic(
			STAGES: positive := 3;
			INIT: std_logic := '0'
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			async_i: in std_logic;
			sync_o: out std_logic
		);
	end component;
	component reset_sync is
		generic(
			STAGES: positive := 3
		);
		port(
			clk_i: in std_logic;
			arst_i: in std_logic;
			rst_o: out std_logic
		);
	end component;
	component pulse_sync is
		port(
			clk_a_i: in std_logic;
			rst_a_i: in std_logic;
			pulse_i: in std_logic;
			clk_b_i: in std_logic;
			rst_b_i: in std_logic;
			pulse_o: out std_logic
		);
	end component;
	component debounce is
		generic(
			TICK_CYCLES: positive := 100;
			CNT_BITS: positive := 16
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			button_i: in std_logic;
			level_o: out std_logic;
			rise_o: out std_logic
		);
	end component;

	constant PERIOD_A: time := 10 ns; -- 100 MHz
	constant PERIOD_B: time := 40 ns; -- 25 MHz
	shared variable chk: checker_t;

	signal clk_a: std_logic := '0';
	signal clk_b: std_logic := '0';
	signal rst: std_logic := '1';
	signal done: boolean := false;

	signal din: std_logic := '0';
	signal sync0: std_logic;
	signal sync1: std_logic;
	signal arst: std_logic := '0';
	signal rst_out: std_logic;
	signal pulse_a: std_logic := '0';
	signal pulse_b: std_logic;
	signal pulses_seen: natural := 0;
	signal button: std_logic := '0';
	signal level: std_logic;
	signal rise: std_logic;
	signal rises_seen: natural := 0;
begin
	sync_zero: synchronizer
		generic map (
			STAGES => 3,
			INIT => '0'
		)
		port map (
			clk_i => clk_a,
			rst_i => rst,
			async_i => din,
			sync_o => sync0
		);

	sync_one: synchronizer
		generic map (
			STAGES => 3,
			INIT => '1'
		)
		port map (
			clk_i => clk_a,
			rst_i => rst,
			async_i => din,
			sync_o => sync1
		);

	rsync: reset_sync
		generic map (
			STAGES => 3
		)
		port map (
			clk_i => clk_a,
			arst_i => arst,
			rst_o => rst_out
		);

	psync: pulse_sync
		port map (
			clk_a_i => clk_a,
			rst_a_i => rst,
			pulse_i => pulse_a,
			clk_b_i => clk_b,
			rst_b_i => rst,
			pulse_o => pulse_b
		);

	dbnc: debounce
		generic map (
			TICK_CYCLES => 2,
			CNT_BITS => 3
		)
		port map (
			clk_i => clk_a,
			rst_i => rst,
			button_i => button,
			level_o => level,
			rise_o => rise
		);

	-- Clocks
	process
	begin
		if (done) then
			wait;
		end if;
		clk_a <= '0';
		wait for PERIOD_A / 2;
		clk_a <= '1';
		wait for PERIOD_A / 2;
	end process;

	process
	begin
		if (done) then
			wait;
		end if;
		clk_b <= '0';
		wait for PERIOD_B / 2;
		clk_b <= '1';
		wait for PERIOD_B / 2;
	end process;

	-- Reset: at least 100 ns, released between clock edges
	process
	begin
		rst <= '1';
		wait for 10.5 * PERIOD_A;
		rst <= '0';
		wait;
	end process;

	-- Event counters in the receiving domains
	process(clk_b)
	begin
		if rising_edge(clk_b) then
			if (pulse_b = '1') then
				pulses_seen <= pulses_seen + 1;
			end if;
		end if;
	end process;

	process(clk_a)
	begin
		if rising_edge(clk_a) then
			if (rise = '1') then
				rises_seen <= rises_seen + 1;
			end if;
		end if;
	end process;

	-- Stimulus and checks
	process
	begin
		wait for 1 ns;
		chk.check(sync1 = '1', "INIT='1' synchronizer holds '1' in reset");
		chk.check(rst_out = '1', "reset_sync powers up in reset");
		wait until (rst = '0');
		wait until rising_edge(clk_a);

		-- Synchronizer latency: din changes just after edge 0, sync_o
		-- follows after the third edge
		wait for 1 ns;
		din <= '1';
		for i in 1 to 2 loop
			wait until rising_edge(clk_a);
			wait for 1 ns; -- Look just after the edge, once the flops have updated
			chk.check(sync0 = '0', "synchronizer output early at edge " & integer'image(i));
		end loop;
		wait until rising_edge(clk_a);
		wait for 1 ns;
		chk.check(sync0 = '1', "synchronizer output after 3 edges");
		chk.check(sync1 = '1', "INIT='1' synchronizer passes '1'");
		din <= '0';
		for i in 1 to 3 loop
			wait until rising_edge(clk_a);
		end loop;
		wait for 1 ns;
		chk.check((sync0 = '0') and (sync1 = '0'), "synchronizers pass '0'");

		-- reset_sync: release takes 3 edges, assert is immediate
		chk.check(rst_out = '0', "reset_sync released after power-on");
		wait for 3 ns;
		arst <= '1';
		wait for 1 ns;
		chk.check(rst_out = '1', "reset_sync asserts without a clock edge");
		wait until rising_edge(clk_a);
		wait for 2 ns;
		arst <= '0';
		for i in 1 to 2 loop
			wait until rising_edge(clk_a);
			wait for 1 ns;
			chk.check(rst_out = '1', "reset_sync released early");
		end loop;
		wait until rising_edge(clk_a);
		wait for 1 ns;
		chk.check(rst_out = '0', "reset_sync released after 3 edges");

		-- pulse_sync: 20 pulses spaced 25 fast cycles apart (above the
		-- 5 slow-cycle minimum) all arrive
		for i in 1 to 20 loop
			wait until rising_edge(clk_a);
			pulse_a <= '1';
			wait until rising_edge(clk_a);
			pulse_a <= '0';
			for j in 1 to 24 loop
				wait until rising_edge(clk_a);
			end loop;
		end loop;
		wait for 10 * PERIOD_B;
		chk.check(pulses_seen = 20, "pulse_sync delivered " & integer'image(pulses_seen) &
			" of 20 pulses");

		-- Debounce: counter is 3 bits stepping every 2 clocks, so a press
		-- must hold about 16 clocks. Glitches of 4 clocks are rejected.
		for i in 1 to 5 loop
			button <= '1';
			wait for 4 * PERIOD_A;
			button <= '0';
			wait for 12 * PERIOD_A;
		end loop;
		chk.check(level = '0', "debounce rejects short glitches");
		chk.check(rises_seen = 0, "no rise pulse from glitches");
		button <= '1';
		wait for 40 * PERIOD_A;
		chk.check(level = '1', "debounce follows a held press");
		-- Bounce while held must not make a second press
		button <= '0';
		wait for 3 * PERIOD_A;
		button <= '1';
		wait for 40 * PERIOD_A;
		button <= '0';
		wait for 40 * PERIOD_A;
		chk.check(level = '0', "debounce follows the release");
		chk.check(rises_seen = 1, "one rise pulse per press, got " & integer'image(rises_seen));

		done <= true;
		tb_finish("tb_common", chk.checks, chk.errors);
		wait;
	end process;
end arch;

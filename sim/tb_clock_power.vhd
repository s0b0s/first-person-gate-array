--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Clock Power Testbench
-- Module Name:    tb_clock_power
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for clock_reset (the real
--                 MMCME2_BASE simulation model) and power_gate:
--                 - clk_sys, clk_pix and clk_sram_rd periods, and the
--                   phase of clk_sram_rd (about 1.04 ns after clk_sys)
--                 - both resets stay high until lock, release on a rising
--                   edge of their own clock, and re-assert at once on
--                   btn_rst
--                 - pcb_on turns on only after PWR_SENSE has been high
--                   for HOLD_CYCLES (shortened to 200), ignores shorter
--                   pulses, and turns off within 4 cycles of a drop.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std, tb_pkg,
--                 clock_reset, power_gate
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

entity tb_clock_power is
end tb_clock_power;

architecture arch of tb_clock_power is
	component clock_reset is
		generic(
			MULT_F: real := 50.0
		);
		port(
			clk12_i: in std_logic;
			btn_rst_i: in std_logic;
			clk_sys_o: out std_logic;
			clk_pix_o: out std_logic;
			clk_sram_rd_o: out std_logic;
			rst_sys_o: out std_logic;
			rst_pix_o: out std_logic;
			locked_o: out std_logic
		);
	end component;
	component power_gate is
		generic(
			HOLD_CYCLES: positive := 1_000_000
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			pwr_sense_i: in std_logic;
			pcb_on_o: out std_logic
		);
	end component;

	constant PERIOD_12: time := 83.333 ns;
	constant HOLD: positive := 200;
	shared variable chk: checker_t;

	signal clk12: std_logic := '0';
	signal btn_rst: std_logic := '0';
	signal clk_sys: std_logic;
	signal clk_pix: std_logic;
	signal clk_rd: std_logic;
	signal rst_sys: std_logic;
	signal rst_pix: std_logic;
	signal locked: std_logic;
	signal pwr_sense: std_logic := '0';
	signal pcb_on: std_logic;
	signal done: boolean := false;
begin
	dut_clk: clock_reset
		port map (
			clk12_i => clk12,
			btn_rst_i => btn_rst,
			clk_sys_o => clk_sys,
			clk_pix_o => clk_pix,
			clk_sram_rd_o => clk_rd,
			rst_sys_o => rst_sys,
			rst_pix_o => rst_pix,
			locked_o => locked
		);

	dut_gate: power_gate
		generic map (
			HOLD_CYCLES => HOLD
		)
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			pwr_sense_i => pwr_sense,
			pcb_on_o => pcb_on
		);

	-- 12 MHz oscillator
	process
	begin
		if (done) then
			wait;
		end if;
		clk12 <= '0';
		wait for PERIOD_12 / 2;
		clk12 <= '1';
		wait for PERIOD_12 / 2;
	end process;

	-- Reset: this design has no external reset; the MMCM lock is the
	-- reset. The process checks that both resets hold until lock.
	process
	begin
		wait for 1 ns;
		chk.check((rst_sys = '1') and (rst_pix = '1'), "resets high at power-on");
		wait until (locked = '1');
		chk.check((rst_sys = '1') and (rst_pix = '1'), "resets still high at lock");
		wait until falling_edge(rst_sys);
		chk.check(clk_sys = '1', "rst_sys released on a clk_sys rising edge");
		wait;
	end process;

	process
	begin
		wait until falling_edge(rst_pix);
		chk.check(clk_pix = '1', "rst_pix released on a clk_pix rising edge");
		wait;
	end process;

	-- Stimulus and checks
	process
		variable t0, t1, t_rd: time;
	begin
		wait until (rst_sys = '0') and (rst_pix = '0');
		wait for 1 us;

		-- Periods: average over 100 cycles to see past the edge resolution
		wait until rising_edge(clk_sys);
		t0 := now;
		for i in 1 to 100 loop
			wait until rising_edge(clk_sys);
		end loop;
		t1 := now;
		chk.check(abs ((t1 - t0) / 100 - 10 ns) < 10 ps, "clk_sys period " &
			time'image((t1 - t0) / 100));
		wait until rising_edge(clk_pix);
		t0 := now;
		for i in 1 to 100 loop
			wait until rising_edge(clk_pix);
		end loop;
		t1 := now;
		chk.check(abs ((t1 - t0) / 100 - 40 ns) < 10 ps, "clk_pix period " &
			time'image((t1 - t0) / 100));

		-- clk_sram_rd: same period, rising edge about 1.04 ns after clk_sys.
		-- The MMCM model rounds single edges to whole picoseconds of a
		-- 1.6667 ns VCO, so single edges wander by tens of ps; the period
		-- is averaged over 100 cycles.
		wait until rising_edge(clk_sys);
		t0 := now;
		wait until rising_edge(clk_rd);
		t_rd := now - t0;
		chk.check((t_rd > 0.95 ns) and (t_rd < 1.15 ns), "clk_sram_rd lag " &
			time'image(t_rd));
		t0 := now;
		for i in 1 to 100 loop
			wait until rising_edge(clk_rd);
		end loop;
		t1 := now;
		chk.check(abs ((t1 - t0) / 100 - 10 ns) < 10 ps, "clk_sram_rd period " &
			time'image((t1 - t0) / 100));

		-- PWR_SENSE: a pulse shorter than HOLD does nothing
		wait until rising_edge(clk_sys);
		wait for 2 ns;
		pwr_sense <= '1';
		wait for (HOLD / 2) * 10 ns;
		pwr_sense <= '0';
		wait for (HOLD + 20) * 10 ns;
		chk.check(pcb_on = '0', "short PWR_SENSE pulse ignored");

		-- Held high: on after about HOLD + 4 cycles, not before HOLD
		pwr_sense <= '1';
		wait for (HOLD - 5) * 10 ns;
		chk.check(pcb_on = '0', "pcb_on not before HOLD cycles");
		wait for 20 * 10 ns;
		chk.check(pcb_on = '1', "pcb_on after HOLD cycles");

		-- Drop: off within 4 clocks (3 synchronizer stages + output)
		pwr_sense <= '0';
		wait for 45 ns;
		chk.check(pcb_on = '0', "pcb_on drops within 4 cycles");

		-- Manual reset re-asserts both resets without waiting for a clock
		btn_rst <= '1';
		wait for 1 ns;
		chk.check((rst_sys = '1') and (rst_pix = '1'), "btn_rst asserts resets at once");
		wait for 200 ns;
		btn_rst <= '0';
		wait for 200 ns;
		chk.check((rst_sys = '0') and (rst_pix = '0'), "resets release after btn_rst");

		done <= true;
		tb_finish("tb_clock_power", chk.checks, chk.errors);
		wait;
	end process;
end arch;

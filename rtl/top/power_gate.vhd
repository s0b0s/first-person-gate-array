--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    PWR_SENSE Gate
-- Module Name:    power_gate
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    PWR_SENSE gate. PWR_SENSE (DIP 34) reads the carrier
--                 PCB's 3.3 V
--                 net. pcb_on_o goes '1' only after the synchronized input
--                 has been '1' for HOLD_CYCLES clocks in a row (1,000,000
--                 = 10 ms at 100 MHz) and drops to '0' on the first clock
--                 that sees it '0'. While pcb_on_o is '0' the top level
--                 keeps every PCB-facing output high-impedance, because
--                 the Pmod VGA buffers must not be driven while unpowered.
--                 Clock domain: clk_i (system). Latency: 3 cycles
--                 (synchronizer) plus 1 to turn off; 3 + HOLD_CYCLES + 1
--                 to turn on.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 synchronizer
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
use work.hw_pkg.all;

entity power_gate is
	generic(
		HOLD_CYCLES: positive := 1_000_000 -- Clocks PWR_SENSE must stay high
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		pwr_sense_i: in std_logic; -- Raw PWR_SENSE pin (PULLDOWN in the XDC)
		pcb_on_o: out std_logic -- '1' when PCB outputs may be driven
	);
end power_gate;

architecture arch of power_gate is
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
	constant CNT_BITS: natural := bits_for(HOLD_CYCLES);
	signal sense: std_logic;
	signal count: unsigned(CNT_BITS - 1 downto 0) := (others => '0');
	signal count_next: unsigned(CNT_BITS - 1 downto 0);
	signal pcb_on: std_logic := '0';
	signal pcb_on_next: std_logic;
begin
	sync_sense: synchronizer
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			async_i => pwr_sense_i,
			sync_o => sense
		);

	-- Count how long the sense line has been high; any low sample
	-- restarts the count and switches the PCB off.
	process(sense, count)
	begin
		if (sense = '0') then
			count_next <= (others => '0');
			pcb_on_next <= '0';
		elsif (count = HOLD_CYCLES) then
			count_next <= count;
			pcb_on_next <= '1';
		else
			count_next <= count + 1;
			pcb_on_next <= '0';
		end if;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			count <= (others => '0');
			pcb_on <= '0';
		elsif rising_edge(clk_i) then
			count <= count_next;
			pcb_on <= pcb_on_next;
		end if;
	end process;

	pcb_on_o <= pcb_on;
end arch;

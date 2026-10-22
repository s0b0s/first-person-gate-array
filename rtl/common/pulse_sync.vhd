--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Pulse Synchronizer
-- Module Name:    pulse_sync
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Carries single-cycle event pulses from clock domain A to
--                 clock domain B (a toggle: a two-phase handshake without
--                 the acknowledge, fine when pulses are far apart). Each
--                 pulse_i flips a toggle flip-flop in domain A; domain B
--                 passes the toggle through a 3-stage synchronizer and
--                 one more flip-flop, and pulse_o is high for one clk_b_i
--                 cycle whenever the last two differ (a 4-stage edge
--                 detector).
--                 Clock domains: clk_a_i (input side), clk_b_i (output).
--                 Latency: 1 clk_a_i cycle plus 3 to 4 clk_b_i cycles.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, synchronizer
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 Pulses must be at least 5 clk_b_i cycles apart or they
--                 merge (two flips cancel). The display uses it for line
--                 and frame events, which are thousands of cycles apart.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;

entity pulse_sync is
	port(
		clk_a_i: in std_logic; -- Source clock
		rst_a_i: in std_logic; -- Source-domain reset
		pulse_i: in std_logic; -- One-cycle event in the source domain
		clk_b_i: in std_logic; -- Destination clock
		rst_b_i: in std_logic; -- Destination-domain reset
		pulse_o: out std_logic -- One-cycle event in the destination domain
	);
end pulse_sync;

architecture arch of pulse_sync is
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
	signal toggle_a: std_logic := '0';
	signal toggle_b: std_logic;
	signal toggle_b_old: std_logic := '0';
begin
	process(clk_a_i, rst_a_i)
	begin
		if (rst_a_i = '1') then
			toggle_a <= '0';
		elsif rising_edge(clk_a_i) then
			if (pulse_i = '1') then
				toggle_a <= not toggle_a;
			end if;
		end if;
	end process;

	sync_toggle: synchronizer
		port map (
			clk_i => clk_b_i,
			rst_i => rst_b_i,
			async_i => toggle_a,
			sync_o => toggle_b
		);

	process(clk_b_i, rst_b_i)
	begin
		if (rst_b_i = '1') then
			toggle_b_old <= '0';
		elsif rising_edge(clk_b_i) then
			toggle_b_old <= toggle_b;
		end if;
	end process;

	pulse_o <= toggle_b xor toggle_b_old; -- Each change of the toggle is one pulse
end arch;

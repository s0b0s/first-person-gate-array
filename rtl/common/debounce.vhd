--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Button Debouncer
-- Module Name:    debounce
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Push-button debouncer: 3-stage synchronizer, then a
--                 saturating
--                 counter with hysteresis that counts up while the input
--                 is '1' and down while it is '0'; the output changes only
--                 when the counter reaches all ones or all zeros. A
--                 prescaler advances the counter once every TICK_CYCLES
--                 clocks, so the input must hold for about
--                 TICK_CYCLES x 2^CNT_BITS clocks (default 100 x 2^16 at
--                 100 MHz = 65 ms, so about 7 presses per second is the
--                 fastest it follows). rise_o pulses for one cycle on each
--                 debounced press.
--                 Clock domain: clk_i.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std,
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

entity debounce is
	generic(
		TICK_CYCLES: positive := 100; -- Clocks per counter step
		CNT_BITS: positive := 16 -- Saturating counter width
	);
	port(
		clk_i: in std_logic; -- Clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		button_i: in std_logic; -- Raw button input, active high
		level_o: out std_logic; -- Debounced level
		rise_o: out std_logic -- One-cycle pulse on each press
	);
end debounce;

architecture arch of debounce is
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
	constant CNT_MAX: unsigned(CNT_BITS - 1 downto 0) := (others => '1');
	signal button_sync: std_logic;
	signal tick_count: natural range 0 to TICK_CYCLES - 1 := 0;
	signal cnt: unsigned(CNT_BITS - 1 downto 0) := (others => '0');
	signal level: std_logic := '0';
	signal level_old: std_logic := '0';
begin
	sync_button: synchronizer
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			async_i => button_i,
			sync_o => button_sync
		);

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			tick_count <= 0;
			cnt <= (others => '0');
			level <= '0';
			level_old <= '0';
		elsif rising_edge(clk_i) then
			level_old <= level;
			if (tick_count = TICK_CYCLES - 1) then
				tick_count <= 0;
				-- Saturating up/down count; the level flips only at the ends
				if (button_sync = '1') then
					if (cnt /= CNT_MAX) then
						cnt <= cnt + 1;
					else
						level <= '1';
					end if;
				else
					if (cnt /= 0) then
						cnt <= cnt - 1;
					else
						level <= '0';
					end if;
				end if;
			else
				tick_count <= tick_count + 1;
			end if;
		end if;
	end process;

	level_o <= level;
	rise_o <= level and (not level_old);
end arch;

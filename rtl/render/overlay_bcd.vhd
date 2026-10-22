--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Binary to BCD
-- Module Name:    overlay_bcd
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Sequential binary to BCD converter (double dabble) for the
--                 overlay's numbers: a 24-bit value becomes 8 decimal digits
--                 (digit k in bits 4k + 3 .. 4k, digit 0 = ones).
--                 Each of the 24 steps first adds 3 to every digit that is
--                 5 or more, then shifts the digits left by one bit with the
--                 next value bit (most significant first) coming in at the
--                 bottom; after 24 steps the digits hold the decimal value.
--                 Interface: pulse start_i with value_i; done_o pulses with
--                 digits_o valid 25 clocks later; digits_o holds until the
--                 next start.
--                 Clock domain: clk_i. Latency 25 clocks.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 Values above 99,999,999 cannot occur (24 bits).
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity overlay_bcd is
	port(
		clk_i: in std_logic; -- Clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		start_i: in std_logic; -- Pulse: convert value_i
		value_i: in std_logic_vector(23 downto 0); -- Binary value
		done_o: out std_logic; -- Pulse: digits_o valid
		digits_o: out std_logic_vector(31 downto 0) -- 8 BCD digits, ones in 3:0
	);
end overlay_bcd;

architecture arch of overlay_bcd is
	signal value: unsigned(23 downto 0) := (others => '0'); -- Shifts out MSB first
	signal bcd: unsigned(31 downto 0) := (others => '0');
	signal count: natural range 0 to 24 := 0; -- Steps still to do
	signal done: std_logic := '0';

	-- Add 3 to every BCD digit that is 5 or more (before the shift)
	function adjust(b: unsigned(31 downto 0)) return unsigned is
		variable r: unsigned(31 downto 0) := b;
	begin
		for k in 0 to 7 loop
			if (r(4 * k + 3 downto 4 * k) >= 5) then
				r(4 * k + 3 downto 4 * k) := r(4 * k + 3 downto 4 * k) + 3;
			end if;
		end loop;
		return r;
	end function;
begin
	process(clk_i, rst_i)
		variable b: unsigned(31 downto 0);
	begin
		if (rst_i = '1') then
			value <= (others => '0');
			bcd <= (others => '0');
			count <= 0;
			done <= '0';
		elsif rising_edge(clk_i) then
			done <= '0';
			if (start_i = '1') then
				value <= unsigned(value_i);
				bcd <= (others => '0');
				count <= 24;
			elsif (count /= 0) then
				-- Double dabble: adjust the digits, then shift the next binary bit into the ones digit
				b := adjust(bcd);
				bcd <= b(30 downto 0) & value(23);
				value <= value(22 downto 0) & '0';
				count <= count - 1;
				if (count = 1) then
					done <= '1';
				end if;
			end if;
		end if;
	end process;

	done_o <= done;
	digits_o <= std_logic_vector(bcd);
end arch;

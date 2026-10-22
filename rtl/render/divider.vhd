--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Restoring Divider
-- Module Name:    divider
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Sequential unsigned restoring divider, one quotient bit
--                 per clock (shift and subtract):
--                   for i = NUM_BITS - 1 downto 0:
--                     r = 2 r + num(i); if r >= den then r = r - den,
--                     q(i) = 1
--                 quo_o = floor(num / den), except that it saturates to
--                 2^QUO_BITS - 1 when the quotient does not fit in
--                 QUO_BITS bits or den = 0 (then every step subtracts
--                 nothing and q comes out all ones). This is exactly
--                 div_sat() in tools/model/render.py.
--                 Interface: pulse start_i with num_i and den_i; done_o
--                 pulses with quo_o valid NUM_BITS + 1 clocks later; quo_o
--                 holds until the next start. busy_o is high meanwhile.
--                 Clock domain: clk_i. Latency NUM_BITS + 1 clocks.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 NUM_BITS must be greater than QUO_BITS.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity divider is
	generic(
		NUM_BITS: positive := 33; -- Dividend width
		DEN_BITS: positive := 24; -- Divisor width
		QUO_BITS: positive := 24 -- Quotient width (saturating)
	);
	port(
		clk_i: in std_logic; -- Clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		start_i: in std_logic; -- Pulse: start a division
		num_i: in std_logic_vector(NUM_BITS - 1 downto 0); -- Dividend
		den_i: in std_logic_vector(DEN_BITS - 1 downto 0); -- Divisor
		busy_o: out std_logic; -- Division in progress
		done_o: out std_logic; -- Pulse: quo_o is valid
		quo_o: out std_logic_vector(QUO_BITS - 1 downto 0) -- Saturated quotient
	);
end divider;

architecture arch of divider is
	signal num: unsigned(NUM_BITS - 1 downto 0) := (others => '0'); -- Shifts out MSB first
	signal den: unsigned(DEN_BITS downto 0) := (others => '0');
	signal rem_r: unsigned(DEN_BITS downto 0) := (others => '0'); -- Partial remainder
	signal quo: unsigned(NUM_BITS - 1 downto 0) := (others => '0');
	signal count: natural range 0 to NUM_BITS := 0; -- Bits still to do
	signal done: std_logic := '0';
	signal result: unsigned(QUO_BITS - 1 downto 0) := (others => '0');
	signal trial: unsigned(DEN_BITS + 1 downto 0);
	signal shifted: unsigned(DEN_BITS + 1 downto 0);
begin
	-- One restoring step: shift the next dividend bit into the remainder
	-- and subtract the divisor if it fits. The remainder never exceeds the
	-- divisor, so DEN_BITS + 1 bits hold it; one more bit holds the shift.
	shifted <= rem_r & num(NUM_BITS - 1);
	trial <= shifted - ('0' & den); -- MSB set = borrow: the divisor did not fit

	process(clk_i, rst_i)
		variable q: unsigned(NUM_BITS - 1 downto 0);
	begin
		if (rst_i = '1') then
			num <= (others => '0');
			den <= (others => '0');
			rem_r <= (others => '0');
			quo <= (others => '0');
			count <= 0;
			done <= '0';
			result <= (others => '0');
		elsif rising_edge(clk_i) then
			done <= '0';
			if (start_i = '1') then
				num <= unsigned(num_i);
				den <= '0' & unsigned(den_i);
				rem_r <= (others => '0');
				quo <= (others => '0');
				count <= NUM_BITS;
			elsif (count /= 0) then
				num <= num(NUM_BITS - 2 downto 0) & '0';
				q := quo(NUM_BITS - 2 downto 0) & '0';
				if (trial(DEN_BITS + 1) = '0') then
					-- No borrow: the divisor fits
					rem_r <= trial(DEN_BITS downto 0);
					q(0) := '1';
				else
					rem_r <= shifted(DEN_BITS downto 0);
				end if;
				quo <= q;
				count <= count - 1;
				if (count = 1) then
					-- Last bit: saturate if the quotient is wider than QUO_BITS
					done <= '1';
					if (q(NUM_BITS - 1 downto QUO_BITS) /= 0) then
						result <= (others => '1');
					else
						result <= q(QUO_BITS - 1 downto 0);
					end if;
				end if;
			end if;
		end if;
	end process;

	busy_o <= '1' when (count /= 0) else '0';
	done_o <= done;
	quo_o <= std_logic_vector(result);
end arch;

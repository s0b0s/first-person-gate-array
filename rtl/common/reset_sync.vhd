--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Reset Synchronizer
-- Module Name:    reset_sync
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Reset synchronizer: rst_o asserts asynchronously with
--                 arst_i and releases synchronously STAGES clk_i edges
--                 after arst_i falls (only the release can cause
--                 metastability). A '0' shifts into a chain preset to all
--                 ones.
--                 Clock domain: clk_i. Release latency: STAGES cycles.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 STAGES must be at least 2.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;

entity reset_sync is
	generic(
		STAGES: positive := 3 -- Release delay in clock cycles
	);
	port(
		clk_i: in std_logic; -- Clock of the domain being reset
		arst_i: in std_logic; -- Asynchronous reset request, active high
		rst_o: out std_logic -- Reset for the domain, active high
	);
end reset_sync;

architecture arch of reset_sync is
	-- Power on in reset; the chain empties only after the clock runs
	signal s: std_logic_vector(STAGES - 1 downto 0) := (others => '1');
	attribute ASYNC_REG: string;
	attribute ASYNC_REG of s: signal is "TRUE";
begin
	process(clk_i, arst_i)
	begin
		if (arst_i = '1') then
			s <= (others => '1');
		elsif rising_edge(clk_i) then
			s <= s(STAGES - 2 downto 0) & '0'; -- Release STAGES edges after arst_i drops
		end if;
	end process;

	rst_o <= s(STAGES - 1);
end arch;

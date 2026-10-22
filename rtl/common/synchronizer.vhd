--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Synchronizer
-- Module Name:    synchronizer
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Metastability shift register for one asynchronous input
--                 or one bit crossing into the clk_i domain (three
--                 stages, no logic between them, clocked by the
--                 receiving domain). INIT sets both the power-on and the
--                 reset value, so a line that idles high (PS/2, UART RX)
--                 does not produce a false edge after configuration.
--                 Clock domain: clk_i. Latency: STAGES clock cycles.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 STAGES must be at least 2. Only for single bits or for
--                 multi-bit values that are stable when sampled.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;

entity synchronizer is
	generic(
		STAGES: positive := 3; -- Flip-flops in the chain
		INIT: std_logic := '0' -- Power-on and reset value
	);
	port(
		clk_i: in std_logic; -- Receiving clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		async_i: in std_logic; -- Asynchronous input
		sync_o: out std_logic -- Synchronized output
	);
end synchronizer;

architecture arch of synchronizer is
	signal s: std_logic_vector(STAGES - 1 downto 0) := (others => INIT);
	-- Keep the chain as separate flip-flops placed close together
	attribute ASYNC_REG: string;
	attribute ASYNC_REG of s: signal is "TRUE";
begin
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			s <= (others => INIT);
		elsif rising_edge(clk_i) then
			s <= s(STAGES - 2 downto 0) & async_i;
		end if;
	end process;

	sync_o <= s(STAGES - 1);
end arch;

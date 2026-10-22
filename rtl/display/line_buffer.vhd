--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Line Buffer
-- Module Name:    line_buffer
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Dual-clock line buffer: 1024 bytes, written in the
--                 system domain by the line fetcher and read in the pixel
--                 domain by the display pipeline. Two 320-byte halves at
--                 0 and 512 hold rendered lines alternately (ping-pong).
--                 This RAM is one of the display's clock-domain crossing
--                 points: the fetcher only writes the half the pixel side
--                 is not reading, so no word is written and read at once.
--                 Clock domains: wr_clk_i (system), rd_clk_i (pixel).
--                 Read latency: 1 rd_clk_i cycle.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
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

entity line_buffer is
	port(
		wr_clk_i: in std_logic; -- System clock
		wr_en_i: in std_logic; -- Write enable
		wr_addr_i: in std_logic_vector(9 downto 0); -- Half (bit 9) and x
		wr_data_i: in std_logic_vector(7 downto 0); -- Palette index
		rd_clk_i: in std_logic; -- Pixel clock
		rd_addr_i: in std_logic_vector(9 downto 0); -- Half (bit 9) and x
		rd_data_o: out std_logic_vector(7 downto 0) -- Palette index
	);
end line_buffer;

architecture arch of line_buffer is
	type ram_t is array (0 to 1023) of std_logic_vector(7 downto 0);
	signal ram: ram_t := (others => (others => '0'));
begin
	process(wr_clk_i)
	begin
		if rising_edge(wr_clk_i) then
			if (wr_en_i = '1') then
				ram(to_integer(unsigned(wr_addr_i))) <= wr_data_i;
			end if;
		end if;
	end process;

	process(rd_clk_i)
	begin
		if rising_edge(rd_clk_i) then
			rd_data_o <= ram(to_integer(unsigned(rd_addr_i)));
		end if;
	end process;
end arch;

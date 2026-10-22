--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Palette RAM
-- Module Name:    palette_ram
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    256 x 18-bit palette (6 bits per channel: R 17:12,
--                 G 11:6, B 5:0), written in the system domain and read
--                 in the pixel domain. Power-on contents come from
--                 palette_pkg. The display controller only lets writes
--                 through during vertical blanking, so a palette change
--                 never shows half-way down the screen.
--                 Clock domains: wr_clk_i (system), rd_clk_i (pixel).
--                 Read latency: 1 rd_clk_i cycle.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, palette_pkg
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
use work.palette_pkg.all;

entity palette_ram is
	port(
		wr_clk_i: in std_logic; -- System clock
		wr_en_i: in std_logic; -- Write enable
		wr_addr_i: in std_logic_vector(7 downto 0); -- Palette index
		wr_data_i: in std_logic_vector(17 downto 0); -- RGB666 color
		rd_clk_i: in std_logic; -- Pixel clock
		rd_addr_i: in std_logic_vector(7 downto 0); -- Palette index
		rd_data_o: out std_logic_vector(17 downto 0) -- RGB666 color
	);
end palette_ram;

architecture arch of palette_ram is
	signal ram: palette_t := DEFAULT_PALETTE;
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

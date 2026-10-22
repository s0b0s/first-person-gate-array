--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Tile Map RAM
-- Module Name:    tile_map
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    The 64 x 64 tile map (24-bit tile words, fields TILE_*
--                 in game_pkg),
--                 index y * 64 + x. Two ports on one clock:
--                   port A: read only, the ray engine's DDA walk
--                   port B: read/write, shared by the level loader
--                           (writes), the game sequencer and the floor
--                           caster (reads); the game top level gives it to
--                           one of them at a time
--                 Both reads are registered (data one clock after the
--                 address). Power-on contents are level 1 from
--                 map_init_pkg, so the game runs even before (or without)
--                 a load from flash.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std,
--                 map_init_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Stage 1
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.map_init_pkg.all;

entity tile_map is
	port(
		clk_i: in std_logic; -- System clock
		a_addr_i: in std_logic_vector(11 downto 0); -- Port A tile index
		a_data_o: out std_logic_vector(23 downto 0); -- Port A tile word
		b_we_i: in std_logic; -- Port B write enable
		b_addr_i: in std_logic_vector(11 downto 0); -- Port B tile index
		b_data_i: in std_logic_vector(23 downto 0); -- Port B write data
		b_data_o: out std_logic_vector(23 downto 0) -- Port B tile word (read first)
	);
end tile_map;

architecture arch of tile_map is
	-- Only port B writes, so the array is a signal written by one process
	-- and read by both (Vivado infers one dual-port block RAM)
	signal ram: tile_array_t := LEVEL1_TILES;
begin
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			a_data_o <= ram(to_integer(unsigned(a_addr_i)));
		end if;
	end process;

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			b_data_o <= ram(to_integer(unsigned(b_addr_i))); -- Old word when also writing (read first)
			if (b_we_i = '1') then
				ram(to_integer(unsigned(b_addr_i))) <= b_data_i;
			end if;
		end if;
	end process;
end arch;

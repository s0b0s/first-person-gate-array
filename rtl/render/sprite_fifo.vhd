--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Sprite Pixel FIFO
-- Module Name:    sprite_fifo
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Small first-word-fall-through FIFO for the sprite engine:
--                 16 words in distributed RAM with an asynchronous read, so
--                 a word pushed at one edge is on dout_o in the next cycle
--                 (the read-return path needs that: SRAM read data can
--                 arrive two clocks after the request was granted).
--                 push_i on a full FIFO and pop_i on an empty one are
--                 ignored; the sprite engine's credit counting keeps both
--                 from happening.
--                 Clock domain: clk_i. One push and one pop per clock.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Stage 2
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity sprite_fifo is
	generic(
		WIDTH: positive := 8 -- Bits per word
	);
	port(
		clk_i: in std_logic; -- Clock
		rst_i: in std_logic; -- Asynchronous reset, empties the FIFO
		push_i: in std_logic; -- Write din_i
		din_i: in std_logic_vector(WIDTH - 1 downto 0); -- Word in
		pop_i: in std_logic; -- Drop the head word
		dout_o: out std_logic_vector(WIDTH - 1 downto 0); -- Head word
		empty_o: out std_logic; -- No word stored
		level_o: out std_logic_vector(4 downto 0) -- Words stored (0..16)
	);
end sprite_fifo;

architecture arch of sprite_fifo is
	type ram_t is array (0 to 15) of std_logic_vector(WIDTH - 1 downto 0);
	signal ram: ram_t;
	signal wr_ptr: unsigned(3 downto 0) := (others => '0');
	signal rd_ptr: unsigned(3 downto 0) := (others => '0');
	signal count: unsigned(4 downto 0) := (others => '0');
	signal do_push: std_logic;
	signal do_pop: std_logic;
begin
	do_push <= '1' when ((push_i = '1') and (count /= 16)) else '0';
	do_pop <= '1' when ((pop_i = '1') and (count /= 0)) else '0';

	-- RAM: no reset so it maps onto distributed RAM
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (do_push = '1') then
				ram(to_integer(wr_ptr)) <= din_i;
			end if;
		end if;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			wr_ptr <= (others => '0');
			rd_ptr <= (others => '0');
			count <= (others => '0');
		elsif rising_edge(clk_i) then
			if (do_push = '1') then
				wr_ptr <= wr_ptr + 1;
			end if;
			if (do_pop = '1') then
				rd_ptr <= rd_ptr + 1;
			end if;
			-- A push and a pop in the same clock leave the count unchanged
			if ((do_push = '1') and (do_pop = '0')) then
				count <= count + 1;
			elsif ((do_push = '0') and (do_pop = '1')) then
				count <= count - 1;
			end if;
		end if;
	end process;

	dout_o <= ram(to_integer(rd_ptr)); -- Asynchronous read: the head word is always visible
	empty_o <= '1' when (count = 0) else '0';
	level_o <= std_logic_vector(count);
end arch;

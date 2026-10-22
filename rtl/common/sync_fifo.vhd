--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Synchronous FIFO
-- Module Name:    sync_fifo
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Single-clock first-word-fall-through FIFO with
--                 valid/ready on both sides. Storage is a simple
--                 dual-port RAM (block RAM when large) read every cycle at
--                 the next read pointer, so the head entry is always
--                 waiting on out_data_o.
--                 Empty-to-non-empty: a word written at edge k is read
--                 out of the RAM at edge k + 1, so out_valid_o rises two
--                 edges after the write (out_valid is registered as
--                 "next read pointer differs from the old write pointer",
--                 which avoids reading a RAM word in the same cycle it is
--                 written).
--                 Capacity is 2^DEPTH_BITS - 1 words (one slot is kept
--                 empty to tell full from empty).
--                 Clock domain: clk_i. Throughput: one word in and one
--                 out per cycle.
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

entity sync_fifo is
	generic(
		WIDTH: positive := 8; -- Bits per word
		DEPTH_BITS: positive := 9 -- RAM holds 2^DEPTH_BITS words
	);
	port(
		clk_i: in std_logic; -- Clock
		rst_i: in std_logic; -- Asynchronous reset, empties the FIFO
		in_valid_i: in std_logic; -- Writer has a word
		in_ready_o: out std_logic; -- FIFO not full
		in_data_i: in std_logic_vector(WIDTH - 1 downto 0); -- Word in
		out_valid_o: out std_logic; -- Head word present
		out_ready_i: in std_logic; -- Reader takes the head word
		out_data_o: out std_logic_vector(WIDTH - 1 downto 0); -- Head word
		level_o: out std_logic_vector(DEPTH_BITS - 1 downto 0) -- Words stored
	);
end sync_fifo;

architecture arch of sync_fifo is
	type ram_t is array (0 to 2 ** DEPTH_BITS - 1) of std_logic_vector(WIDTH - 1 downto 0);
	signal ram: ram_t;
	signal wr_ptr: unsigned(DEPTH_BITS - 1 downto 0) := (others => '0');
	signal rd_ptr: unsigned(DEPTH_BITS - 1 downto 0) := (others => '0');
	signal rd_ptr_next: unsigned(DEPTH_BITS - 1 downto 0);
	signal out_valid: std_logic := '0';
	signal full: std_logic;
	signal push: std_logic;
	signal pop: std_logic;
begin
	-- One slot always stays empty, so equal pointers can only mean empty
	full <= '1' when (wr_ptr + 1 = rd_ptr) else '0';
	push <= in_valid_i and (not full);
	pop <= out_valid and out_ready_i;
	rd_ptr_next <= rd_ptr + 1 when (pop = '1') else rd_ptr;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			wr_ptr <= (others => '0');
			rd_ptr <= (others => '0');
			out_valid <= '0';
		elsif rising_edge(clk_i) then
			if (push = '1') then
				wr_ptr <= wr_ptr + 1;
			end if;
			rd_ptr <= rd_ptr_next;
			-- Compare with the old write pointer: a word written at this
			-- edge is not yet readable from the RAM
			if (rd_ptr_next /= wr_ptr) then
				out_valid <= '1';
			else
				out_valid <= '0';
			end if;
		end if;
	end process;

	-- RAM: no reset, so it maps onto block RAM
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (push = '1') then
				ram(to_integer(wr_ptr)) <= in_data_i;
			end if;
			out_data_o <= ram(to_integer(rd_ptr_next)); -- Show-ahead: next word ready with out_valid
		end if;
	end process;

	in_ready_o <= not full;
	out_valid_o <= out_valid;
	level_o <= std_logic_vector(wr_ptr - rd_ptr);
end arch;

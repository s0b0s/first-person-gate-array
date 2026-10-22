--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    State CRC-32
-- Module Name:    core_crc
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Byte-serial CRC-32 for the game core's per-frame state
--                 checksum (game.state_crc() in tools/model/game.py, which
--                 is zlib.crc32): reflected polynomial 0xEDB88320, register
--                 preset to all ones by init_i, one byte per clock while
--                 valid_i is high (least significant bit first, as zlib),
--                 crc_o is the register inverted (the final xor), so it is
--                 the CRC of every byte fed since the last init_i.
--                 The 8 shift steps of one byte are unrolled into one XOR
--                 network (each result bit is an XOR of at most 8 + 8 bits).
--                 Clock domain: clk_i (system). Latency: crc_o includes a
--                 byte one clock after it was fed.
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

entity core_crc is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		init_i: in std_logic; -- Pulse: start a new checksum
		valid_i: in std_logic; -- data_i is the next byte
		data_i: in std_logic_vector(7 downto 0);
		crc_o: out std_logic_vector(31 downto 0) -- CRC-32 of the bytes so far
	);
end core_crc;

architecture arch of core_crc is
	constant POLY: unsigned(31 downto 0) := x"EDB88320"; -- 0x04C11DB7 bit-reversed

	signal crc: unsigned(31 downto 0) := (others => '1'); -- zlib CRC-32 starts from all ones

	-- One byte through the bit-serial reflected CRC: xor the byte into the
	-- low end, then 8 times shift right and xor the polynomial when the
	-- bit shifted out is 1
	function crc_byte(c: unsigned(31 downto 0); b: std_logic_vector(7 downto 0)) return unsigned is
		variable x: unsigned(31 downto 0);
	begin
		x := c xor resize(unsigned(b), 32);
		for i in 0 to 7 loop
			if (x(0) = '1') then
				x := shift_right(x, 1) xor POLY;
			else
				x := shift_right(x, 1);
			end if;
		end loop;
		return x;
	end function;
begin
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			crc <= (others => '1');
		elsif rising_edge(clk_i) then
			if (init_i = '1') then
				crc <= (others => '1');
			elsif (valid_i = '1') then
				crc <= crc_byte(crc, data_i);
			end if;
		end if;
	end process;

	crc_o <= std_logic_vector(not crc); -- and ends with an xor of all ones (zlib.crc32)
end arch;

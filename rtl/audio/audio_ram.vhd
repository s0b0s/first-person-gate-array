--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Audio Sample RAM
-- Module Name:    audio_ram
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Sample memory of the audio mixer, 4096 bytes:
--                   0..2303     nine 256-byte rings (voice v at v * 256;
--                               voices 0..7 effects, 8 music), refilled
--                               from flash while a sound plays
--                   2304..3647  the first 64 bytes ("head") of each of the
--                               21 items (18 sounds, 3 music tracks) at
--                               2304 + item * 64, loaded once at start-up,
--                               so a sound can start on the next output
--                               sample without waiting for the flash
--                 Port A writes (flash data), port B reads (the mixer).
--                 Clock domain: clk_i. Read latency 1 clock.
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

entity audio_ram is
	port(
		clk_i: in std_logic; -- Clock
		we_i: in std_logic; -- Port A write enable
		waddr_i: in std_logic_vector(11 downto 0); -- Port A address
		wdata_i: in std_logic_vector(7 downto 0); -- Port A data
		raddr_i: in std_logic_vector(11 downto 0); -- Port B address
		rdata_o: out std_logic_vector(7 downto 0) -- Port B data
	);
end audio_ram;

architecture arch of audio_ram is
	type ram_t is array (0 to 4095) of std_logic_vector(7 downto 0);
	signal ram: ram_t := (others => x"80"); -- 128 = silence
begin
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (we_i = '1') then
				ram(to_integer(unsigned(waddr_i))) <= wdata_i;
			end if;
		end if;
	end process;

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			rdata_o <= ram(to_integer(unsigned(raddr_i)));
		end if;
	end process;
end arch;

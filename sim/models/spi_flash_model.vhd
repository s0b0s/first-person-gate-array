--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    SPI Flash Model
-- Module Name:    spi_flash_model
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Behavioral single-bit SPI flash (mode 0) standing in for
--                 the Cmod's MX25L3233F / N25Q032A:
--                 - 0x9F READ ID: returns the 3 ID bytes (generic, default
--                   C2 20 16 = Macronix MX25L3233F), then 0xFF
--                 - 0x03 READ: 3 address bytes, then data from that
--                   address on, wrapping at 4 MB
--                 Any other command is reported as an error (the design
--                 must never write or erase).
--                 MOSI is sampled on rising SCK; MISO changes after each
--                 falling SCK: 'X' at once, the new bit after T_V (8 ns),
--                 and 'Z' while CS_n is high.
--                 Timing checks (severity error, counted in errors_o):
--                 SCK period >= T_SCK_MIN (20 ns = 50 MHz READ limit),
--                 CS_n low to first rising SCK >= T_CSS, CS_n high time
--                 between commands >= T_CSH, SCK low when CS_n changes
--                 (mode 0), MOSI stable T_DS before rising SCK.
--                 Memory: flash_mem in spi_flash_model_pkg. Bytes never
--                 written return flash_pattern(address), so testbenches
--                 can predict any read; testbenches may also write bytes
--                 (back door). One flash model per simulation.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std
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

package spi_flash_model_pkg is
	constant FLASH_BYTES: natural := 4 * 1024 * 1024;
	-- Default contents: varies with every address byte
	function flash_pattern(addr: natural) return natural;

	type flash_mem_t is protected
		procedure write(addr: natural; data: natural);
		impure function read(addr: natural) return natural;
	end protected flash_mem_t;
	shared variable flash_mem: flash_mem_t;
end package spi_flash_model_pkg;

package body spi_flash_model_pkg is
	function flash_pattern(addr: natural) return natural is
	begin
		-- Page and 64 KB terms make a wrong address byte show up as wrong data
		return (addr + 3 * (addr / 256) + 7 * (addr / 65536)) mod 256;
	end function;

	type flash_mem_t is protected body
		-- -1 marks a byte that was never written
		type mem_array_t is array (0 to FLASH_BYTES - 1) of integer range -1 to 255;
		variable mem: mem_array_t := (others => -1);

		procedure write(addr: natural; data: natural) is
		begin
			mem(addr mod FLASH_BYTES) := data mod 256;
		end procedure;

		impure function read(addr: natural) return natural is
		begin
			if (mem(addr mod FLASH_BYTES) < 0) then
				return flash_pattern(addr mod FLASH_BYTES);
			end if;
			return mem(addr mod FLASH_BYTES);
		end function;
	end protected body flash_mem_t;
end package body spi_flash_model_pkg;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.spi_flash_model_pkg.all;

entity spi_flash_model is
	generic(
		JEDEC_ID: std_logic_vector(23 downto 0) := x"C22016"; -- MX25L3233F
		T_V: time := 8 ns; -- SCK falling to MISO valid
		T_SCK_MIN: time := 20 ns; -- Fastest SCK period allowed for READ
		T_CSS: time := 5 ns; -- CS_n low to first rising SCK
		T_CSH: time := 30 ns; -- CS_n high time between commands
		T_DS: time := 2 ns -- MOSI setup before rising SCK
	);
	port(
		cs_n_i: in std_logic; -- Chip select, active low
		sck_i: in std_logic; -- Serial clock
		mosi_i: in std_logic; -- Data in (DQ0)
		miso_o: out std_logic; -- Data out (DQ1)
		reads_o: out natural; -- Commands completed
		errors_o: out natural -- Protocol and timing errors
	);
end spi_flash_model;

architecture arch of spi_flash_model is
	signal drive: std_logic := 'Z'; -- Scheduled MISO level
begin
	miso_o <= drive;

	process
		type phase_t is (P_CMD, P_ADDR, P_DATA, P_IGNORE);
		variable phase: phase_t := P_CMD;
		variable bits: natural := 0; -- Bits received in the current byte
		variable inbyte: std_logic_vector(7 downto 0) := (others => '0');
		variable cmd: std_logic_vector(7 downto 0) := (others => '0');
		variable addr_bytes: natural := 0;
		variable addr: natural := 0;
		variable outbyte: std_logic_vector(7 downto 0) := (others => '1');
		variable outbit: natural := 7; -- Bit of outbyte driven after the next fall
		variable id_index: natural := 0;
		variable t_rise, t_cs_fall, t_cs_rise, t_mosi: time := 0 ns;
		variable cs_seen_high: boolean := false;
		variable first_rise: boolean := true;
		variable errs: natural := 0;
		variable reads: natural := 0;

		procedure err(msg: string) is
		begin
			errs := errs + 1;
			report "SPI flash model: " & msg severity error;
		end procedure;

		-- Load the next output byte of the current command
		procedure next_out is
		begin
			if (cmd = x"9F") then
				if (id_index < 3) then
					-- ID bytes in order: manufacturer, memory type, capacity
					outbyte := JEDEC_ID(23 - 8 * id_index downto 16 - 8 * id_index);
				else
					outbyte := x"FF";
				end if;
				id_index := id_index + 1;
			else
				outbyte := std_logic_vector(to_unsigned(flash_mem.read(addr), 8));
				addr := (addr + 1) mod FLASH_BYTES;
			end if;
			outbit := 7;
		end procedure;
	begin
		wait on cs_n_i, sck_i, mosi_i;

		if (mosi_i'event) then
			t_mosi := now;
		end if;

		-- Chip select edges; SCK must be low (mode 0)
		if (cs_n_i'event and ((cs_n_i = '0') or (cs_n_i = '1'))) then -- (moves to 'X' or 'Z' ignored)
			if (sck_i = '1') then
				err("CS_n changed while SCK high");
			end if;
			if (cs_n_i = '0') then
				if (cs_seen_high and (now - t_cs_rise < T_CSH)) then
					err("CS_n high for only " & time'image(now - t_cs_rise));
				end if;
				t_cs_fall := now;
				phase := P_CMD;
				bits := 0;
				first_rise := true;
			else
				if ((phase = P_DATA) or (phase = P_IGNORE)) then
					reads := reads + 1;
				elsif ((phase /= P_CMD) or (bits /= 0)) then
					err("command cut short");
				end if;
				t_cs_rise := now;
				cs_seen_high := true;
			end if;
			drive <= transport 'Z';
		end if;

		-- Rising SCK: sample MOSI, or step to the next output bit
		if ((cs_n_i = '0') and rising_edge(sck_i)) then
			if (first_rise) then
				if (now - t_cs_fall < T_CSS) then
					err("CS_n setup " & time'image(now - t_cs_fall));
				end if;
			elsif (now - t_rise < T_SCK_MIN) then
				err("SCK period " & time'image(now - t_rise));
			end if;
			first_rise := false;
			t_rise := now;
			if ((phase = P_CMD) or (phase = P_ADDR)) then
				if (now - t_mosi < T_DS) then
					err("MOSI setup " & time'image(now - t_mosi));
				end if;
				inbyte := inbyte(6 downto 0) & mosi_i;
				bits := bits + 1;
				if (bits = 8) then
					bits := 0;
					if (phase = P_CMD) then
						cmd := inbyte;
						if (cmd = x"9F") then
							id_index := 0;
							phase := P_DATA;
							next_out;
						elsif (cmd = x"03") then
							phase := P_ADDR;
							addr_bytes := 0;
							addr := 0;
						else
							err("unsupported command 0x" &
								integer'image(to_integer(unsigned(cmd))));
							phase := P_IGNORE;
						end if;
					else
						-- 24-bit address, most significant byte first
						addr := (addr * 256 + to_integer(unsigned(inbyte))) mod FLASH_BYTES;
						addr_bytes := addr_bytes + 1;
						if (addr_bytes = 3) then
							phase := P_DATA;
							next_out;
						end if;
					end if;
				end if;
			elsif (phase = P_DATA) then
				-- The host just took outbyte(outbit)
				if (outbit = 0) then
					next_out;
				else
					outbit := outbit - 1;
				end if;
			end if;
		end if;

		-- Falling SCK in the data phase: old bit invalid at once, new bit
		-- valid T_V later
		if ((cs_n_i = '0') and falling_edge(sck_i) and (phase = P_DATA)) then
			drive <= transport 'X', outbyte(outbit) after T_V;
		end if;

		reads_o <= reads;
		errors_o <= errs;
	end process;
end arch;

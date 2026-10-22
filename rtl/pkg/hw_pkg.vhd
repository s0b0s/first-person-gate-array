--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Hardware Constants Package
-- Module Name:    hw_pkg
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Board and clock constants shared by every block: clock
--                 rates, VGA timing, SRAM and flash maps. The clock rates
--                 must match the MMCM in clock_reset and the XDC; the flash
--                 map must match tools/flash_image/make_gamedata.py.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Stage 0 constants
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package hw_pkg is
	-- Clocks: one MMCM, 12 MHz x 50 = 600 MHz VCO, /6 and /24
	constant SYS_CLK_HZ: natural := 100_000_000;
	constant PIX_CLK_HZ: natural := 25_000_000;

	-- 640x480 at 60 Hz (25.000 MHz pixel clock gives 59.52 Hz). Counts are
	-- in pixel clocks (horizontal) and scanlines (vertical); syncs are
	-- active low.
	constant H_VISIBLE: natural := 640;
	constant H_FRONT: natural := 16;
	constant H_SYNC: natural := 96;
	constant H_BACK: natural := 48;
	constant H_TOTAL: natural := H_VISIBLE + H_FRONT + H_SYNC + H_BACK; -- 800
	constant V_VISIBLE: natural := 480;
	constant V_FRONT: natural := 10;
	constant V_SYNC: natural := 2;
	constant V_BACK: natural := 33;
	constant V_TOTAL: natural := V_VISIBLE + V_FRONT + V_SYNC + V_BACK; -- 525

	-- External SRAM (IS61WV5128BLL-10): 512 K x 8
	constant SRAM_ADDR_BITS: natural := 19;
	constant SRAM_DATA_BITS: natural := 8;

	-- SRAM map (byte addresses). A framebuffer is 320 x 240 bytes; buffer
	-- select is address bit 17.
	constant FB_BYTES: natural := 76_800;
	constant FB0_BASE: natural := 16#00000#;
	constant FB1_BASE: natural := 16#20000#;
	constant ART_BASE: natural := 16#40000#;
	constant REPLAY_BASE: natural := 16#71000#;

	-- QSPI flash: bitstream at 0, game data at 0x220000
	constant FLASH_ADDR_BITS: natural := 22;
	constant FLASH_DATA_BASE: natural := 16#220000#;

	-- Number of cycles of clk in t_ns nanoseconds, rounded up. Used to turn
	-- datasheet times into counter limits.
	function cycles_ns(clk_hz: natural; t_ns: natural) return natural;
	-- Smallest number of bits that can hold the value n (at least 1)
	function bits_for(n: natural) return natural;
end package hw_pkg;

package body hw_pkg is
	function cycles_ns(clk_hz: natural; t_ns: natural) return natural is
		-- Work in units of kHz so 100 MHz x 20 ms stays inside 32 bits
		constant KHZ: natural := clk_hz / 1000;
	begin
		return (KHZ * t_ns + 999_999) / 1_000_000; -- kHz x ns / 10^6, rounded up
	end function;

	function bits_for(n: natural) return natural is
		variable b: natural := 1;
	begin
		while (2 ** b <= n) loop
			b := b + 1;
		end loop;
		return b;
	end function;
end package body hw_pkg;

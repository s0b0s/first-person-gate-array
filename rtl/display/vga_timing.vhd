--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    VGA Timing
-- Module Name:    vga_timing
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    640x480 at 60 Hz raster counters (VESA timing, both
--                 syncs active low; numbers in hw_pkg):
--                   h: 0..639 visible, 640..655 front porch,
--                      656..751 sync, 752..799 back porch
--                   v: 0..479 visible, 480..489 front porch,
--                      490..491 sync, 492..524 back porch
--                 h_o / v_o are the registered counters; hsync_o,
--                 vsync_o and active_o are decoded from them in the same
--                 cycle (the display pipeline delays them to match its
--                 color path).
--                 Clock domain: clk_i (pixel clock, 25 MHz). One pixel
--                 per clock.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg
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
use work.hw_pkg.all;

entity vga_timing is
	port(
		clk_i: in std_logic; -- Pixel clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		h_o: out std_logic_vector(9 downto 0); -- Horizontal count 0..799
		v_o: out std_logic_vector(9 downto 0); -- Vertical count 0..524
		hsync_o: out std_logic; -- Horizontal sync, active low
		vsync_o: out std_logic; -- Vertical sync, active low
		active_o: out std_logic -- Inside the 640x480 visible area
	);
end vga_timing;

architecture arch of vga_timing is
	signal h: unsigned(9 downto 0) := (others => '0');
	signal v: unsigned(9 downto 0) := (others => '0');
begin
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			h <= (others => '0');
			v <= (others => '0');
		elsif rising_edge(clk_i) then
			if (h = H_TOTAL - 1) then
				h <= (others => '0');
				if (v = V_TOTAL - 1) then
					v <= (others => '0');
				else
					v <= v + 1;
				end if;
			else
				h <= h + 1;
			end if;
		end if;
	end process;

	hsync_o <= '0' when ((h >= H_VISIBLE + H_FRONT) and
		(h < H_VISIBLE + H_FRONT + H_SYNC)) else '1';
	vsync_o <= '0' when ((v >= V_VISIBLE + V_FRONT) and
		(v < V_VISIBLE + V_FRONT + V_SYNC)) else '1';
	active_o <= '1' when ((h < H_VISIBLE) and (v < V_VISIBLE)) else '0';
	h_o <= std_logic_vector(h);
	v_o <= std_logic_vector(v);
end arch;

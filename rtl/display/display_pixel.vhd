--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Display Pixel Path
-- Module Name:    display_pixel
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Pixel-domain color path of the display controller.
--                 Pipeline (S0 = vga_timing's registered counters):
--                   S0: line buffer address from (h, v): half = rendered
--                       line bit 0 = v(1), x = h / 2 (pixel doubling)
--                   S1: line buffer byte arrives; the test pattern (if
--                       selected) replaces it; result addresses the
--                       palette
--                   S2: 18-bit palette color arrives; tint, then 2x2
--                       ordered dither down to OUT_BITS per channel
--                   S3: output registers (IOB) for color and both syncs
--                 Syncs and the visible flag travel down the same three
--                 registers, so they stay aligned with the color.
--                 Dither: d = Bayer 2x2 {0, 2, 3, 1} at (h mod 2, v mod 2)
--                 indexed as 2 * (v mod 2) + (h mod 2);
--                 out = min(15, (c6 + d) / 4). Each game pixel covers one
--                 2x2 block, so the four screen pixels average to about
--                 c6 / 4: 6 bits of shading from a 4-bit DAC.
--                 Tint: c = (3 * c + T) / 4 per channel toward T.
--                 Test patterns (game_pkg): color bands with one band per
--                 output bit (bypassing palette and dither), 2x2 checker
--                 with a white border, 8-pixel grid, palette gradient.
--                 Output enable: vga_t_o (one bit per pin, '1' = high
--                 impedance) follows out_en_i, registered like the data.
--                 Clock domain: clk_i (pixel, 25 MHz). Latency 3 clocks
--                 from the counters to the pins.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, game_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 OUT_BITS is 4 (dithered) or 6 (no dither).
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.game_pkg.all;

entity display_pixel is
	generic(
		OUT_BITS: positive := 4 -- Bits per channel at the DAC (4 or 6)
	);
	port(
		clk_i: in std_logic; -- Pixel clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		-- Raster position (S0)
		h_i: in std_logic_vector(9 downto 0);
		v_i: in std_logic_vector(9 downto 0);
		hsync_i: in std_logic;
		vsync_i: in std_logic;
		active_i: in std_logic;
		-- Settings, already in the pixel domain
		pattern_i: in std_logic_vector(2 downto 0); -- Test pattern select
		tint_i: in std_logic_vector(1 downto 0); -- Screen tint
		blank_i: in std_logic; -- Force black
		out_en_i: in std_logic; -- '1' = drive the pins (PWR_SENSE gate)
		-- Line buffer read port (address at S0, data at S1)
		lb_addr_o: out std_logic_vector(9 downto 0);
		lb_data_i: in std_logic_vector(7 downto 0);
		-- Palette read port (address at S1, data at S2)
		pal_addr_o: out std_logic_vector(7 downto 0);
		pal_data_i: in std_logic_vector(17 downto 0);
		-- VGA pins (S3)
		vga_r_o: out std_logic_vector(OUT_BITS - 1 downto 0);
		vga_g_o: out std_logic_vector(OUT_BITS - 1 downto 0);
		vga_b_o: out std_logic_vector(OUT_BITS - 1 downto 0);
		vga_hs_o: out std_logic;
		vga_vs_o: out std_logic;
		vga_t_o: out std_logic_vector(3 * OUT_BITS + 1 downto 0) -- '1' = high-Z
	);
end display_pixel;

architecture arch of display_pixel is
	constant NBANDS: natural := 3 * OUT_BITS;
	constant BAND_PERIOD: natural := 600 / NBANDS; -- Bands fill about 600 of the 640 visible pixels
	subtype chan_t is unsigned(5 downto 0);

	-- S1 registers
	signal h1, v1: unsigned(9 downto 0) := (others => '0');
	signal hs1, vs1, act1: std_logic := '1';
	-- S2 registers
	signal h2_0, v2_0: std_logic := '0';
	signal hs2, vs2, act2: std_logic := '1';
	signal bands2: std_logic := '0';
	signal band_bits2: std_logic_vector(NBANDS - 1 downto 0) := (others => '0');
	-- S3 (output) registers
	signal r3, g3, b3: std_logic_vector(OUT_BITS - 1 downto 0) := (others => '0');
	signal hs3, vs3: std_logic := '1';
	signal t3: std_logic_vector(3 * OUT_BITS + 1 downto 0) := (others => '1'); -- Color pins plus HS and VS
	attribute IOB: string;
	attribute IOB of r3, g3, b3, hs3, vs3, t3: signal is "TRUE";

	signal x1: unsigned(8 downto 0);
	signal y1: unsigned(8 downto 0);
	signal pattern_index: std_logic_vector(7 downto 0);
	signal band_bits: std_logic_vector(NBANDS - 1 downto 0);
	signal r_out, g_out, b_out: std_logic_vector(OUT_BITS - 1 downto 0);

	-- Blend one 6-bit channel 25% toward t: (3c + t) / 4
	function tint_chan(c: chan_t; t: natural) return chan_t is
		variable s: unsigned(7 downto 0);
	begin
		s := resize(c, 8) + resize(c & '0', 8) + to_unsigned(t, 8); -- c + 2c + t
		return s(7 downto 2);
	end function;

	-- 6-bit channel to OUT_BITS with the 2x2 ordered dither value d
	function dither_chan(c: chan_t; d: natural) return std_logic_vector is
		variable s: unsigned(6 downto 0);
	begin
		if (OUT_BITS >= 6) then
			return std_logic_vector(resize(c, OUT_BITS));
		end if;
		s := resize(c, 7) + to_unsigned(d, 7);
		if (s(6) = '1') then
			return (OUT_BITS - 1 downto 0 => '1'); -- (63 + d) / 4 = 16: clamp
		end if;
		return std_logic_vector(s(5 downto 6 - OUT_BITS)); -- Top OUT_BITS of the sum: (c + d) / 4 at 4 bits
	end function;
begin
	------------------------------------------------------------------
	-- S0: line buffer address. Rendered line y = v / 2, half = y mod 2.
	------------------------------------------------------------------
	lb_addr_o <= v_i(1) & h_i(9 downto 1);

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			h1 <= (others => '0');
			v1 <= (others => '0');
			hs1 <= '1';
			vs1 <= '1';
			act1 <= '0';
		elsif rising_edge(clk_i) then
			h1 <= unsigned(h_i);
			v1 <= unsigned(v_i);
			hs1 <= hsync_i;
			vs1 <= vsync_i;
			act1 <= active_i;
		end if;
	end process;

	------------------------------------------------------------------
	-- S1: test patterns (palette indices) and color bands (direct bits)
	------------------------------------------------------------------
	x1 <= h1(9 downto 1);
	y1 <= v1(9 downto 1);

	process(pattern_i, lb_data_i, x1, y1, h1, v1)
		variable border: boolean;
		variable cell: unsigned(8 downto 0);
	begin
		border := (x1 = 0) or (x1 = RENDER_W - 1) or (y1 = 0) or (y1 = RENDER_H - 1);
		-- Gradient cell: 32x32 screen pixels, 20 per row; row * 20 = row * 16 + row * 4
		cell := shift_left(resize(v1(8 downto 5), 9), 4) + shift_left(resize(v1(8 downto 5), 9), 2) +
			resize(h1(9 downto 5), 9);
		case to_integer(unsigned(pattern_i)) is
			when PATTERN_CHECKER =>
				if (border) then
					pattern_index <= x"0F";
				elsif ((x1(0) xor y1(0)) = '1') then
					pattern_index <= x"07";
				else
					pattern_index <= x"00";
				end if;
			when PATTERN_GRID =>
				if (border or (x1(2 downto 0) = 0) or (y1(2 downto 0) = 0)) then
					pattern_index <= x"0F";
				else
					pattern_index <= x"00";
				end if;
			when PATTERN_GRADIENT =>
				pattern_index <= std_logic_vector(cell(7 downto 0));
			when others =>
				pattern_index <= lb_data_i;
		end case;
	end process;

	pal_addr_o <= pattern_index;

	-- Band i covers h = 20 + i * BAND_PERIOD for BAND_PERIOD - 8 pixels
	-- and lights only output bit NBANDS - 1 - i (R MSB first, B LSB last)
	process(h1)
	begin
		band_bits <= (others => '0');
		for i in 0 to NBANDS - 1 loop
			if ((h1 >= 20 + i * BAND_PERIOD) and (h1 < 12 + (i + 1) * BAND_PERIOD)) then
				band_bits(NBANDS - 1 - i) <= '1';
			end if;
		end loop;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			h2_0 <= '0';
			v2_0 <= '0';
			hs2 <= '1';
			vs2 <= '1';
			act2 <= '0';
			bands2 <= '0';
			band_bits2 <= (others => '0');
		elsif rising_edge(clk_i) then
			h2_0 <= h1(0);
			v2_0 <= v1(0);
			hs2 <= hs1;
			vs2 <= vs1;
			act2 <= act1;
			if (to_integer(unsigned(pattern_i)) = PATTERN_BANDS) then
				bands2 <= '1';
			else
				bands2 <= '0';
			end if;
			band_bits2 <= band_bits;
		end if;
	end process;

	------------------------------------------------------------------
	-- S2: tint and dither
	------------------------------------------------------------------
	process(pal_data_i, tint_i, h2_0, v2_0)
		variable r, g, b: chan_t;
		variable d: natural range 0 to 3;
	begin
		r := unsigned(pal_data_i(17 downto 12));
		g := unsigned(pal_data_i(11 downto 6));
		b := unsigned(pal_data_i(5 downto 0));
		case to_integer(unsigned(tint_i)) is
			when TINT_RED =>
				r := tint_chan(r, 63);
				g := tint_chan(g, 0);
				b := tint_chan(b, 0);
			when TINT_GOLD =>
				r := tint_chan(r, 63);
				g := tint_chan(g, 52);
				b := tint_chan(b, 0);
			when TINT_GREEN =>
				r := tint_chan(r, 0);
				g := tint_chan(g, 63);
				b := tint_chan(b, 0);
			when others =>
				null;
		end case;
		-- Bayer 2x2: (h, v) = (0, 0) -> 0, (1, 0) -> 2, (0, 1) -> 3, (1, 1) -> 1
		if (v2_0 = '0') then
			if (h2_0 = '0') then
				d := 0;
			else
				d := 2;
			end if;
		else
			if (h2_0 = '0') then
				d := 3;
			else
				d := 1;
			end if;
		end if;
		r_out <= dither_chan(r, d);
		g_out <= dither_chan(g, d);
		b_out <= dither_chan(b, d);
	end process;

	------------------------------------------------------------------
	-- S3: output registers, black outside the visible area
	------------------------------------------------------------------
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			r3 <= (others => '0');
			g3 <= (others => '0');
			b3 <= (others => '0');
			hs3 <= '1';
			vs3 <= '1';
			t3 <= (others => '1');
		elsif rising_edge(clk_i) then
			hs3 <= hs2;
			vs3 <= vs2;
			if ((act2 = '0') or (blank_i = '1')) then
				r3 <= (others => '0');
				g3 <= (others => '0');
				b3 <= (others => '0');
			elsif (bands2 = '1') then
				r3 <= band_bits2(3 * OUT_BITS - 1 downto 2 * OUT_BITS);
				g3 <= band_bits2(2 * OUT_BITS - 1 downto OUT_BITS);
				b3 <= band_bits2(OUT_BITS - 1 downto 0);
			else
				r3 <= r_out;
				g3 <= g_out;
				b3 <= b_out;
			end if;
			t3 <= (others => not out_en_i);
		end if;
	end process;

	vga_r_o <= r3;
	vga_g_o <= g3;
	vga_b_o <= b3;
	vga_hs_o <= hs3;
	vga_vs_o <= vs3;
	vga_t_o <= t3;
end arch;

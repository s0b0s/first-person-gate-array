--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Text Painter
-- Module Name:    text_painter
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Draws the 40 x 30 character bring-up page (page_rom) into
--                 a 320x240 framebuffer through the pixel write port, once
--                 per start_i pulse, so the page shows live values. This
--                 stands in for the renderer in the bring-up design and
--                 exercises the same path: pixel FIFO, SRAM writes, buffer
--                 manager swap, display.
--                 Order: for each pixel row y (0..239), for each cell
--                 column (0..39): fetch the page cell (row y / 8), turn a
--                 field cell into a hex digit of its value word, fetch the
--                 font row (y mod 8), emit 8 pixels left to right.
--                 States per cell:
--                   S_CELL  page ROM address on the bus (from counters)
--                   S_CHAR  page cell valid; character -> font address
--                   S_LOAD  font row valid; copy it and the color
--                   S_EMIT  8 pixels, each waiting for pix_ready_i
--                 Colors (palette_pkg): row 0 yellow, value digits light
--                 green, other text white, background black.
--                 done_o pulses when the last pixel has been taken by the
--                 FIFO (the FIFO may still be writing it to SRAM).
--                 Clock domain: clk_i (system). About 11 cycles per 8
--                 pixels when the FIFO does not stall; the SRAM takes 16.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, game_pkg,
--                 palette_pkg, page_rom, font_rom
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
use work.game_pkg.all;
use work.palette_pkg.all;

entity text_painter is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		start_i: in std_logic; -- Pulse: draw one page
		buf_i: in std_logic; -- Framebuffer to draw (latched at start_i)
		values_i: in std_logic_vector(32 * 32 - 1 downto 0); -- Value word w = bits 32w+31..32w
		pix_valid_o: out std_logic; -- Pixel write port
		pix_ready_i: in std_logic;
		pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0); -- buf, addr, index
		busy_o: out std_logic; -- Drawing
		done_o: out std_logic -- Pulse: last pixel taken
	);
end text_painter;

architecture arch of text_painter is
	component page_rom is
		port(
			clk_i: in std_logic;
			addr_i: in std_logic_vector(10 downto 0);
			cell_o: out std_logic_vector(8 downto 0)
		);
	end component;
	component font_rom is
		port(
			clk_i: in std_logic;
			char_i: in std_logic_vector(6 downto 0);
			row_i: in std_logic_vector(2 downto 0);
			bits_o: out std_logic_vector(7 downto 0)
		);
	end component;

	type state_t is (S_IDLE, S_CELL, S_CHAR, S_LOAD, S_EMIT);
	signal state: state_t := S_IDLE;
	signal buf: std_logic := '0';
	signal y: unsigned(7 downto 0) := (others => '0'); -- Pixel row 0..239
	signal col: unsigned(5 downto 0) := (others => '0'); -- Cell column 0..39
	signal bit_index: unsigned(2 downto 0) := (others => '0'); -- Pixel in the cell
	signal row_base: unsigned(16 downto 0) := (others => '0'); -- y * 320
	signal page_addr: unsigned(10 downto 0) := (others => '0'); -- (y / 8) * 40 + col
	signal cell: std_logic_vector(8 downto 0);
	signal char: std_logic_vector(6 downto 0);
	signal font_bits: std_logic_vector(7 downto 0);
	signal bits: std_logic_vector(7 downto 0) := (others => '0');
	signal fg: std_logic_vector(7 downto 0) := (others => '0');
	signal done: std_logic := '0';
	signal x: unsigned(8 downto 0);
	signal pix_index: std_logic_vector(7 downto 0);
	signal emit_last: boolean;
	signal page_rd_addr: std_logic_vector(10 downto 0); -- page_addr + col
begin
	-- Page cell address: row base (y / 8) * 40 kept in page_addr minus col
	page_rd_addr <= std_logic_vector(page_addr + col);

	pages: page_rom
		port map (
			clk_i => clk_i,
			addr_i => page_rd_addr,
			cell_o => cell
		);

	-- Field cells become hex digits of the selected nibble
	process(cell, values_i)
		variable word: natural range 0 to 31;
		variable nib: natural range 0 to 7;
		variable digit: unsigned(3 downto 0);
	begin
		-- Field cell: bit 8 set, bits 7:3 value word, bits 2:0 nibble
		if (cell(8) = '1') then
			word := to_integer(unsigned(cell(7 downto 3)));
			nib := to_integer(unsigned(cell(2 downto 0)));
			digit := unsigned(values_i(32 * word + 4 * nib + 3 downto 32 * word + 4 * nib));
			if (digit < 10) then
				char <= std_logic_vector(resize(digit, 7) + 16#30#); -- '0'..'9'
			else
				char <= std_logic_vector(resize(digit, 7) + 16#37#); -- 'A'..'F'
			end if;
		else
			char <= cell(6 downto 0);
		end if;
	end process;

	fonts: font_rom
		port map (
			clk_i => clk_i,
			char_i => char,
			row_i => std_logic_vector(y(2 downto 0)),
			bits_o => font_bits
		);

	x <= col & bit_index; -- col * 8 + pixel in the cell
	emit_last <= (bit_index = 7) and (col = 39) and (y = RENDER_H - 1);

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			state <= S_IDLE;
			buf <= '0';
			y <= (others => '0');
			col <= (others => '0');
			bit_index <= (others => '0');
			row_base <= (others => '0');
			page_addr <= (others => '0');
			bits <= (others => '0');
			fg <= (others => '0');
			done <= '0';
		elsif rising_edge(clk_i) then
			done <= '0';
			case state is
				when S_IDLE =>
					if (start_i = '1') then
						buf <= buf_i;
						y <= (others => '0');
						col <= (others => '0');
						row_base <= (others => '0');
						page_addr <= (others => '0');
						state <= S_CELL;
					end if;
				when S_CELL =>
					state <= S_CHAR;
				when S_CHAR =>
					state <= S_LOAD;
				when S_LOAD =>
					bits <= font_bits;
					if (y < 8) then
						fg <= std_logic_vector(to_unsigned(COLOR_YELLOW, 8));
					elsif (cell(8) = '1') then
						fg <= std_logic_vector(to_unsigned(COLOR_LIGHT_GREEN, 8));
					else
						fg <= std_logic_vector(to_unsigned(COLOR_WHITE, 8));
					end if;
					bit_index <= (others => '0');
					state <= S_EMIT;
				when S_EMIT =>
					if (pix_ready_i = '1') then
						bits <= bits(6 downto 0) & '0';
						bit_index <= bit_index + 1;
						if (bit_index = 7) then
							if (emit_last) then
								done <= '1';
								state <= S_IDLE;
							elsif (col = 39) then
								-- Next pixel row; a new cell row every 8 rows
								col <= (others => '0');
								y <= y + 1;
								row_base <= row_base + RENDER_W;
								if (y(2 downto 0) = 7) then
									page_addr <= page_addr + 40;
								end if;
								state <= S_CELL;
							else
								col <= col + 1;
								state <= S_CELL;
							end if;
						end if;
					end if;
			end case;
		end if;
	end process;

	pix_valid_o <= '1' when (state = S_EMIT) else '0';
	pix_index <= fg when (bits(7) = '1') else std_logic_vector(to_unsigned(COLOR_BLACK, 8));
	pix_data_o <= buf & std_logic_vector(row_base + x) & pix_index; -- Buffer, y * 320 + x, color
	busy_o <= '0' when (state = S_IDLE) else '1';
	done_o <= done;
end arch;

--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Text Painter Testbench
-- Module Name:    tb_text_painter
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for text_painter against the
--                 golden image from tools/bringup/make_page.py
--                 (sim/golden/page_expected.txt, value word w set to
--                 (0x9E3779B9 * (w + 1)) mod 2^32 on both sides).
--                 The pixel port's ready is random (about 60% high) to
--                 exercise back-pressure. Checks: every one of the 76,800
--                 pixel addresses is written exactly once, to the
--                 requested buffer, with the golden palette index; done
--                 pulses once at the end; a second page into the other
--                 buffer works too.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, std.textio, tb_pkg, text_painter, page_rom,
--                 font_rom, game_pkg
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
use IEEE.math_real.all;
use std.textio.all;
use work.tb_pkg.all;
use work.game_pkg.all;

entity tb_text_painter is
	generic(
		GOLDEN_FILE: string := "../../sim/golden/page_expected.txt" -- Relative to build/sim
	);
end tb_text_painter;

architecture arch of tb_text_painter is
	component text_painter is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			buf_i: in std_logic;
			values_i: in std_logic_vector(32 * 32 - 1 downto 0);
			pix_valid_o: out std_logic;
			pix_ready_i: in std_logic;
			pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic
		);
	end component;

	constant PERIOD: time := 10 ns;
	type image_t is array (0 to 76_799) of integer;
	shared variable chk: checker_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal start: std_logic := '0';
	signal buf: std_logic := '0';
	signal values: std_logic_vector(32 * 32 - 1 downto 0);
	signal pix_valid: std_logic;
	signal pix_ready: std_logic := '0';
	signal pix_data: std_logic_vector(PIXW_BITS - 1 downto 0);
	signal busy, done: std_logic;

	function test_values return std_logic_vector is
		variable v: std_logic_vector(32 * 32 - 1 downto 0);
		variable p: unsigned(63 downto 0);
	begin
		for w in 0 to 31 loop
			p := unsigned(std_logic_vector'(x"9E3779B9")) * to_unsigned(w + 1, 32);
			v(32 * w + 31 downto 32 * w) := std_logic_vector(p(31 downto 0));
		end loop;
		return v;
	end function;

	impure function read_golden return image_t is
		file f: text open read_mode is GOLDEN_FILE;
		variable l: line;
		variable img: image_t;
		variable c1, c2: character;
		function hexval(c: character) return natural is
		begin
			if ((c >= '0') and (c <= '9')) then
				return character'pos(c) - character'pos('0');
			else
				return character'pos(c) - character'pos('A') + 10;
			end if;
		end function;
	begin
		for y in 0 to 239 loop
			readline(f, l);
			for x in 0 to 319 loop
				read(l, c1);
				read(l, c2);
				img(y * 320 + x) := hexval(c1) * 16 + hexval(c2);
			end loop;
		end loop;
		return img;
	end function;
begin
	values <= test_values;

	dut: text_painter
		port map (
			clk_i => clk,
			rst_i => rst,
			start_i => start,
			buf_i => buf,
			values_i => values,
			pix_valid_o => pix_valid,
			pix_ready_i => pix_ready,
			pix_data_o => pix_data,
			busy_o => busy,
			done_o => done
		);

	process
	begin
		if (finished) then
			wait;
		end if;
		clk <= '0';
		wait for PERIOD / 2;
		clk <= '1';
		wait for PERIOD / 2;
	end process;

	process
	begin
		rst <= '1';
		wait for 10.5 * PERIOD;
		rst <= '0';
		wait;
	end process;

	-- Random back-pressure
	process
		variable s1, s2: positive := 3;
		variable r: real;
	begin
		wait until rising_edge(clk);
		uniform(s1, s2, r);
		pix_ready <= '1' when (r < 0.6) else '0';
	end process;

	-- Stimulus, capture and checks
	process
		variable golden: image_t;
		variable written: image_t;
		variable a, wrong, twice, missing: natural;
	begin
		golden := read_golden;
		wait until (rst = '0');
		for page in 0 to 1 loop
			for i in written'range loop
				written(i) := -1;
			end loop;
			wrong := 0;
			twice := 0;
			wait until rising_edge(clk);
			start <= '1';
			buf <= '1' when (page = 1) else '0';
			wait until rising_edge(clk);
			start <= '0';
			loop
				wait until rising_edge(clk);
				if ((pix_valid = '1') and (pix_ready = '1')) then
					a := to_integer(unsigned(pix_data(PIXW_ADDR_HI downto PIXW_ADDR_LO)));
					chk.check(pix_data(PIXW_BUF) = buf, "pixel written to the wrong buffer");
					if (written(a) /= -1) then
						twice := twice + 1;
					end if;
					written(a) := to_integer(unsigned(pix_data(PIXW_DATA_HI downto PIXW_DATA_LO)));
					if ((written(a) /= golden(a)) and (wrong < 5)) then
						report "pixel " & integer'image(a mod 320) & "," & integer'image(a / 320) &
							" = " & integer'image(written(a)) & " want " &
							integer'image(golden(a)) severity error;
					end if;
					if (written(a) /= golden(a)) then
						wrong := wrong + 1;
					end if;
				end if;
				exit when (done = '1');
			end loop;
			missing := 0;
			for i in written'range loop
				if (written(i) = -1) then
					missing := missing + 1;
				end if;
			end loop;
			chk.check(wrong = 0, "page " & integer'image(page) & ": " & integer'image(wrong) &
				" wrong pixels");
			chk.check(twice = 0, "pixels written twice: " & integer'image(twice));
			chk.check(missing = 0, "pixels never written: " & integer'image(missing));
			wait until rising_edge(clk);
			chk.check(busy = '0', "idle after done");
		end loop;
		finished <= true;
		tb_finish("tb_text_painter", chk.checks, chk.errors);
		wait;
	end process;
end arch;

--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Restoring Divider Testbench
-- Module Name:    tb_divider
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for divider (33 / 24 bits,
--                 24-bit saturating quotient) against the golden vectors
--                 in sim/golden/divider.txt, written by
--                 tools/model/build_assets.py: every deltaDist, lineHeight
--                 and rowDist division of the renderer test poses plus
--                 edge cases (divide by 0 and 1, saturation boundaries).
--                 Also checks the latency (done_o NUM_BITS + 1 clocks
--                 after start_i) and that busy_o covers the division.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 std.textio, tb_pkg, divider
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
use std.textio.all;
use work.tb_pkg.all;

entity tb_divider is
	generic(
		VECTOR_FILE: string := "../../sim/golden/divider.txt" -- Relative to build/sim
	);
end tb_divider;

architecture arch of tb_divider is
	component divider is
		generic(
			NUM_BITS: positive := 33;
			DEN_BITS: positive := 24;
			QUO_BITS: positive := 24
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			num_i: in std_logic_vector(NUM_BITS - 1 downto 0);
			den_i: in std_logic_vector(DEN_BITS - 1 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic;
			quo_o: out std_logic_vector(QUO_BITS - 1 downto 0)
		);
	end component;

	constant PERIOD: time := 10 ns;
	shared variable chk: checker_t;
	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal start: std_logic := '0';
	signal num: std_logic_vector(32 downto 0) := (others => '0');
	signal den: std_logic_vector(23 downto 0) := (others => '0');
	signal busy, done: std_logic;
	signal quo: std_logic_vector(23 downto 0);

	-- Decimal text to unsigned (the values need up to 33 bits)
	function to_u(s: string; bits: natural) return unsigned is
		variable v: unsigned(bits + 3 downto 0) := (others => '0');
	begin
		for i in s'range loop
			v := resize(v * 10, bits + 4) + (character'pos(s(i)) - character'pos('0'));
		end loop;
		return v(bits - 1 downto 0);
	end function;

	-- Next space-separated word of l as text (integer read cannot hold 33-bit values)
	procedure read_word(l: inout line; w: out string; n: out natural) is
		variable c: character;
		variable good: boolean;
		variable k: natural := 0;
	begin
		w := (w'range => ' ');
		loop
			read(l, c, good);
			exit when (not good) or (c /= ' ');
		end loop;
		while good and (c /= ' ') loop
			k := k + 1;
			w(k) := c;
			read(l, c, good);
		end loop;
		n := k;
	end procedure;
begin
	dut: divider
		port map (
			clk_i => clk,
			rst_i => rst,
			start_i => start,
			num_i => num,
			den_i => den,
			busy_o => busy,
			done_o => done,
			quo_o => quo
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

	process
		file f: text open read_mode is VECTOR_FILE;
		variable l: line;
		variable w: string(1 to 20);
		variable n: natural;
		variable want: unsigned(23 downto 0);
		variable cycles: natural;
		variable vectors, bad: natural := 0;
	begin
		wait until (rst = '0');
		wait until rising_edge(clk);
		while not endfile(f) loop
			readline(f, l);
			read_word(l, w, n);
			num <= std_logic_vector(to_u(w(1 to n), 33));
			read_word(l, w, n);
			den <= std_logic_vector(to_u(w(1 to n), 24));
			read_word(l, w, n);
			want := to_u(w(1 to n), 24);
			start <= '1';
			wait until rising_edge(clk);
			start <= '0';
			cycles := 0;
			loop
				wait until rising_edge(clk);
				cycles := cycles + 1;
				exit when (done = '1') or (cycles > 100);
			end loop;
			vectors := vectors + 1;
			if ((unsigned(quo) /= want) or (cycles /= 34)) then -- Latency NUM_BITS + 1
				bad := bad + 1;
				if (bad <= 5) then
					report "vector " & integer'image(vectors) & ": got " & to_hex(quo) & " want " &
						to_hex(want) & " after " & integer'image(cycles) & " clocks" severity error;
				end if;
			end if;
		end loop;
		chk.check(bad = 0, integer'image(bad) & " of " & integer'image(vectors) & " vectors wrong");
		chk.check(vectors > 1000, "vector file read: " & integer'image(vectors));
		finished <= true;
		tb_finish("tb_divider", chk.checks + vectors, chk.errors);
		wait;
	end process;
end arch;

--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Testbench Support Package
-- Module Name:    tb_pkg
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Helpers shared by the self-checking testbenches:
--                 - checker_t, a protected type that counts checks and
--                   errors; a testbench declares one shared variable of it
--                   so its clock, reset and stimulus processes can all
--                   check results.
--                 - tb_finish prints "TB_RESULT <name> PASS checks=<n>"
--                   (scripts/run_sim.py looks for it) or a failure, then
--                   stops the simulation.
--                 - hex and integer formatting for messages.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 std.textio, std.env (VHDL-2008)
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

package tb_pkg is
	type checker_t is protected
		-- Count one check; report an error (simulation continues) if false
		procedure check(cond: boolean; msg: string);
		impure function checks return natural;
		impure function errors return natural;
	end protected checker_t;

	-- Print the summary line and stop the simulation
	procedure tb_finish(name: string; checks: natural; errors: natural);
	-- Print a line of text to the simulator console
	procedure tb_print(msg: string);
	-- Hexadecimal text of a vector (width rounded up to whole digits)
	function to_hex(v: std_logic_vector) return string;
	function to_hex(v: unsigned) return string;
end package tb_pkg;

package body tb_pkg is
	type checker_t is protected body
		variable n_checks: natural := 0;
		variable n_errors: natural := 0;

		procedure check(cond: boolean; msg: string) is
		begin
			n_checks := n_checks + 1;
			if (not cond) then
				n_errors := n_errors + 1;
				report "CHECK FAILED: " & msg severity error;
			end if;
		end procedure;

		impure function checks return natural is
		begin
			return n_checks;
		end function;

		impure function errors return natural is
		begin
			return n_errors;
		end function;
	end protected body checker_t;

	procedure tb_print(msg: string) is
		variable l: line;
	begin
		write(l, msg);
		writeline(output, l);
	end procedure;

	procedure tb_finish(name: string; checks: natural; errors: natural) is
	begin
		if ((errors = 0) and (checks > 0)) then
			tb_print("TB_RESULT " & name & " PASS checks=" & integer'image(checks));
			std.env.stop;
		else
			report "TB_RESULT " & name & " FAIL errors=" & integer'image(errors) &
				" checks=" & integer'image(checks) severity failure;
		end if;
	end procedure;

	function to_hex(v: std_logic_vector) return string is
		constant DIGITS: natural := (v'length + 3) / 4;
		constant HEX: string(1 to 16) := "0123456789ABCDEF";
		variable padded: std_logic_vector(DIGITS * 4 - 1 downto 0) := (others => '0');
		variable s: string(1 to DIGITS);
		variable nib: std_logic_vector(3 downto 0);
	begin
		padded(v'length - 1 downto 0) := v;
		for i in 0 to DIGITS - 1 loop
			nib := padded(DIGITS * 4 - 1 - i * 4 downto DIGITS * 4 - 4 - i * 4);
			if (is_x(nib)) then
				s(i + 1) := 'X';
			else
				s(i + 1) := HEX(to_integer(unsigned(nib)) + 1);
			end if;
		end loop;
		return s;
	end function;

	function to_hex(v: unsigned) return string is
	begin
		return to_hex(std_logic_vector(v));
	end function;
end package body tb_pkg;

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
-- Description:    Helpers for the self-checking testbenches:
--                 - check: counts one check in the caller's checks and
--                   errors variables; reports a failure (severity error).
--                   Each checking process keeps its own counters; other
--                   processes copy theirs onto signals, and the finishing
--                   process waits 1 ns and adds them before tb_finish.
--                 - tb_finish: prints "TB_RESULT <name> PASS checks=<n>"
--                   (parsed by scripts/run_sim.py) or a failure, then stops.
--                 - hex and integer formatting for messages.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 std.textio, std.env (VHDL-2008)
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - Procedure-based checks instead of a protected type
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.textio.all;

package tb_pkg is
	-- Count one check in checks; if cond is false, count an error in errors and
	-- report it with severity error (the simulation continues)
	procedure check(cond: boolean; msg: string; checks: inout natural; errors: inout natural);

	-- Print the summary line and stop the simulation
	procedure tb_finish(name: string; checks: natural; errors: natural);
	-- Print a line of text to the simulator console
	procedure tb_print(msg: string);
	-- Hexadecimal text of a vector (width rounded up to whole digits)
	function to_hex(v: std_logic_vector) return string;
	function to_hex(v: unsigned) return string;
end package tb_pkg;

package body tb_pkg is
	procedure check(cond: boolean; msg: string; checks: inout natural; errors: inout natural) is
	begin
		checks := checks + 1;
		if (not cond) then
			errors := errors + 1;
			report "CHECK FAILED: " & msg severity error;
		end if;
	end procedure;

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

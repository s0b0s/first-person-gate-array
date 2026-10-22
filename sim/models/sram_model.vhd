--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    SRAM Model
-- Module Name:    sram_model
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Behavioral model of the ISSI IS61WV5128BLL-10 (512 K x 8
--                 asynchronous SRAM, 10 ns grade) with the datasheet
--                 timing the controller is designed around:
--                 Read: data is 'X' from tOHA (2 ns) after an address
--                   change until tAA (10 ns), and 'X' until tDOE (4.5 ns)
--                   after OE_n falls. The output keeps driving for tHZOE
--                   (4 ns) after OE_n rises or WE_n falls, so a driver
--                   that turns on too early shows up as contention.
--                 Write (WE controlled, data latched when WE_n rises):
--                   checks tPWE >= 8 ns, tSD >= 6 ns, tAW >= 8 ns, and
--                   that the address does not move while WE_n is low.
--                 driving_o tells the testbench when the model drives the
--                 bus so it can flag contention with the FPGA's drivers.
--                 Timing errors use severity error and are counted in
--                 errors_o.
--                 The storage is the shared variable sram_mem in
--                 sram_model_pkg, so a testbench can preload or inspect
--                 memory directly (one SRAM model per simulation).
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

package sram_model_pkg is
	-- Storage shared between the model and testbench back-door access
	type sram_mem_t is protected
		procedure write(addr: natural; data: std_logic_vector(7 downto 0));
		impure function read(addr: natural) return std_logic_vector;
	end protected sram_mem_t;
	-- The one SRAM in the system; testbenches may read and write it
	-- directly (back door) to preload or check memory.
	shared variable sram_mem: sram_mem_t;
end package sram_model_pkg;

package body sram_model_pkg is
	type sram_mem_t is protected body
		type mem_array_t is array (0 to 2 ** 19 - 1) of std_logic_vector(7 downto 0);
		variable mem: mem_array_t := (others => (others => 'U'));

		procedure write(addr: natural; data: std_logic_vector(7 downto 0)) is
		begin
			mem(addr) := data;
		end procedure;

		impure function read(addr: natural) return std_logic_vector is
		begin
			return mem(addr);
		end function;
	end protected body sram_mem_t;
end package body sram_model_pkg;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.sram_model_pkg.all;

entity sram_model is
	-- Defaults: the IS61WV5128BLL-10 datasheet (10 ns grade)
	generic(
		T_AA: time := 10 ns; -- Address access
		T_OHA: time := 2 ns; -- Output hold after address change
		T_DOE: time := 4.5 ns; -- OE_n low to data valid
		T_HZOE: time := 4 ns; -- OE_n high to high-Z
		T_HZWE: time := 5 ns; -- WE_n low to high-Z
		T_PWE: time := 8 ns; -- WE_n pulse width
		T_SD: time := 6 ns; -- Data setup to WE_n rising
		T_AW: time := 8 ns -- Address valid to WE_n rising
	);
	port(
		a_i: in std_logic_vector(18 downto 0); -- Address
		dq_io: inout std_logic_vector(7 downto 0); -- Data
		ce_n_i: in std_logic; -- Chip enable, active low
		oe_n_i: in std_logic; -- Output enable, active low
		we_n_i: in std_logic; -- Write enable, active low
		driving_o: out boolean; -- Model drives dq_io now
		errors_o: out natural -- Timing violations seen so far
	);
end sram_model;

architecture arch of sram_model is
	signal a_settled: std_logic_vector(18 downto 0) := (others => '0');
	signal a_valid: std_logic := '0'; -- '0' between tOHA and tAA
	signal oe_valid: std_logic := '0'; -- '0' until tDOE after OE_n falls
	signal out_on: std_logic;
	signal drive: std_logic := '0';
	signal mem_tick: boolean := false; -- Flips on every write
	signal timing_errors: natural := 0;
begin
	-- Address timing: old data until tOHA, 'X' until tAA, then new data
	-- transport keeps both scheduled edges (inertial delay would swallow the tOHA one)
	process(a_i)
	begin
		a_valid <= transport '0' after T_OHA;
		a_valid <= transport '1' after T_AA;
		a_settled <= transport a_i after T_AA;
	end process;

	process(oe_n_i)
	begin
		if (oe_n_i = '0') then
			oe_valid <= '0';
			oe_valid <= transport '1' after T_DOE;
		else
			oe_valid <= '0';
		end if;
	end process;

	out_on <= '1' when ((ce_n_i = '0') and (oe_n_i = '0') and (we_n_i = '1')) else '0';

	-- The output turns on at once (tLZOE = 0) but stays on for tHZOE (or
	-- tHZWE when WE_n caused it) after it is disabled.
	-- Runs on out_on changes only; WE_n is sampled then to pick the turn-off delay
	process
	begin
		if (out_on = '1') then
			drive <= transport '1';
		elsif (we_n_i = '0') then
			drive <= transport '0' after T_HZWE;
		else
			drive <= transport '0' after T_HZOE;
		end if;
		wait on out_on;
	end process;

	-- Data out: 'Z' when not driving, 'X' while tAA or tDOE is not met, else the byte;
	-- mem_tick re-reads after a write to the address being shown
	process(drive, out_on, a_valid, oe_valid, a_settled, mem_tick)
	begin
		if (drive = '0') then
			dq_io <= (others => 'Z');
		elsif ((out_on = '0') or (a_valid = '0') or (oe_valid = '0') or
			(is_x(a_settled))) then
			dq_io <= (others => 'X');
		else
			dq_io <= sram_mem.read(to_integer(unsigned(a_settled)));
		end if;
	end process;

	driving_o <= (drive = '1');

	-- Writes and write timing checks
	process
		variable t_we_fall: time := 0 ns;
		variable t_addr: time := 0 ns;
		variable t_dq: time := 0 ns;
		variable errs: natural := 0;
		variable a_at_fall: std_logic_vector(18 downto 0);
	begin
		wait on a_i, dq_io, we_n_i;
		if (a_i'event) then
			t_addr := now;
			-- (address and WE_n rising together ends a write and is allowed)
			if ((we_n_i = '0') and (ce_n_i = '0') and (not we_n_i'event)) then
				errs := errs + 1;
				report "SRAM model: address changed while WE_n low" severity error;
			end if;
		end if;
		if (dq_io'event) then
			t_dq := now;
		end if;
		if (we_n_i'event and (we_n_i = '0') and (we_n_i'last_value = '1')) then
			t_we_fall := now;
			a_at_fall := a_i;
		end if;
		-- Only a real '0' to '1' edge ends a write (not 'U' to '1' at power-up)
		if (we_n_i'event and (we_n_i = '1') and (we_n_i'last_value = '0') and
			(ce_n_i = '0')) then
			if (now - t_we_fall < T_PWE) then
				errs := errs + 1;
				report "SRAM model: tPWE violated, WE_n low for " &
					time'image(now - t_we_fall) severity error;
			end if;
			if (now - t_dq < T_SD) then
				errs := errs + 1;
				report "SRAM model: tSD violated, data stable for " &
					time'image(now - t_dq) severity error;
			end if;
			if (now - t_addr < T_AW) then
				errs := errs + 1;
				report "SRAM model: tAW violated, address stable for " &
					time'image(now - t_addr) severity error;
			end if;
			if (a_i /= a_at_fall) then
				errs := errs + 1;
				report "SRAM model: address moved during the write" severity error;
			end if;
			if (is_x(a_i)) then
				errs := errs + 1;
				report "SRAM model: write to an unknown address" severity error;
			else
				sram_mem.write(to_integer(unsigned(a_i)), dq_io);
				mem_tick <= not mem_tick;
			end if;
		end if;
		timing_errors <= errs;
	end process;

	errors_o <= timing_errors;
end arch;

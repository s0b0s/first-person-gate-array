--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    SRAM Controller
-- Module Name:    sram_controller
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Drives the Cmod's IS61WV5128BLL-10 asynchronous SRAM at
--                 CYCLES system clocks per access (2 at 100 MHz = 20 ns).
--                 One access may start on every CYCLES-th edge; commands
--                 arrive on a valid/ready port (from sram_arbiter) with a
--                 tag that comes back with the read data.
--
--                 Waveform of a write starting at edge E0 (CYCLES = 2):
--                   E0         E0+5ns     E1         E1+5ns     E2
--                   |  addr, data out, bus driven (T = 0)        |
--                   |  WE_n high | WE_n low             | high   |
--                 WE_n comes from an ODDR (SAME_EDGE mode) so it falls at
--                 E0 + 5 ns and rises at E1 + 5 ns: a 10 ns pulse (tPWE
--                 8 ns), with 5 ns of address setup before it and 5 ns of
--                 address and data hold after it.
--                 Read starting at E0: address out at E0, OE_n low (from
--                 E0 + 5 ns after a write or idle, so the FPGA's bus
--                 driver is off first), data captured by the IOB register
--                 on clk_sram_rd at E2 + 1.04 ns, then moved into clk_sys
--                 at E3. The late capture moves spare time from read hold
--                 to read setup (checked by hand: setup slack +3.2 ns,
--                 hold slack +1.6 ns; the numbers are in the XDC).
--                 A write may not start on the edge that ends a read: one
--                 idle cycle lets the SRAM release the bus (tHZOE 4 ns)
--                 before the FPGA drives it.
--
--                 Every SRAM-facing register is meant for the IOB (IOB
--                 attribute here, IOB TRUE in the XDC). CE_n is held low.
--                 The data bus is split into dq_o / dq_t_o / dq_i; the
--                 top level makes the tristate buffer ('1' on dq_t_o =
--                 high impedance, power-on value '1').
--
--                 Clock domains: clk_i (system) for everything except
--                 the read capture register on clk_rd_i (same frequency,
--                 fixed +37.5 deg phase, timed as related clocks).
--                 Throughput: one access per CYCLES clocks (50 M/s).
--                 Read latency: rsp_valid_o is high CYCLES + 2 cycles
--                 after the cycle in which the command was accepted
--                 (4 cycles at CYCLES = 2). Reads return in order.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, UNISIM,
--                 UNISIM (ODDR)
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 CYCLES must be 2 or 3.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library UNISIM;
use UNISIM.vcomponents.all;

entity sram_controller is
	generic(
		CYCLES: positive := 2; -- System clocks per access (2 or 3)
		TAG_BITS: positive := 2 -- Width of the command tag
	);
	port(
		clk_i: in std_logic; -- System clock, 100 MHz
		clk_rd_i: in std_logic; -- Read capture clock, 100 MHz +37.5 deg
		rst_i: in std_logic; -- Asynchronous reset, active high
		-- Command port
		cmd_valid_i: in std_logic; -- Command present
		cmd_ready_o: out std_logic; -- Command accepted this cycle if valid
		cmd_we_i: in std_logic; -- '1' write, '0' read
		cmd_addr_i: in std_logic_vector(18 downto 0); -- Byte address
		cmd_wdata_i: in std_logic_vector(7 downto 0); -- Write data
		cmd_tag_i: in std_logic_vector(TAG_BITS - 1 downto 0); -- Returned with read data
		-- Read response
		rsp_valid_o: out std_logic; -- Read data valid (one cycle)
		rsp_data_o: out std_logic_vector(7 downto 0); -- Read data
		rsp_tag_o: out std_logic_vector(TAG_BITS - 1 downto 0); -- Tag of the read
		busy_o: out std_logic; -- An access occupies this cycle
		-- SRAM pins
		sram_a_o: out std_logic_vector(18 downto 0); -- Address
		sram_dq_o: out std_logic_vector(7 downto 0); -- Data out
		sram_dq_t_o: out std_logic_vector(7 downto 0); -- '1' = data bus released
		sram_dq_i: in std_logic_vector(7 downto 0); -- Data in (from the pad)
		sram_oe_n_o: out std_logic; -- Output enable, active low
		sram_we_n_o: out std_logic; -- Write enable, active low
		sram_ce_n_o: out std_logic -- Chip enable, active low
	);
end sram_controller;

architecture arch of sram_controller is
	-- Access sequencer: act = an access occupies this cycle, ph = its phase
	signal act: std_logic := '0';
	signal act_next: std_logic;
	signal ph: natural range 0 to CYCLES - 1 := 0;
	signal ph_next: natural range 0 to CYCLES - 1;
	signal cur_we: std_logic := '0';
	signal cur_we_next: std_logic;
	signal start: std_logic;
	signal ready: std_logic;

	-- IOB registers
	signal a_q: std_logic_vector(18 downto 0) := (others => '0');
	signal dq_o_q: std_logic_vector(7 downto 0) := (others => '0');
	signal dq_t_q: std_logic_vector(7 downto 0) := (others => '1');
	signal cap_q: std_logic_vector(7 downto 0) := (others => '0');
	attribute IOB: string;
	attribute IOB of a_q: signal is "TRUE";
	attribute IOB of dq_o_q: signal is "TRUE";
	attribute IOB of dq_t_q: signal is "TRUE";
	attribute IOB of cap_q: signal is "TRUE";

	-- ODDR inputs for the cycle that starts at the next edge
	signal we_d1: std_logic;
	signal we_d2: std_logic;
	signal oe_d1: std_logic;
	signal oe_d2: std_logic;

	-- Read return: rd_pipe(k) is set k edges after a read started
	signal rd_pipe: std_logic_vector(CYCLES + 1 downto 0) := (others => '0');
	type tag_pipe_t is array (0 to CYCLES + 1) of std_logic_vector(TAG_BITS - 1 downto 0);
	signal tag_pipe: tag_pipe_t := (others => (others => '0'));
	signal rd_data: std_logic_vector(7 downto 0) := (others => '0');
begin
	------------------------------------------------------------------
	-- Next-state logic (two-segment style)
	------------------------------------------------------------------
	-- A new access can start at the next edge when nothing is in progress
	-- or the current access is in its last phase. A write may not start
	-- on the edge that ends a read (bus turnaround).
	process(act, ph, cur_we, cmd_we_i)
	begin
		if ((act = '0') or (ph = CYCLES - 1)) then
			if ((act = '1') and (cur_we = '0') and (cmd_we_i = '1')) then
				ready <= '0';
			else
				ready <= '1';
			end if;
		else
			ready <= '0';
		end if;
	end process;

	start <= cmd_valid_i and ready;

	process(start, act, ph, cur_we, cmd_we_i)
	begin
		if (start = '1') then
			act_next <= '1';
			ph_next <= 0;
			cur_we_next <= cmd_we_i;
		elsif ((act = '1') and (ph /= CYCLES - 1)) then
			act_next <= '1';
			ph_next <= ph + 1;
			cur_we_next <= cur_we;
		else
			act_next <= '0';
			ph_next <= 0;
			cur_we_next <= cur_we;
		end if;
	end process;

	-- WE_n and OE_n patterns for the cycle after the next edge. D1 is the
	-- first half of that cycle, D2 the second half.
	process(act_next, ph_next, cur_we_next, act, cur_we)
	begin
		we_d1 <= '1';
		we_d2 <= '1';
		oe_d1 <= '1';
		oe_d2 <= '1';
		if (act_next = '1') then
			if (cur_we_next = '1') then
				-- WE_n low from the middle of the first cycle to the middle
				-- of the last cycle
				if (ph_next /= 0) then
					we_d1 <= '0';
				end if;
				if (ph_next /= CYCLES - 1) then
					we_d2 <= '0';
				end if;
			else
				-- OE_n low for the whole read, except the first half cycle
				-- when the bus was not already in a read
				oe_d2 <= '0';
				if ((ph_next /= 0) or ((act = '1') and (cur_we = '0'))) then
					oe_d1 <= '0';
				end if;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Registers
	------------------------------------------------------------------
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			act <= '0';
			ph <= 0;
			cur_we <= '0';
		elsif rising_edge(clk_i) then
			act <= act_next;
			ph <= ph_next;
			cur_we <= cur_we_next;
		end if;
	end process;

	-- Address and data out load when an access starts; the bus is driven
	-- for exactly the cycles of a write.
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			a_q <= (others => '0');
			dq_o_q <= (others => '0');
			dq_t_q <= (others => '1');
		elsif rising_edge(clk_i) then
			if (start = '1') then
				a_q <= cmd_addr_i;
				dq_o_q <= cmd_wdata_i;
			end if;
			dq_t_q <= (others => not (act_next and cur_we_next)); -- '0' drives the bus (writes only)
		end if;
	end process;

	we_oddr: ODDR
		generic map (
			DDR_CLK_EDGE => "SAME_EDGE", -- D1 and D2 both sampled on the rising edge
			INIT => '1',
			SRTYPE => "ASYNC"
		)
		port map (
			Q => sram_we_n_o,
			C => clk_i,
			CE => '1',
			D1 => we_d1,
			D2 => we_d2,
			R => '0',
			S => rst_i
		);

	oe_oddr: ODDR
		generic map (
			DDR_CLK_EDGE => "SAME_EDGE",
			INIT => '1',
			SRTYPE => "ASYNC"
		)
		port map (
			Q => sram_oe_n_o,
			C => clk_i,
			CE => '1',
			D1 => oe_d1,
			D2 => oe_d2,
			R => '0',
			S => rst_i
		);

	-- Read capture in the IOB on the late clock. It samples every cycle;
	-- rd_pipe picks out the samples that belong to reads.
	process(clk_rd_i)
	begin
		if rising_edge(clk_rd_i) then
			cap_q <= sram_dq_i;
		end if;
	end process;

	-- An access started at edge E0 ends at E0 + CYCLES; its data is in
	-- cap_q 1.04 ns later and in rd_data after edge E0 + CYCLES + 1,
	-- the same edge that sets rd_pipe(CYCLES + 1).
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			rd_pipe <= (others => '0');
			tag_pipe <= (others => (others => '0'));
			rd_data <= (others => '0');
		elsif rising_edge(clk_i) then
			rd_pipe <= rd_pipe(CYCLES downto 0) & (start and not cmd_we_i);
			tag_pipe(0) <= cmd_tag_i;
			for k in 1 to CYCLES + 1 loop
				tag_pipe(k) <= tag_pipe(k - 1);
			end loop;
			rd_data <= cap_q;
		end if;
	end process;

	cmd_ready_o <= ready;
	rsp_valid_o <= rd_pipe(CYCLES + 1);
	rsp_data_o <= rd_data;
	rsp_tag_o <= tag_pipe(CYCLES + 1);
	busy_o <= act;
	sram_a_o <= a_q;
	sram_dq_o <= dq_o_q;
	sram_dq_t_o <= dq_t_q;
	sram_ce_n_o <= '0';
end arch;

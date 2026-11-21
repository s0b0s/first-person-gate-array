--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    SRAM Port Multiplexer Testbench
-- Module Name:    tb_sram_port_mux
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for sram_port_mux. Two clients
--                 issue OPS random reads and writes to their own 256-byte
--                 regions (A 0..255, B 256..511), back to back or with random
--                 gaps, without waiting for read data. The master port model
--                 grants with GNT_PCT probability per clock (combinationally,
--                 like sram_arbiter) and returns data LAT clocks after the
--                 grant. The read checker shadows both regions and queues the
--                 byte of each granted read per client.
--                 Checks: every rvalid matches the head of its client's queue
--                 (client, order, byte); none with an empty queue; both
--                 clients finish (no starvation); every read returns.
--                 RUN_VARIANTS: LAT=2 LAT=5
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, tb_pkg, sram_port_mux
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - Procedure-based checks instead of a protected type;
--                 read queues kept by the read checker, filled at grant
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.math_real.all;
use work.tb_pkg.all;

entity tb_sram_port_mux is
	generic(
		LAT: positive := 4; -- Clocks from grant to rvalid
		GNT_PCT: natural := 60; -- Grant probability per clock, percent
		OPS: positive := 3000 -- Operations per client
	);
end tb_sram_port_mux;

architecture arch of tb_sram_port_mux is
	component sram_port_mux is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			a_req_i: in std_logic;
			a_we_i: in std_logic;
			a_addr_i: in std_logic_vector(18 downto 0);
			a_wdata_i: in std_logic_vector(7 downto 0);
			a_gnt_o: out std_logic;
			a_rvalid_o: out std_logic;
			b_req_i: in std_logic;
			b_we_i: in std_logic;
			b_addr_i: in std_logic_vector(18 downto 0);
			b_wdata_i: in std_logic_vector(7 downto 0);
			b_gnt_o: out std_logic;
			b_rvalid_o: out std_logic;
			m_req_o: out std_logic;
			m_we_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_wdata_o: out std_logic_vector(7 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic
		);
	end component;

	constant PERIOD: time := 10 ns;

	type mem_t is array (0 to 511) of natural range 0 to 255;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal a_req, a_we, b_req, b_we: std_logic := '0';
	signal a_addr, b_addr: std_logic_vector(18 downto 0) := (others => '0');
	signal a_wdata, b_wdata: std_logic_vector(7 downto 0) := (others => '0');
	signal a_gnt, a_rvalid, b_gnt, b_rvalid: std_logic;
	signal m_req, m_we, m_gnt: std_logic;
	signal m_addr: std_logic_vector(18 downto 0);
	signal m_wdata: std_logic_vector(7 downto 0);
	signal gnt_ok: std_logic := '0';
	signal m_rvalid: std_logic := '0';
	signal m_rdata: std_logic_vector(7 downto 0) := (others => '0');
	signal a_done, b_done: boolean := false;
	signal a_reads, b_reads: natural := 0; -- Reads checked
	signal a_pending, b_pending: natural := 0; -- Reads granted but not yet returned
	signal rd_checks, rd_errors: natural := 0; -- Read checker check counts

	-- One client: OPS random operations on region BASE .. BASE + 255
	procedure client(constant BASE: natural; constant SEED: positive;
		signal req: out std_logic; signal we: out std_logic;
		signal addr: out std_logic_vector(18 downto 0); signal wdata: out std_logic_vector(7 downto 0);
		signal gnt: in std_logic; signal clk: in std_logic; signal done: out boolean) is
		variable s1, s2: positive := SEED;
		variable x: real;
		variable a, d: natural;
		variable w: boolean;
	begin
		for n in 1 to OPS loop
			-- Random idle gap (half the time none: back-to-back requests)
			uniform(s1, s2, x);
			if (x < 0.3) then
				uniform(s1, s2, x);
				for i in 1 to integer(x * 6.0) loop
					wait until rising_edge(clk);
				end loop;
			end if;
			uniform(s1, s2, x);
			a := integer(floor(x * 256.0)) mod 256;
			uniform(s1, s2, x);
			w := x < 0.4;
			uniform(s1, s2, x);
			d := integer(floor(x * 256.0)) mod 256;
			req <= '1';
			addr <= std_logic_vector(to_unsigned(BASE + a, 19));
			wdata <= std_logic_vector(to_unsigned(d, 8));
			we <= '1' when w else '0';
			loop
				wait until rising_edge(clk);
				exit when (gnt = '1');
			end loop;
			req <= '0';
			we <= '0';
		end loop;
		done <= true;
	end procedure;
begin
	dut: sram_port_mux
		port map (
			clk_i => clk,
			rst_i => rst,
			a_req_i => a_req,
			a_we_i => a_we,
			a_addr_i => a_addr,
			a_wdata_i => a_wdata,
			a_gnt_o => a_gnt,
			a_rvalid_o => a_rvalid,
			b_req_i => b_req,
			b_we_i => b_we,
			b_addr_i => b_addr,
			b_wdata_i => b_wdata,
			b_gnt_o => b_gnt,
			b_rvalid_o => b_rvalid,
			m_req_o => m_req,
			m_we_o => m_we,
			m_addr_o => m_addr,
			m_wdata_o => m_wdata,
			m_gnt_i => m_gnt,
			m_rvalid_i => m_rvalid
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

	-- Master port model: random grants, memory, read data LAT clocks later
	process
		variable s1, s2: positive := 7;
		variable x: real;
	begin
		wait until rising_edge(clk);
		uniform(s1, s2, x);
		if (x * 100.0 < real(GNT_PCT)) then
			gnt_ok <= '1';
		else
			gnt_ok <= '0';
		end if;
	end process;

	m_gnt <= m_req and gnt_ok;

	process
		type pipe_t is array (1 to LAT) of integer;
		variable mem: mem_t := (others => 0);
		variable pipe: pipe_t := (others => -1);
		variable a: natural;
	begin
		wait until rising_edge(clk);
		if (pipe(LAT) >= 0) then
			m_rvalid <= '1';
			m_rdata <= std_logic_vector(to_unsigned(pipe(LAT), 8));
		else
			m_rvalid <= '0';
			m_rdata <= (others => 'X');
		end if;
		for k in LAT downto 2 loop
			pipe(k) := pipe(k - 1);
		end loop;
		pipe(1) := -1;
		if (m_gnt = '1') then
			a := to_integer(unsigned(m_addr));
			if (m_we = '1') then
				mem(a) := to_integer(unsigned(m_wdata));
			else
				pipe(1) := mem(a);
			end if;
		end if;
	end process;

	-- Read data checks: a granted write updates the client's shadow, a
	-- granted read queues its byte (64-entry ring per client). Data comes
	-- back at least 2 clocks after its grant, so returned bytes leave the
	-- queues before this edge's grants are added.
	process(clk)
		type queue_t is array (0 to 63) of natural;
		variable shadow: mem_t := (others => 0);
		variable qa, qb: queue_t;
		variable a_head, a_count, b_head, b_count: natural := 0;
		variable want: integer;
		variable checks, errors: natural := 0;
	begin
		if rising_edge(clk) then
			if (a_rvalid = '1') then
				want := -1; -- Nothing expected: the check fails
				if (a_count > 0) then
					want := qa(a_head);
					a_head := (a_head + 1) mod 64;
					a_count := a_count - 1;
				end if;
				check(want = to_integer(unsigned(m_rdata)), "client A read: got " &
					to_hex(m_rdata) & ", want " & integer'image(want), checks, errors);
				a_reads <= a_reads + 1;
			end if;
			if (b_rvalid = '1') then
				want := -1;
				if (b_count > 0) then
					want := qb(b_head);
					b_head := (b_head + 1) mod 64;
					b_count := b_count - 1;
				end if;
				check(want = to_integer(unsigned(m_rdata)), "client B read: got " &
					to_hex(m_rdata) & ", want " & integer'image(want), checks, errors);
				b_reads <= b_reads + 1;
			end if;
			if ((a_req = '1') and (a_gnt = '1')) then
				if (a_we = '1') then
					shadow(to_integer(unsigned(a_addr))) := to_integer(unsigned(a_wdata));
				else
					qa((a_head + a_count) mod 64) := shadow(to_integer(unsigned(a_addr)));
					a_count := a_count + 1;
				end if;
			end if;
			if ((b_req = '1') and (b_gnt = '1')) then
				if (b_we = '1') then
					shadow(to_integer(unsigned(b_addr))) := to_integer(unsigned(b_wdata));
				else
					qb((b_head + b_count) mod 64) := shadow(to_integer(unsigned(b_addr)));
					b_count := b_count + 1;
				end if;
			end if;
			a_pending <= a_count;
			b_pending <= b_count;
			rd_checks <= checks;
			rd_errors <= errors;
		end if;
	end process;

	process
	begin
		wait until (rst = '0');
		wait until rising_edge(clk);
		client(0, 11, a_req, a_we, a_addr, a_wdata, a_gnt, clk, a_done);
		wait;
	end process;

	process
	begin
		wait until (rst = '0');
		wait until rising_edge(clk);
		client(256, 29, b_req, b_we, b_addr, b_wdata, b_gnt, clk, b_done);
		wait;
	end process;

	-- Finish: both clients done, every read returned
	process
		variable checks, errors: natural := 0;
	begin
		wait until (rst = '0');
		wait until (a_done and b_done) for 10 ms;
		check(a_done and b_done, "both clients finished (no starvation)", checks, errors);
		for i in 1 to LAT + 4 loop
			wait until rising_edge(clk);
		end loop;
		check(a_pending = 0, "client A: " & integer'image(a_pending) & " reads not returned",
			checks, errors);
		check(b_pending = 0, "client B: " & integer'image(b_pending) & " reads not returned",
			checks, errors);
		check((a_reads > OPS / 3) and (b_reads > OPS / 3), "reads checked: A " &
			integer'image(a_reads) & ", B " & integer'image(b_reads), checks, errors);
		finished <= true;
		wait for 1 ns; -- The other processes' last counts reach their signals a delta later
		tb_finish("tb_sram_port_mux", checks + rd_checks, errors + rd_errors);
		wait;
	end process;
end arch;

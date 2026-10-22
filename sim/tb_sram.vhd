--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    SRAM Testbench
-- Module Name:    tb_sram
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for sram_arbiter +
--                 sram_controller against sram_model (datasheet timing
--                 checks). Board wiring adds 3.5 ns from the FPGA's output
--                 registers to the SRAM pins (clock-to-out plus trace).
--                 Clocks: clk_sys 100 MHz and clk_sram_rd 1.04 ns later.
--                 Tests:
--                 1. Directed: write then read back, read-to-write and
--                    write-to-read turnarounds, back-to-back reads.
--                 2. Random traffic from all four masters at once over a
--                    small address window (many address collisions); a
--                    shadow memory updated at grant time predicts every
--                    read, per-master queues check the returned order.
--                 3. Display deadline: 320-byte line reads from master 0
--                    finish within 320 x CYCLES + 60 cycles under full
--                    write traffic (the deadline is 6,400 cycles).
--                 Throughout: the SRAM model's timing checks, and no
--                 cycle where the FPGA and the SRAM drive the bus at the
--                 same time.
--                 RUN_VARIANTS: CYCLES=2 CYCLES=3
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, tb_pkg, sram_model, sram_controller,
--                 sram_arbiter
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
use work.tb_pkg.all;
use work.sram_model_pkg.all;

entity tb_sram is
	generic(
		CYCLES: positive := 2
	);
end tb_sram;

architecture arch of tb_sram is
	component sram_controller is
		generic(
			CYCLES: positive := 2;
			TAG_BITS: positive := 2
		);
		port(
			clk_i: in std_logic;
			clk_rd_i: in std_logic;
			rst_i: in std_logic;
			cmd_valid_i: in std_logic;
			cmd_ready_o: out std_logic;
			cmd_we_i: in std_logic;
			cmd_addr_i: in std_logic_vector(18 downto 0);
			cmd_wdata_i: in std_logic_vector(7 downto 0);
			cmd_tag_i: in std_logic_vector(TAG_BITS - 1 downto 0);
			rsp_valid_o: out std_logic;
			rsp_data_o: out std_logic_vector(7 downto 0);
			rsp_tag_o: out std_logic_vector(TAG_BITS - 1 downto 0);
			busy_o: out std_logic;
			sram_a_o: out std_logic_vector(18 downto 0);
			sram_dq_o: out std_logic_vector(7 downto 0);
			sram_dq_t_o: out std_logic_vector(7 downto 0);
			sram_dq_i: in std_logic_vector(7 downto 0);
			sram_oe_n_o: out std_logic;
			sram_we_n_o: out std_logic;
			sram_ce_n_o: out std_logic
		);
	end component;
	component sram_arbiter is
		generic(
			BURST_MAX: positive := 32
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			m_req_i: in std_logic_vector(3 downto 0);
			m_we_i: in std_logic_vector(3 downto 0);
			m_addr_i: in std_logic_vector(4 * 19 - 1 downto 0);
			m_wdata_i: in std_logic_vector(4 * 8 - 1 downto 0);
			m_gnt_o: out std_logic_vector(3 downto 0);
			m_rvalid_o: out std_logic_vector(3 downto 0);
			m_rdata_o: out std_logic_vector(7 downto 0);
			cmd_valid_o: out std_logic;
			cmd_ready_i: in std_logic;
			cmd_we_o: out std_logic;
			cmd_addr_o: out std_logic_vector(18 downto 0);
			cmd_wdata_o: out std_logic_vector(7 downto 0);
			cmd_tag_o: out std_logic_vector(1 downto 0);
			rsp_valid_i: in std_logic;
			rsp_data_i: in std_logic_vector(7 downto 0);
			rsp_tag_i: in std_logic_vector(1 downto 0);
			busy_i: in std_logic;
			clear_count_i: in std_logic;
			busy_count_o: out std_logic_vector(23 downto 0)
		);
	end component;
	component sram_model is
		generic(
			T_AA: time := 10 ns;
			T_OHA: time := 2 ns;
			T_DOE: time := 4.5 ns;
			T_HZOE: time := 4 ns;
			T_HZWE: time := 5 ns;
			T_PWE: time := 8 ns;
			T_SD: time := 6 ns;
			T_AW: time := 8 ns
		);
		port(
			a_i: in std_logic_vector(18 downto 0);
			dq_io: inout std_logic_vector(7 downto 0);
			ce_n_i: in std_logic;
			oe_n_i: in std_logic;
			we_n_i: in std_logic;
			driving_o: out boolean;
			errors_o: out natural
		);
	end component;

	constant PERIOD: time := 10 ns;
	constant T_OUT: time := 3.5 ns; -- FPGA clock-to-out plus board trace
	constant T_RD_SHIFT: time := 1.04 ns; -- clk_sram_rd lag (37.5 deg)
	constant RANDOM_OPS: natural := 3000; -- Requests per random master

	-- Reference memory updated when a write is granted
	type shadow_t is protected
		procedure write(addr: natural; data: std_logic_vector(7 downto 0));
		impure function read(addr: natural) return std_logic_vector;
	end protected shadow_t;
	type shadow_t is protected body
		type arr_t is array (0 to 2 ** 19 - 1) of std_logic_vector(7 downto 0);
		variable arr: arr_t := (others => (others => 'U'));
		procedure write(addr: natural; data: std_logic_vector(7 downto 0)) is
		begin
			arr(addr) := data;
		end procedure;
		impure function read(addr: natural) return std_logic_vector is
		begin
			return arr(addr);
		end function;
	end protected body shadow_t;

	shared variable chk: checker_t;
	shared variable shadow: shadow_t;

	signal clk: std_logic := '0';
	signal clk_rd: std_logic := '0';
	signal rst: std_logic := '1';
	signal done: boolean := false;

	-- Master ports: one record signal per master, so each stimulus
	-- process drives only its own master (one driver per signal)
	type mport_t is record
		req: std_logic;
		we: std_logic;
		addr: natural;
		wdata: natural;
	end record;
	type mports_t is array (0 to 3) of mport_t;
	signal mp: mports_t := (others => ('0', '0', 0, 0));
	signal m_req: std_logic_vector(3 downto 0);
	signal m_we: std_logic_vector(3 downto 0);
	signal m_addr: std_logic_vector(4 * 19 - 1 downto 0);
	signal m_wdata: std_logic_vector(4 * 8 - 1 downto 0);
	signal m_gnt: std_logic_vector(3 downto 0);
	signal m_rvalid: std_logic_vector(3 downto 0);
	signal m_rdata: std_logic_vector(7 downto 0);
	signal masters_done: std_logic_vector(3 downto 0) := (others => '0');
	signal phase: natural := 0; -- 0 directed, 1 random, 2 deadline

	-- Arbiter to controller
	signal cmd_valid, cmd_ready, cmd_we: std_logic;
	signal cmd_addr: std_logic_vector(18 downto 0);
	signal cmd_wdata: std_logic_vector(7 downto 0);
	signal cmd_tag: std_logic_vector(1 downto 0);
	signal rsp_valid: std_logic;
	signal rsp_data: std_logic_vector(7 downto 0);
	signal rsp_tag: std_logic_vector(1 downto 0);
	signal busy: std_logic;
	signal busy_count: std_logic_vector(23 downto 0);

	-- FPGA pins and the board
	signal pin_a: std_logic_vector(18 downto 0);
	signal pin_dq_o: std_logic_vector(7 downto 0);
	signal pin_dq_t: std_logic_vector(7 downto 0);
	signal pin_oe_n, pin_we_n, pin_ce_n: std_logic;
	signal brd_a: std_logic_vector(18 downto 0) := (others => '0');
	signal brd_oe_n, brd_we_n, brd_ce_n: std_logic := '1';
	signal brd_fpga_drive: boolean := false;
	signal dq: std_logic_vector(7 downto 0);
	signal sram_driving: boolean;
	signal sram_errors: natural;

	-- Issue one request on a master port and wait for its grant. Called
	-- from the stimulus processes right after a rising edge.
	procedure request(signal p: inout mport_t; signal gnt: in std_logic;
		signal clk: in std_logic; write: boolean; a: natural; d: natural) is
	begin
		p.req <= '1';
		p.we <= '1' when write else '0';
		p.addr <= a;
		p.wdata <= d;
		loop
			wait until rising_edge(clk);
			exit when (gnt = '1');
		end loop;
		if (write) then
			shadow.write(a, std_logic_vector(to_unsigned(d, 8)));
		end if;
		p.req <= '0';
	end procedure;
begin
	pack: for m in 0 to 3 generate
		m_req(m) <= mp(m).req;
		m_we(m) <= mp(m).we;
		m_addr(m * 19 + 18 downto m * 19) <= std_logic_vector(to_unsigned(mp(m).addr, 19));
		m_wdata(m * 8 + 7 downto m * 8) <= std_logic_vector(to_unsigned(mp(m).wdata, 8));
	end generate;

	arb: sram_arbiter
		port map (
			clk_i => clk,
			rst_i => rst,
			m_req_i => m_req,
			m_we_i => m_we,
			m_addr_i => m_addr,
			m_wdata_i => m_wdata,
			m_gnt_o => m_gnt,
			m_rvalid_o => m_rvalid,
			m_rdata_o => m_rdata,
			cmd_valid_o => cmd_valid,
			cmd_ready_i => cmd_ready,
			cmd_we_o => cmd_we,
			cmd_addr_o => cmd_addr,
			cmd_wdata_o => cmd_wdata,
			cmd_tag_o => cmd_tag,
			rsp_valid_i => rsp_valid,
			rsp_data_i => rsp_data,
			rsp_tag_i => rsp_tag,
			busy_i => busy,
			clear_count_i => '0',
			busy_count_o => busy_count
		);

	ctrl: sram_controller
		generic map (
			CYCLES => CYCLES
		)
		port map (
			clk_i => clk,
			clk_rd_i => clk_rd,
			rst_i => rst,
			cmd_valid_i => cmd_valid,
			cmd_ready_o => cmd_ready,
			cmd_we_i => cmd_we,
			cmd_addr_i => cmd_addr,
			cmd_wdata_i => cmd_wdata,
			cmd_tag_i => cmd_tag,
			rsp_valid_o => rsp_valid,
			rsp_data_o => rsp_data,
			rsp_tag_o => rsp_tag,
			busy_o => busy,
			sram_a_o => pin_a,
			sram_dq_o => pin_dq_o,
			sram_dq_t_o => pin_dq_t,
			sram_dq_i => dq,
			sram_oe_n_o => pin_oe_n,
			sram_we_n_o => pin_we_n,
			sram_ce_n_o => pin_ce_n
		);

	-- Board: outputs reach the SRAM T_OUT after the FPGA registers change
	brd_a <= transport pin_a after T_OUT;
	brd_oe_n <= transport pin_oe_n after T_OUT;
	brd_we_n <= transport pin_we_n after T_OUT;
	brd_ce_n <= transport pin_ce_n after T_OUT;
	brd_fpga_drive <= transport (pin_dq_t(0) = '0') after T_OUT;
	dq <= transport pin_dq_o after T_OUT when (pin_dq_t(0) = '0') else
		(others => 'Z') after T_OUT;

	mem: sram_model
		port map (
			a_i => brd_a,
			dq_io => dq,
			ce_n_i => brd_ce_n,
			oe_n_i => brd_oe_n,
			we_n_i => brd_we_n,
			driving_o => sram_driving,
			errors_o => sram_errors
		);

	-- Clocks: clk_sram_rd is the same clock 1.04 ns later
	process
	begin
		if (done) then
			wait;
		end if;
		clk <= '0';
		wait for PERIOD / 2;
		clk <= '1';
		wait for PERIOD / 2;
	end process;

	clk_rd <= transport clk after T_RD_SHIFT;

	-- Reset
	process
	begin
		rst <= '1';
		wait for 10.5 * PERIOD;
		rst <= '0';
		wait;
	end process;

	-- Bus contention monitor
	process(brd_fpga_drive, sram_driving)
	begin
		if (brd_fpga_drive and sram_driving) then
			chk.check(false, "bus contention at " & time'image(now));
		end if;
	end process;

	-- All dq_t bits must move together (the top level uses bit 0 above)
	process(pin_dq_t, rst)
	begin
		if (rst = '0') then
			chk.check((pin_dq_t = x"00") or (pin_dq_t = x"FF"), "dq_t bits differ");
		end if;
	end process;

	------------------------------------------------------------------
	-- Response checkers, one per master: expected data queued at grant
	------------------------------------------------------------------
	checkers: for m in 0 to 3 generate
		process
			type queue_t is array (0 to 255) of std_logic_vector(7 downto 0);
			variable q: queue_t;
			variable head, tail: natural := 0;
			variable a: natural;
		begin
			wait until rising_edge(clk);
			-- Grant of a read: remember what it must return
			if ((m_gnt(m) = '1') and (m_we(m) = '0')) then
				a := mp(m).addr;
				q(tail) := shadow.read(a);
				tail := (tail + 1) mod 256;
			end if;
			if (m_rvalid(m) = '1') then
				if (head = tail) then
					chk.check(false, "master " & integer'image(m) & " got unexpected data");
				else
					chk.check(m_rdata = q(head), "master " & integer'image(m) & " read " &
						to_hex(m_rdata) & " expected " & to_hex(q(head)));
					head := (head + 1) mod 256;
				end if;
			end if;
		end process;
	end generate;

	------------------------------------------------------------------
	-- Stimulus: directed tests and master 0 (display)
	------------------------------------------------------------------
	process
		variable t0: time;
		variable seed1, seed2: positive := 7;
		variable r: real;
	begin
		-- Preload the low 4 KB and the deadline-test address through the
		-- back door so every read has a known expected value
		-- (mod 251, a prime, so the pattern does not repeat at power-of-two strides)
		for a in 0 to 4095 loop
			sram_mem.write(a, std_logic_vector(to_unsigned(a mod 251, 8)));
			shadow.write(a, std_logic_vector(to_unsigned(a mod 251, 8)));
		end loop;
		for i in 0 to 18 loop
			sram_mem.write(2 ** i, x"00");
			shadow.write(2 ** i, x"00");
		end loop;
		wait until (rst = '0');
		wait until rising_edge(clk);

		-- 1. Directed (on master 0): writes, then reads of the same bytes
		for i in 0 to 15 loop
			request(mp(0), m_gnt(0), clk, true, 16#100# + i, 16#A0# + i);
		end loop;
		for i in 0 to 15 loop
			request(mp(0), m_gnt(0), clk, false, 16#100# + i, 0);
		end loop;
		-- Alternate read, write, read on the same address (turnarounds)
		for i in 0 to 15 loop
			request(mp(0), m_gnt(0), clk, false, 16#200# + i, 0);
			request(mp(0), m_gnt(0), clk, true, 16#200# + i, 16#30# + i);
			request(mp(0), m_gnt(0), clk, false, 16#200# + i, 0);
		end loop;
		-- Every address bit and data bit (walking ones)
		for i in 0 to 18 loop
			request(mp(0), m_gnt(0), clk, true, 2 ** i, 2 ** (i mod 8));
		end loop;
		for i in 0 to 18 loop
			request(mp(0), m_gnt(0), clk, false, 2 ** i, 0);
		end loop;
		for i in 1 to 20 loop
			wait until rising_edge(clk);
		end loop;

		-- 2. Random traffic on all masters
		phase <= 1;
		for i in 0 to RANDOM_OPS - 1 loop
			uniform(seed1, seed2, r);
			if (r < 0.15) then
				-- Occasional display-like read bursts
				for j in 0 to 7 loop
					request(mp(0), m_gnt(0), clk, false,
						16#3F0# + j, 0);
				end loop;
			else
				wait until rising_edge(clk);
			end if;
		end loop;
		wait until (masters_done(3 downto 1) = "111");
		for i in 1 to 20 loop
			wait until rising_edge(clk);
		end loop;

		-- 3. Display deadline: line reads while master 2 writes flat out
		phase <= 2;
		for line in 0 to 3 loop
			t0 := now;
			for x in 0 to 319 loop
				request(mp(0), m_gnt(0), clk, false, line * 320 + x, 0);
			end loop;
			-- 320 accesses at CYCLES clocks each, plus a little latency;
			-- the real deadline is 6,400 cycles (two scanlines)
			chk.check(now - t0 < (320 * CYCLES + 60) * PERIOD, "display line took " &
				integer'image((now - t0) / PERIOD) & " cycles");
		end loop;
		phase <= 3;
		for i in 1 to 20 loop
			wait until rising_edge(clk);
		end loop;

		chk.check(sram_errors = 0, "SRAM model timing errors: " & integer'image(sram_errors));
		tb_print("busy cycles: " & integer'image(to_integer(unsigned(busy_count))) &
			" of " & integer'image(now / PERIOD));
		done <= true;
		tb_finish("tb_sram_c" & integer'image(CYCLES), chk.checks, chk.errors);
		wait;
	end process;

	-- Random masters 1 to 3: reads and writes with random gaps
	random_masters: for m in 1 to 3 generate
		process
			variable seed1: positive := 11 * m;
			variable seed2: positive := 13 * m + 5;
			variable r1, r2, r3: real;
			variable a, d: natural;
		begin
			wait until (phase = 1);
			wait until rising_edge(clk);
			for i in 0 to RANDOM_OPS - 1 loop
				uniform(seed1, seed2, r1);
				uniform(seed1, seed2, r2);
				uniform(seed1, seed2, r3);
				a := 16#3F0# + integer(trunc(r2 * 40.0)); -- 40-byte window
				d := integer(trunc(r3 * 256.0));
				-- Master 2 writes only (like the pixel FIFO)
				request(mp(m), m_gnt(m), clk, (m = 2) or (r1 < 0.5), a, d);
				if (r1 > 0.8) then
					wait until rising_edge(clk);
				end if;
			end loop;
			masters_done(m) <= '1';
			-- Master 2 keeps writing during the deadline test
			if (m = 2) then
				wait until (phase = 2);
				while (phase = 2) loop
					request(mp(m), m_gnt(m), clk, true, 16#40000#, 0);
				end loop;
			end if;
			wait;
		end process;
	end generate;
end arch;

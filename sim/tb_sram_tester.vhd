--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    SRAM Tester Testbench
-- Module Name:    tb_sram_tester
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for sram_tester running through
--                 sram_arbiter, sram_controller and sram_model on a
--                 512-byte range:
--                 1. Two clean passes: pass count rises, no errors, and
--                    the SRAM holds the last LFSR pattern (checked through
--                    the model's back door against this testbench's own
--                    LFSR).
--                 2. A data bit stuck at 0 on the board (fault injected
--                    between FPGA and SRAM): errors are counted and the
--                    first error is reported with the right address and
--                    data.
--                 3. Two address lines shorted together (A1 driven from
--                    A0): only the address-in-address phase can see it.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std, tb_pkg,
--                 sram_model, sram_tester, sram_arbiter, sram_controller
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
use work.tb_pkg.all;
use work.sram_model_pkg.all;

entity tb_sram_tester is
end tb_sram_tester;

architecture arch of tb_sram_tester is
	component sram_tester is
		generic(
			FIRST: natural := 16#40000#;
			LAST: natural := 16#7FFFF#
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			enable_i: in std_logic;
			m_req_o: out std_logic;
			m_we_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_wdata_o: out std_logic_vector(7 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0);
			phase_o: out std_logic_vector(2 downto 0);
			pass_count_o: out std_logic_vector(15 downto 0);
			error_count_o: out std_logic_vector(15 downto 0);
			first_error_addr_o: out std_logic_vector(18 downto 0);
			first_error_data_o: out std_logic_vector(15 downto 0)
		);
	end component;
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
	constant FIRST: natural := 16#41000#;
	constant LAST: natural := 16#411FF#;
	shared variable chk: checker_t;

	signal clk, clk_rd: std_logic := '0';
	signal rst: std_logic := '1';
	signal done: boolean := false;
	signal enable: std_logic := '0';
	signal stuck_bit: boolean := false; -- DQ3 stuck at 0 on the board
	signal short_a1: boolean := false; -- A1 shorted to A0 on the board

	signal t_req, t_we: std_logic;
	signal t_addr: std_logic_vector(18 downto 0);
	signal t_wdata: std_logic_vector(7 downto 0);
	signal phase: std_logic_vector(2 downto 0);
	signal passes, errors: std_logic_vector(15 downto 0);
	signal first_addr: std_logic_vector(18 downto 0);
	signal first_data: std_logic_vector(15 downto 0);

	signal m_gnt, m_rvalid: std_logic_vector(3 downto 0);
	signal m_rdata: std_logic_vector(7 downto 0);
	signal cmd_valid, cmd_ready, cmd_we: std_logic;
	signal cmd_addr: std_logic_vector(18 downto 0);
	signal cmd_wdata: std_logic_vector(7 downto 0);
	signal cmd_tag, rsp_tag: std_logic_vector(1 downto 0);
	signal rsp_valid, busy: std_logic;
	signal rsp_data: std_logic_vector(7 downto 0);
	signal pin_a: std_logic_vector(18 downto 0);
	signal pin_dq_o, pin_dq_t: std_logic_vector(7 downto 0);
	signal pin_oe_n, pin_we_n, pin_ce_n: std_logic;
	signal brd_a: std_logic_vector(18 downto 0) := (others => '0');
	signal brd_a_faulty: std_logic_vector(18 downto 0);
	signal brd_oe_n, brd_we_n, brd_ce_n: std_logic := '1';
	signal dq_fpga: std_logic_vector(7 downto 0);
	signal dq: std_logic_vector(7 downto 0);
	signal sram_driving: boolean;
	signal sram_errors: natural;

	-- 16-bit Fibonacci LFSR, taps 16, 15, 13, 4 (the same sequence as sram_tester)
	function lfsr_step(s: unsigned(15 downto 0)) return unsigned is
	begin
		return s(14 downto 0) & (s(15) xor s(14) xor s(12) xor s(3));
	end function;
begin
	dut: sram_tester
		generic map (
			FIRST => FIRST,
			LAST => LAST
		)
		port map (
			clk_i => clk,
			rst_i => rst,
			enable_i => enable,
			m_req_o => t_req,
			m_we_o => t_we,
			m_addr_o => t_addr,
			m_wdata_o => t_wdata,
			m_gnt_i => m_gnt(1),
			m_rvalid_i => m_rvalid(1),
			m_rdata_i => m_rdata,
			phase_o => phase,
			pass_count_o => passes,
			error_count_o => errors,
			first_error_addr_o => first_addr,
			first_error_data_o => first_data
		);

	arb: sram_arbiter
		port map (
			clk_i => clk,
			rst_i => rst,
			m_req_i => "00" & t_req & '0',
			m_we_i => "00" & t_we & '0',
			m_addr_i => (2 * 19 - 1 downto 0 => '0') & t_addr & (18 downto 0 => '0'),
			m_wdata_i => x"0000" & t_wdata & x"00",
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
			busy_count_o => open
		);

	ctrl: sram_controller
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

	-- Board wiring with optional faults
	brd_a <= transport pin_a after T_OUT;
	brd_oe_n <= transport pin_oe_n after T_OUT;
	brd_we_n <= transport pin_we_n after T_OUT;
	brd_ce_n <= transport pin_ce_n after T_OUT;
	process(brd_a, short_a1)
	begin
		brd_a_faulty <= brd_a;
		if (short_a1) then
			brd_a_faulty(1) <= brd_a(0);
		end if;
	end process;
	process(pin_dq_o, stuck_bit)
	begin
		dq_fpga <= pin_dq_o;
		if (stuck_bit) then
			dq_fpga(3) <= '0';
		end if;
	end process;
	dq <= transport dq_fpga after T_OUT when (pin_dq_t(0) = '0') else
		(others => 'Z') after T_OUT;

	mem: sram_model
		port map (
			a_i => brd_a_faulty,
			dq_io => dq,
			ce_n_i => brd_ce_n,
			oe_n_i => brd_oe_n,
			we_n_i => brd_we_n,
			driving_o => sram_driving,
			errors_o => sram_errors
		);

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

	clk_rd <= transport clk after 1.04 ns; -- The MMCM's +37.5 deg SRAM read clock

	process
	begin
		rst <= '1';
		wait for 10.5 * PERIOD;
		rst <= '0';
		wait until (stuck_bit or short_a1);
		-- Each fault test starts from reset
		loop
			rst <= '1';
			wait for 10.5 * PERIOD;
			rst <= '0';
			wait on stuck_bit, short_a1;
		end loop;
	end process;

	process
		variable s: unsigned(15 downto 0);
		variable ok: boolean;
	begin
		wait until (rst = '0');
		enable <= '1';

		-- 1. Clean passes
		wait until (unsigned(passes) = 2);
		chk.check(unsigned(errors) = 0, "no errors on a good SRAM, got " & to_hex(errors));
		-- The range now holds the LFSR bytes of pass 2 (seed = step(ACE1) or 1)
		s := lfsr_step(x"ACE1") or x"0001";
		ok := true;
		for a in FIRST to LAST loop
			if (sram_mem.read(a) /= std_logic_vector(s(7 downto 0))) then
				ok := false;
			end if;
			s := lfsr_step(s);
		end loop;
		chk.check(ok, "SRAM holds the pass-2 LFSR pattern");
		chk.check(sram_errors = 0, "SRAM model timing errors");

		-- 2. DQ3 stuck at 0: the first walking-ones byte with bit 3 set is
		-- the fourth one (FIRST + 3, data 08)
		enable <= '0';
		stuck_bit <= true;
		wait until (rst = '1');
		wait until (rst = '0');
		enable <= '1';
		wait until (unsigned(passes) = 1);
		chk.check(unsigned(errors) > 0, "stuck data bit detected");
		chk.check(unsigned(first_addr) = FIRST + 3, "first error address " & to_hex(first_addr));
		-- first_data is expected (15:8) & read (7:0)
		chk.check(first_data = x"0800", "first error data " & to_hex(first_data));

		-- 3. A1 shorted to A0: walking ones use FIRST..FIRST+7, so bytes
		-- 1 and 2 collide; address-in-address catches it everywhere
		enable <= '0';
		stuck_bit <= false;
		short_a1 <= true;
		wait until (rst = '1');
		wait until (rst = '0');
		enable <= '1';
		wait until (unsigned(passes) = 1);
		chk.check(unsigned(errors) > 0, "shorted address lines detected");

		done <= true;
		tb_finish("tb_sram_tester", chk.checks, chk.errors);
		wait;
	end process;
end arch;

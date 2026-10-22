--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    UART Debug Port Testbench
-- Module Name:    tb_debug_port
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for debug_port at 1 Mbaud with
--                 the real SRAM path behind master 3 (sram_arbiter,
--                 sram_controller, sram_model). A PC-side UART written
--                 here sends commands bit by bit and collects the reply
--                 bytes. Commands tested: ping, echo, read of a status
--                 register, write then read of a control register (and
--                 ctrl_o), read of an unused register, SRAM write of 40
--                 bytes then read back (checked against the SRAM model's
--                 back door as well), an unknown command, and a command
--                 abandoned half-way (dropped after TIMEOUT_MS = 1 ms, the
--                 next ping still works).
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std, tb_pkg,
--                 sram_model, debug_port, uart_rx, uart_tx, sram_arbiter,
--                 sram_controller
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

entity tb_debug_port is
end tb_debug_port;

architecture arch of tb_debug_port is
	component debug_port is
		generic(
			CLK_HZ: natural := 100_000_000;
			BAUD: natural := 1_000_000;
			TIMEOUT_MS: natural := 100;
			CTRL_INIT: std_logic_vector(8 * 32 - 1 downto 0) := (others => '0')
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			rx_i: in std_logic;
			tx_o: out std_logic;
			status_i: in std_logic_vector(32 * 32 - 1 downto 0);
			ctrl_o: out std_logic_vector(8 * 32 - 1 downto 0);
			m_req_o: out std_logic;
			m_we_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_wdata_o: out std_logic_vector(7 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0);
			rx_count_o: out std_logic_vector(15 downto 0);
			tx_count_o: out std_logic_vector(15 downto 0)
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
	constant BIT_TIME: time := 1 us; -- 1 Mbaud
	constant T_OUT: time := 3.5 ns; -- FPGA clock-to-out plus board trace
	type bytes_t is array (0 to 255) of std_logic_vector(7 downto 0);
	shared variable chk: checker_t;

	signal clk, clk_rd: std_logic := '0';
	signal rst: std_logic := '1';
	signal done: boolean := false;
	signal pc_tx: std_logic := '1'; -- PC to FPGA
	signal fpga_tx: std_logic; -- FPGA to PC
	signal status: std_logic_vector(32 * 32 - 1 downto 0);
	signal ctrl: std_logic_vector(8 * 32 - 1 downto 0);
	signal rx_count, tx_count: std_logic_vector(15 downto 0);
	signal replies: bytes_t;
	signal nreplies: natural := 0;

	signal g_req, g_we: std_logic;
	signal g_addr: std_logic_vector(18 downto 0);
	signal g_wdata: std_logic_vector(7 downto 0);
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
	signal brd_oe_n, brd_we_n, brd_ce_n: std_logic := '1';
	signal dq: std_logic_vector(7 downto 0);
	signal sram_driving: boolean;
	signal sram_errors: natural;

	-- PC side: send one 8N1 byte
	procedure pc_send(signal line: out std_logic; b: std_logic_vector(7 downto 0)) is
	begin
		line <= '0';
		wait for BIT_TIME;
		for i in 0 to 7 loop
			line <= b(i);
			wait for BIT_TIME;
		end loop;
		line <= '1';
		wait for BIT_TIME;
	end procedure;
begin
	-- Status word w = w * 0x01010101 (easy to recognize)
	status_words: for w in 0 to 31 generate
		status(32 * w + 31 downto 32 * w) <= std_logic_vector(to_unsigned(w * 16#01010101# mod 2 ** 30, 32));
	end generate;

	dut: debug_port
		generic map (
			TIMEOUT_MS => 1,
			CTRL_INIT => (others => '0')
		)
		port map (
			clk_i => clk,
			rst_i => rst,
			rx_i => pc_tx,
			tx_o => fpga_tx,
			status_i => status,
			ctrl_o => ctrl,
			m_req_o => g_req,
			m_we_o => g_we,
			m_addr_o => g_addr,
			m_wdata_o => g_wdata,
			m_gnt_i => m_gnt(3),
			m_rvalid_i => m_rvalid(3),
			m_rdata_i => m_rdata,
			rx_count_o => rx_count,
			tx_count_o => tx_count
		);

	arb: sram_arbiter
		port map (
			clk_i => clk,
			rst_i => rst,
			m_req_i => g_req & "000",
			m_we_i => g_we & "000",
			m_addr_i => g_addr & (3 * 19 - 1 downto 0 => '0'),
			m_wdata_i => g_wdata & x"000000",
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

	ctrl_sram: sram_controller
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

	brd_a <= transport pin_a after T_OUT;
	brd_oe_n <= transport pin_oe_n after T_OUT;
	brd_we_n <= transport pin_we_n after T_OUT;
	brd_ce_n <= transport pin_ce_n after T_OUT;
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
		wait;
	end process;

	-- PC side receiver: sample each bit in its middle
	process
		variable b: std_logic_vector(7 downto 0);
	begin
		wait until falling_edge(fpga_tx);
		wait for BIT_TIME / 2;
		chk.check(fpga_tx = '0', "start bit");
		for i in 0 to 7 loop
			wait for BIT_TIME;
			b(i) := fpga_tx;
		end loop;
		wait for BIT_TIME;
		chk.check(fpga_tx = '1', "stop bit");
		replies(nreplies mod 256) <= b;
		nreplies <= nreplies + 1;
	end process;

	-- Stimulus and checks
	process
		variable first: natural;
		variable ok: boolean;

		-- Wait for n more reply bytes (or give up after a long time)
		procedure expect(n: natural; msg: string) is
		begin
			wait until (nreplies >= first + n) for 2 ms;
			chk.check(nreplies >= first + n, msg & ": got " & integer'image(nreplies - first) &
				" of " & integer'image(n) & " reply bytes");
		end procedure;

		impure function reply(i: natural) return std_logic_vector is
		begin
			return replies((first + i) mod 256);
		end function;
	begin
		wait until (rst = '0');
		wait for 2 us;

		-- Ping
		first := nreplies;
		pc_send(pc_tx, x"50");
		expect(1, "ping");
		chk.check(reply(0) = x"4B", "ping replies K");

		-- Echo
		first := nreplies;
		pc_send(pc_tx, x"45");
		pc_send(pc_tx, x"A5");
		expect(1, "echo");
		chk.check(reply(0) = x"A5", "echo returns the byte");

		-- Read status register 5: 0x05050505, little endian
		first := nreplies;
		pc_send(pc_tx, x"52");
		pc_send(pc_tx, x"05");
		expect(4, "read reg 5");
		chk.check((reply(0) & reply(1) & reply(2) & reply(3)) = x"05050505", "status reg 5 value");

		-- Write control register 33, read it back
		first := nreplies;
		-- 'W', register 0x21, then the 32-bit value least significant byte first
		pc_send(pc_tx, x"57");
		pc_send(pc_tx, x"21");
		pc_send(pc_tx, x"78");
		pc_send(pc_tx, x"56");
		pc_send(pc_tx, x"34");
		pc_send(pc_tx, x"12");
		expect(1, "write reg 33");
		chk.check(reply(0) = x"4B", "write replies K");
		chk.check(ctrl(63 downto 32) = x"12345678", "ctrl word 1 written");
		first := nreplies;
		pc_send(pc_tx, x"52");
		pc_send(pc_tx, x"21");
		expect(4, "read reg 33");
		chk.check((reply(3) & reply(2) & reply(1) & reply(0)) = x"12345678", "reg 33 reads back");

		-- Unused register reads as 0
		first := nreplies;
		pc_send(pc_tx, x"52");
		pc_send(pc_tx, x"40");
		expect(4, "read reg 64");
		chk.check((reply(0) & reply(1) & reply(2) & reply(3)) = x"00000000", "unused register is 0");

		-- SRAM write: 40 bytes at 0x41230
		first := nreplies;
		-- 'S', then address and length, 3 bytes each, least significant first, then the data
		pc_send(pc_tx, x"53");
		pc_send(pc_tx, x"30");
		pc_send(pc_tx, x"12");
		pc_send(pc_tx, x"04");
		pc_send(pc_tx, x"28");
		pc_send(pc_tx, x"00");
		pc_send(pc_tx, x"00");
		for i in 0 to 39 loop
			pc_send(pc_tx, std_logic_vector(to_unsigned(200 - 3 * i, 8)));
		end loop;
		expect(1, "SRAM write");
		chk.check(reply(0) = x"4B", "SRAM write replies K");
		ok := true;
		for i in 0 to 39 loop
			if (sram_mem.read(16#41230# + i) /= std_logic_vector(to_unsigned(200 - 3 * i, 8))) then
				ok := false;
			end if;
		end loop;
		chk.check(ok, "SRAM holds the 40 written bytes");

		-- SRAM read back
		first := nreplies;
		pc_send(pc_tx, x"4D");
		pc_send(pc_tx, x"30");
		pc_send(pc_tx, x"12");
		pc_send(pc_tx, x"04");
		pc_send(pc_tx, x"28");
		pc_send(pc_tx, x"00");
		pc_send(pc_tx, x"00");
		expect(40, "SRAM read");
		ok := true;
		for i in 0 to 39 loop
			if (reply(i) /= std_logic_vector(to_unsigned(200 - 3 * i, 8))) then
				ok := false;
			end if;
		end loop;
		chk.check(ok, "SRAM read returns the 40 bytes");

		-- Unknown command
		first := nreplies;
		pc_send(pc_tx, x"5A");
		expect(1, "unknown command");
		chk.check(reply(0) = x"3F", "unknown command replies ?");

		-- Abandoned command: 'W' and two bytes, then silence past the
		-- timeout; the next ping must work
		first := nreplies;
		pc_send(pc_tx, x"57");
		pc_send(pc_tx, x"21");
		pc_send(pc_tx, x"00");
		wait for 1.5 ms;
		chk.check(nreplies = first, "no reply to an abandoned command");
		pc_send(pc_tx, x"50");
		expect(1, "ping after timeout");
		chk.check(reply(0) = x"4B", "ping works after a dropped command");
		chk.check(ctrl(63 downto 32) = x"12345678", "abandoned write changed nothing");

		-- Every byte the PC side sent above
		chk.check(unsigned(rx_count) = 74, "rx byte count " & integer'image(to_integer(unsigned(rx_count))));
		chk.check(unsigned(tx_count) = nreplies, "tx byte count");
		chk.check(sram_errors = 0, "SRAM model timing errors");
		done <= true;
		tb_finish("tb_debug_port", chk.checks, chk.errors);
		wait;
	end process;
end arch;

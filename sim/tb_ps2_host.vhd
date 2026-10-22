--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    PS/2 Host Testbench
-- Module Name:    tb_ps2_host
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for ps2_host against
--                 ps2_device_model on open-drain lines with weak 'H'
--                 pull-ups. The system clock is 10 MHz here (timing
--                 generics scaled to match) to keep the run short; the
--                 PS/2 timing itself is real (12.5 kHz device clock).
--                 Tests: a run of bytes received in order; a parity
--                 error; a bad stop bit; a truncated byte that times out
--                 and is followed by a good byte; host-to-device bytes
--                 with both parities, acknowledged, with no bytes
--                 received during the send; a silent device that makes
--                 the send time out and release the lines; enable low
--                 in the middle of a send releasing both lines at once.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std, tb_pkg,
--                 ps2_device_model, ps2_host
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

entity tb_ps2_host is
end tb_ps2_host;

architecture arch of tb_ps2_host is
	component ps2_host is
		generic(
			SAMPLE_CYCLES: positive := 100;
			RX_TIMEOUT_CYCLES: positive := 200_000;
			TX_INHIBIT_CYCLES: positive := 15_000;
			TX_RELEASE_CYCLES: positive := 1_000;
			TX_TIMEOUT_CYCLES: positive := 2_000_000
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			en_i: in std_logic;
			ps2_clk_i: in std_logic;
			ps2_dat_i: in std_logic;
			clk_pull_o: out std_logic;
			dat_pull_o: out std_logic;
			rx_data_o: out std_logic_vector(7 downto 0);
			rx_valid_o: out std_logic;
			rx_parity_err_o: out std_logic;
			rx_frame_err_o: out std_logic;
			rx_timeout_o: out std_logic;
			tx_data_i: in std_logic_vector(7 downto 0);
			tx_valid_i: in std_logic;
			tx_ready_o: out std_logic;
			tx_done_o: out std_logic;
			tx_err_o: out std_logic
		);
	end component;
	component ps2_device_model is
		generic(
			HALF_PERIOD: time := 40 us;
			MOUSE: boolean := false;
			REPLY_DELAY: time := 300 us;
			BAT_DELAY: time := 3 ms;
			BYTE_GAP: time := 100 us
		);
		port(
			clk_io: inout std_logic;
			dat_io: inout std_logic;
			send_i: in boolean;
			send_byte_i: in std_logic_vector(7 downto 0);
			send_mode_i: in natural;
			silent_i: in boolean;
			sent_o: out natural;
			rx_byte_o: out std_logic_vector(7 downto 0);
			rx_count_o: out natural;
			rx_parity_errors_o: out natural
		);
	end component;

	constant PERIOD: time := 100 ns; -- 10 MHz
	type bytes_t is array (natural range <>) of std_logic_vector(7 downto 0);
	constant SEQ: bytes_t := (x"1C", x"F0", x"1C", x"E0", x"75", x"00", x"FF", x"55");
	shared variable chk: checker_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal done: boolean := false;
	signal en: std_logic := '1';
	signal ps2_clk, ps2_dat: std_logic;
	signal clk_in, dat_in: std_logic;
	signal clk_pull, dat_pull: std_logic;
	signal rx_data: std_logic_vector(7 downto 0);
	signal rx_valid, rx_perr, rx_ferr, rx_tout: std_logic;
	signal tx_data: std_logic_vector(7 downto 0) := (others => '0');
	signal tx_valid: std_logic := '0';
	signal tx_ready, tx_done, tx_err: std_logic;

	signal dev_send: boolean := false;
	signal dev_byte: std_logic_vector(7 downto 0) := (others => '0');
	signal dev_mode: natural := 0;
	signal dev_silent: boolean := false;
	signal dev_sent, dev_rx_count, dev_rx_perr: natural;
	signal dev_rx_byte: std_logic_vector(7 downto 0);

	-- Results seen by the monitor
	signal got: bytes_t(0 to 31) := (others => (others => '0'));
	signal n_got, n_perr, n_ferr, n_tout, n_done, n_err: natural := 0;
begin
	dut: ps2_host
		generic map (
			SAMPLE_CYCLES => 10, -- 1 MHz at 10 MHz
			RX_TIMEOUT_CYCLES => 20_000, -- 2 ms
			TX_INHIBIT_CYCLES => 1_500, -- 150 us
			TX_RELEASE_CYCLES => 100, -- 10 us
			TX_TIMEOUT_CYCLES => 200_000 -- 20 ms
		)
		port map (
			clk_i => clk,
			rst_i => rst,
			en_i => en,
			ps2_clk_i => clk_in,
			ps2_dat_i => dat_in,
			clk_pull_o => clk_pull,
			dat_pull_o => dat_pull,
			rx_data_o => rx_data,
			rx_valid_o => rx_valid,
			rx_parity_err_o => rx_perr,
			rx_frame_err_o => rx_ferr,
			rx_timeout_o => rx_tout,
			tx_data_i => tx_data,
			tx_valid_i => tx_valid,
			tx_ready_o => tx_ready,
			tx_done_o => tx_done,
			tx_err_o => tx_err
		);

	-- Open-drain bus: pull-ups, the host's pull-downs, the device
	ps2_clk <= 'H';
	ps2_dat <= 'H';
	ps2_clk <= '0' when (clk_pull = '1') else 'Z';
	ps2_dat <= '0' when (dat_pull = '1') else 'Z';
	clk_in <= to_x01(ps2_clk);
	dat_in <= to_x01(ps2_dat);

	dev: ps2_device_model
		port map (
			clk_io => ps2_clk,
			dat_io => ps2_dat,
			send_i => dev_send,
			send_byte_i => dev_byte,
			send_mode_i => dev_mode,
			silent_i => dev_silent,
			sent_o => dev_sent,
			rx_byte_o => dev_rx_byte,
			rx_count_o => dev_rx_count,
			rx_parity_errors_o => dev_rx_perr
		);

	-- Clock
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

	-- Reset
	process
	begin
		rst <= '1';
		wait for 10.5 * PERIOD;
		rst <= '0';
		wait;
	end process;

	-- Monitor: collect every host output event
	process(clk)
	begin
		if rising_edge(clk) then
			if (rx_valid = '1') then
				got(n_got mod 32) <= rx_data;
				n_got <= n_got + 1;
			end if;
			if (rx_perr = '1') then
				n_perr <= n_perr + 1;
			end if;
			if (rx_ferr = '1') then
				n_ferr <= n_ferr + 1;
			end if;
			if (rx_tout = '1') then
				n_tout <= n_tout + 1;
			end if;
			if (tx_done = '1') then
				n_done <= n_done + 1;
			end if;
			if (tx_err = '1') then
				n_err <= n_err + 1;
			end if;
		end if;
	end process;

	-- Stimulus
	process
		variable n0: natural;

		procedure dev_tx(b: std_logic_vector(7 downto 0); mode: natural) is
			variable before: natural;
		begin
			before := dev_sent;
			dev_byte <= b;
			dev_mode <= mode;
			dev_send <= not dev_send;
			wait until (dev_sent = before + 1);
			wait for 50 us; -- Let the host's filter and receiver finish
		end procedure;

		procedure host_tx(b: std_logic_vector(7 downto 0)) is
		begin
			wait until rising_edge(clk);
			tx_data <= b;
			tx_valid <= '1';
			loop
				wait until rising_edge(clk);
				exit when (tx_ready = '1');
			end loop;
			tx_valid <= '0';
			wait until (tx_done = '1') or (tx_err = '1');
			wait until rising_edge(clk);
			wait for 1 ns; -- Let the monitor count the pulse
		end procedure;
	begin
		wait until (rst = '0');
		wait for 100 us;

		-- 1. A run of bytes
		for i in SEQ'range loop
			dev_tx(SEQ(i), 0);
		end loop;
		chk.check(n_got = SEQ'length, "received " & integer'image(n_got) & " bytes");
		for i in SEQ'range loop
			chk.check(got(i) = SEQ(i), "byte " & integer'image(i) & " got " & to_hex(got(i)) &
				" want " & to_hex(SEQ(i)));
		end loop;

		-- 2. Parity error, 3. bad stop bit
		dev_tx(x"3A", 1);
		chk.check((n_perr = 1) and (n_got = SEQ'length), "parity error reported, byte dropped");
		dev_tx(x"3A", 2);
		chk.check((n_ferr = 1) and (n_got = SEQ'length), "framing error reported, byte dropped");

		-- 4. Truncated byte: timeout after 2 ms, then a good byte
		dev_tx(x"C3", 3);
		chk.check(n_tout = 0, "no timeout before 2 ms");
		wait for 2.5 ms;
		chk.check(n_tout = 1, "timeout after a truncated byte");
		dev_tx(x"AB", 0);
		chk.check((n_got = SEQ'length + 1) and (got(SEQ'length) = x"AB"),
			"good byte after a timeout");

		-- 5. Host to device: both parities, acknowledged, nothing received
		n0 := n_got;
		host_tx(x"F4");
		chk.check(n_done = 1, "send F4 acknowledged");
		chk.check((dev_rx_count = 1) and (dev_rx_byte = x"F4"), "device got F4");
		host_tx(x"FF");
		host_tx(x"00");
		chk.check(n_done = 3, "three sends acknowledged");
		chk.check((dev_rx_count = 3) and (dev_rx_byte = x"00"), "device got FF then 00");
		chk.check(dev_rx_perr = 0, "device saw good parity and stop bits");
		chk.check((n_got = n0) and (n_perr = 1) and (n_ferr = 1) and (n_tout = 1),
			"receiver quiet while sending");
		chk.check((clk_pull = '0') and (dat_pull = '0'), "lines released after a send");

		-- Receive still works after sending
		dev_tx(x"FA", 0);
		chk.check(got((n_got - 1) mod 32) = x"FA", "byte received after a send");

		-- 6. Silent device: send times out, lines released
		dev_silent <= true;
		host_tx(x"F4");
		chk.check(n_err = 1, "send to a silent device times out");
		chk.check((clk_pull = '0') and (dat_pull = '0'), "lines released after the timeout");
		dev_silent <= false;
		wait for 1 ms;

		-- 7. Enable low during a send releases both lines at once
		wait until rising_edge(clk);
		tx_data <= x"F5";
		tx_valid <= '1';
		wait until rising_edge(clk);
		tx_valid <= '0';
		wait for 100 us;
		chk.check(clk_pull = '1', "clock pulled during the inhibit time");
		en <= '0';
		wait for 1 ns;
		chk.check((clk_pull = '0') and (dat_pull = '0'), "enable low releases the lines");
		wait for 50 us;
		chk.check(tx_ready = '0', "not ready while disabled");
		en <= '1';
		wait for 3 ms;
		chk.check((clk_pull = '0') and (dat_pull = '0') and (tx_ready = '1'),
			"idle again after enable");
		dev_tx(x"5A", 0);
		chk.check(got((n_got - 1) mod 32) = x"5A", "receive works after re-enable");

		done <= true;
		tb_finish("tb_ps2_host", chk.checks, chk.errors);
		wait;
	end process;
end arch;

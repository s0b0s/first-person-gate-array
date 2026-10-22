--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    UART Testbench
-- Module Name:    tb_uart
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for uart_tx and uart_rx:
--                 1. 1,000,000 baud loopback (tx1 -> rx1): 256 bytes sent
--                    back to back through valid/ready, received in order,
--                    no idle gap between frames.
--                 2. Bit timing on the tx1 line: every bit of a 0x55 frame
--                    lasts 1000 ns.
--                 3. 115,200 baud loopback (tx2 -> rx2): 8 bytes.
--                 4. rx3 (1,000,000 baud) driven by a testbench serial
--                    source running 3% slow and 3% fast: all bytes right.
--                 5. Framing error: a frame with a low stop bit gives
--                    frame_err and no byte; the line held low (break)
--                    does not produce bytes; after it returns high the
--                    next byte is received normally.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std, tb_pkg,
--                 uart_tx, uart_rx
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

entity tb_uart is
end tb_uart;

architecture arch of tb_uart is
	component uart_tx is
		generic(
			CLK_HZ: natural := 100_000_000;
			BAUD: natural := 1_000_000
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			data_i: in std_logic_vector(7 downto 0);
			valid_i: in std_logic;
			ready_o: out std_logic;
			tx_o: out std_logic
		);
	end component;
	component uart_rx is
		generic(
			CLK_HZ: natural := 100_000_000;
			BAUD: natural := 1_000_000
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			rx_i: in std_logic;
			data_o: out std_logic_vector(7 downto 0);
			valid_o: out std_logic;
			frame_err_o: out std_logic
		);
	end component;

	constant PERIOD: time := 10 ns;
	constant LOOP_BYTES: natural := 256;
	shared variable chk: checker_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal done: boolean := false;

	-- Path 1: 1 Mbaud loopback
	signal tx1_data: std_logic_vector(7 downto 0) := (others => '0');
	signal tx1_valid: std_logic := '0';
	signal tx1_ready: std_logic;
	signal line1: std_logic;
	signal rx1_data: std_logic_vector(7 downto 0);
	signal rx1_valid, rx1_err: std_logic;
	signal rx1_count: natural := 0;
	signal rx1_bad: natural := 0;
	signal rx1_errs: natural := 0;

	-- Path 2: 115,200 baud loopback
	signal tx2_data: std_logic_vector(7 downto 0) := (others => '0');
	signal tx2_valid: std_logic := '0';
	signal tx2_ready: std_logic;
	signal line2: std_logic;
	signal rx2_data: std_logic_vector(7 downto 0);
	signal rx2_valid, rx2_err: std_logic;

	-- Path 3: testbench serial source into a 1 Mbaud receiver
	signal line3: std_logic := '1';
	signal rx3_data: std_logic_vector(7 downto 0);
	signal rx3_valid, rx3_err: std_logic;
	type byte_log_t is array (0 to 63) of std_logic_vector(7 downto 0);
	signal rx3_log: byte_log_t := (others => (others => '0'));
	signal rx3_bytes: natural := 0;
	signal rx3_ferrs: natural := 0;

	-- Drive one 8N1 frame with the given bit time and stop bit level
	procedure send_serial(signal line: out std_logic; data: std_logic_vector(7 downto 0);
		bit_time: time; stop: std_logic) is
	begin
		line <= '0';
		wait for bit_time;
		for i in 0 to 7 loop
			line <= data(i);
			wait for bit_time;
		end loop;
		line <= stop;
		wait for bit_time;
		line <= '1';
	end procedure;

begin
	tx1: uart_tx
		generic map (
			BAUD => 1_000_000
		)
		port map (
			clk_i => clk,
			rst_i => rst,
			data_i => tx1_data,
			valid_i => tx1_valid,
			ready_o => tx1_ready,
			tx_o => line1
		);

	rx1: uart_rx
		generic map (
			BAUD => 1_000_000
		)
		port map (
			clk_i => clk,
			rst_i => rst,
			rx_i => line1,
			data_o => rx1_data,
			valid_o => rx1_valid,
			frame_err_o => rx1_err
		);

	tx2: uart_tx
		generic map (
			BAUD => 115_200
		)
		port map (
			clk_i => clk,
			rst_i => rst,
			data_i => tx2_data,
			valid_i => tx2_valid,
			ready_o => tx2_ready,
			tx_o => line2
		);

	rx2: uart_rx
		generic map (
			BAUD => 115_200
		)
		port map (
			clk_i => clk,
			rst_i => rst,
			rx_i => line2,
			data_o => rx2_data,
			valid_o => rx2_valid,
			frame_err_o => rx2_err
		);

	rx3: uart_rx
		generic map (
			BAUD => 1_000_000
		)
		port map (
			clk_i => clk,
			rst_i => rst,
			rx_i => line3,
			data_o => rx3_data,
			valid_o => rx3_valid,
			frame_err_o => rx3_err
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

	-- Path 1 receiver checker: bytes must arrive as 0, 1, 2, ... (x 37)
	process(clk)
	begin
		if rising_edge(clk) then
			if (rx1_valid = '1') then
				if (unsigned(rx1_data) /= to_unsigned((rx1_count * 37) mod 256, 8)) then
					rx1_bad <= rx1_bad + 1;
				end if;
				rx1_count <= rx1_count + 1;
			end if;
			if (rx1_err = '1') then
				rx1_errs <= rx1_errs + 1;
			end if;
		end if;
	end process;

	-- Path 1 sender: back to back through valid/ready
	process
		variable t_first, t_last: time;
	begin
		wait until (rst = '0');
		wait until rising_edge(clk);
		for i in 0 to LOOP_BYTES - 1 loop
			tx1_data <= std_logic_vector(to_unsigned((i * 37) mod 256, 8));
			tx1_valid <= '1';
			loop
				wait until rising_edge(clk);
				exit when (tx1_ready = '1');
			end loop;
			if (i = 0) then
				t_first := now;
			end if;
			t_last := now;
		end loop;
		tx1_valid <= '0';
		-- 255 frames between the first and the last handshake: exactly
		-- 10 bit times each when there is no gap
		chk.check(t_last - t_first = 255 * 10 * 1000 ns, "no gap between frames, took " &
			time'image(t_last - t_first));
		wait;
	end process;

	-- Stimulus for paths 2 and 3 and the bit timing check
	process
		variable t0, t1: time;
	begin
		wait until (rst = '0');

		-- 2. Bit timing of path 1: watch the first frame (data 0x00:
		-- start bit and 8 data bits low = 9000 ns, then a 1000 ns stop)
		wait until falling_edge(line1);
		t0 := now;
		wait until rising_edge(line1);
		t1 := now;
		chk.check(t1 - t0 = 9000 ns, "start + 8 zero bits last 9000 ns, got " &
			time'image(t1 - t0));
		-- Second frame is 37 = 0x25 = 10100100 LSB first: 1,0,1,0,0,1,0,0.
		-- The line falls at its start bit right after the stop bit.
		wait until falling_edge(line1);
		chk.check(now - t1 = 1000 ns, "stop bit lasts 1000 ns, got " & time'image(now - t1));
		t0 := now;
		wait until rising_edge(line1);
		chk.check(now - t0 = 1000 ns, "start bit lasts 1000 ns");

		-- 3. 115,200 baud loopback
		for i in 0 to 7 loop
			tx2_data <= std_logic_vector(to_unsigned(16#A5# + 17 * i, 8));
			tx2_valid <= '1';
			loop
				wait until rising_edge(clk);
				exit when (tx2_ready = '1');
			end loop;
			tx2_valid <= '0';
			loop
				wait until rising_edge(clk);
				exit when ((rx2_valid = '1') or (rx2_err = '1'));
			end loop;
			chk.check((rx2_valid = '1') and
				(unsigned(rx2_data) = to_unsigned((16#A5# + 17 * i) mod 256, 8)),
				"115200 byte " & integer'image(i) & " got " & to_hex(rx2_data));
		end loop;

		wait;
	end process;

	-- Path 3 recorder: every byte and framing error from rx3
	process(clk)
	begin
		if rising_edge(clk) then
			if (rx3_valid = '1') then
				rx3_log(rx3_bytes mod 64) <= rx3_data;
				rx3_bytes <= rx3_bytes + 1;
			end if;
			if (rx3_err = '1') then
				rx3_ferrs <= rx3_ferrs + 1;
			end if;
		end if;
	end process;

	-- Path 3 (the only driver of line3): 4. baud error, checks, then
	-- 5. framing error and recovery
	process
	begin
		wait until (rst = '0');
		wait for 1 us;
		-- 4. Baud error on the receive side: 3% slow, 3% fast
		for i in 0 to 15 loop
			send_serial(line3, std_logic_vector(to_unsigned(i * 16 + 15 - i, 8)), 1030 ns, '1');
		end loop;
		wait for 100 ns;
		for i in 0 to 15 loop
			send_serial(line3, std_logic_vector(to_unsigned(255 - i * 13, 8)), 970 ns, '1');
		end loop;
		wait until (rx1_count = LOOP_BYTES);
		wait for 400 us; -- Path 2 finishes well before this
		chk.check(rx3_bytes = 32, "baud error test received " & integer'image(rx3_bytes) &
			" of 32 bytes");
		chk.check(rx3_ferrs = 0, "no framing errors at +/-3% baud error");
		for i in 0 to 15 loop
			chk.check(unsigned(rx3_log(i)) = to_unsigned(i * 16 + 15 - i, 8),
				"3% slow byte " & integer'image(i) & " got " & to_hex(rx3_log(i)));
			chk.check(unsigned(rx3_log(16 + i)) = to_unsigned(255 - i * 13, 8),
				"3% fast byte " & integer'image(i) & " got " & to_hex(rx3_log(16 + i)));
		end loop;

		-- A frame with a low stop bit, then the line held low (break)
		send_serial(line3, x"3C", 1000 ns, '0');
		line3 <= '0';
		wait for 30 us;
		chk.check(rx3_ferrs = 1, "exactly one framing error, got " & integer'image(rx3_ferrs));
		chk.check(rx3_bytes = 32, "no byte from a bad frame or a break");
		line3 <= '1';
		wait for 3 us;
		send_serial(line3, x"C3", 1000 ns, '1');
		wait for 2 us;
		chk.check(rx3_bytes = 33, "byte received after the break");
		chk.check(rx3_log(32) = x"C3", "byte after the break is " & to_hex(rx3_log(32)));

		chk.check(rx1_count = LOOP_BYTES, "loopback received " & integer'image(rx1_count) &
			" bytes");
		chk.check(rx1_bad = 0, "loopback wrong bytes: " & integer'image(rx1_bad));
		chk.check(rx1_errs = 0, "loopback framing errors: " & integer'image(rx1_errs));
		done <= true;
		tb_finish("tb_uart", chk.checks, chk.errors);
		wait;
	end process;
end arch;

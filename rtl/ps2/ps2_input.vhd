--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    PS/2 Keyboard and Mouse Input
-- Module Name:    ps2_input
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    The whole PS/2 input block:
--                 a ps2_host for the keyboard (receive only) and one for
--                 the mouse, the scan code decoder (ps2_keyboard), the
--                 mouse start-up and packet driver (ps2_mouse) and the
--                 per-frame snapshot (input_snapshot). Also keeps what
--                 the bring-up input page shows: the last 16 bytes from
--                 each device and error counts.
--                 Pins: the *_pull_o outputs are '1' to drive a line
--                 low; the top level makes each line open drain
--                 (line <= '0' when pull = '1' else 'Z', never '1') and
--                 feeds the line back on the *_i inputs. enable_i is the
--                 PWR_SENSE gate (pcb_on): while '0' both devices are
--                 held idle and all four lines are released.
--                 Timing generics are in microseconds and converted to
--                 clock cycles with CLK_HZ; simulations shorten them.
--                 Error counts saturate at 255. The mouse timeout byte
--                 (ms_errors_o 23:16) also counts send errors (no
--                 response from the mouse to FF or F4 within 20 ms).
--                 Clock domain: clk_i (system). PS/2 pins asynchronous.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, game_pkg, ps2_host (ps2_rx, ps2_tx,
--                 synchronizer), ps2_keyboard, ps2_mouse, input_snapshot
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
use work.game_pkg.all;

entity ps2_input is
	generic(
		CLK_HZ: natural := 100_000_000; -- System clock
		SAMPLE_HZ: natural := 1_000_000; -- Glitch filter sample rate
		RX_TIMEOUT_US: natural := 2_000; -- Abandon a partial frame
		TX_INHIBIT_US: natural := 150; -- Clock held low before a command
		TX_TIMEOUT_US: natural := 20_000; -- Whole command exchange limit
		MOUSE_STARTUP_US: natural := 500_000; -- Delay before the first FF
		MOUSE_RESP_US: natural := 1_000_000; -- Wait for each start-up reply
		PACKET_GAP_US: natural := 3_000; -- Silence that starts a new packet
		MOUSE_SHIFT: natural := 1; -- Turn = mouse dx / 2^MOUSE_SHIFT
		KEY_TURN: natural := 6 -- Turn per frame from an arrow key
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		enable_i: in std_logic; -- PWR_SENSE gate: '0' = idle, lines released
		kb_clk_i: in std_logic; -- Keyboard clock line (pin read)
		kb_dat_i: in std_logic; -- Keyboard data line (pin read)
		ms_clk_i: in std_logic; -- Mouse clock line (pin read)
		ms_dat_i: in std_logic; -- Mouse data line (pin read)
		kb_clk_pull_o: out std_logic; -- '1' = drive the keyboard clock low
		kb_dat_pull_o: out std_logic; -- '1' = drive the keyboard data low
		ms_clk_pull_o: out std_logic; -- '1' = drive the mouse clock low
		ms_dat_pull_o: out std_logic; -- '1' = drive the mouse data low
		frame_start_i: in std_logic; -- Pulse: latch a snapshot
		snapshot_o: out std_logic_vector(39 downto 0); -- Per-frame snapshot
		snapshot_valid_o: out std_logic; -- Pulse: new snapshot
		keys_o: out std_logic_vector(KEYS_N - 1 downto 0); -- Held keys (KEY_*)
		mouse_buttons_o: out std_logic_vector(2 downto 0); -- BTN_* positions
		mouse_x_total_o: out std_logic_vector(15 downto 0); -- Running dx total
		mouse_y_total_o: out std_logic_vector(15 downto 0); -- Running dy total
		mouse_state_o: out std_logic_vector(3 downto 0); -- ps2_mouse state code
		mouse_retries_o: out std_logic_vector(7 downto 0); -- Failed start-ups
		kb_history_o: out std_logic_vector(127 downto 0); -- Last 16 bytes, 7:0 newest
		ms_history_o: out std_logic_vector(127 downto 0); -- Last 16 bytes, 7:0 newest
		kb_errors_o: out std_logic_vector(23 downto 0); -- Timeout, framing, parity
		ms_errors_o: out std_logic_vector(23 downto 0) -- Timeout + tx, framing, parity
	);
end ps2_input;

architecture arch of ps2_input is
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
	component ps2_keyboard is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			en_i: in std_logic;
			rx_data_i: in std_logic_vector(7 downto 0);
			rx_valid_i: in std_logic;
			keys_o: out std_logic_vector(KEYS_N - 1 downto 0)
		);
	end component;
	component ps2_mouse is
		generic(
			STARTUP_CYCLES: positive := 50_000_000;
			RESP_TIMEOUT_CYCLES: positive := 100_000_000;
			PACKET_GAP_CYCLES: positive := 300_000
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			en_i: in std_logic;
			rx_data_i: in std_logic_vector(7 downto 0);
			rx_valid_i: in std_logic;
			tx_data_o: out std_logic_vector(7 downto 0);
			tx_valid_o: out std_logic;
			tx_ready_i: in std_logic;
			tx_done_i: in std_logic;
			tx_err_i: in std_logic;
			take_i: in std_logic;
			dx_o: out std_logic_vector(15 downto 0);
			dy_o: out std_logic_vector(15 downto 0);
			buttons_o: out std_logic_vector(2 downto 0);
			x_total_o: out std_logic_vector(15 downto 0);
			y_total_o: out std_logic_vector(15 downto 0);
			state_o: out std_logic_vector(3 downto 0);
			retries_o: out std_logic_vector(7 downto 0)
		);
	end component;
	component input_snapshot is
		generic(
			MOUSE_SHIFT: natural := 1;
			KEY_TURN: natural := 6
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			frame_start_i: in std_logic;
			keys_i: in std_logic_vector(KEYS_N - 1 downto 0);
			buttons_i: in std_logic_vector(2 downto 0);
			mouse_dx_i: in std_logic_vector(15 downto 0);
			take_o: out std_logic;
			snapshot_o: out std_logic_vector(SNAP_BITS - 1 downto 0);
			valid_o: out std_logic
		);
	end component;

	-- Larger of two naturals (maximum() is VHDL-2008)
	function max_nat(a, b: natural) return natural is
	begin
		if (a > b) then
			return a;
		end if;
		return b;
	end function;

	-- Microseconds to clock cycles (at least 1)
	function us_cycles(us: natural) return positive is
	begin
		return max_nat(1, natural(round(real(CLK_HZ) * real(us) / 1.0e6)));
	end function;

	constant SAMPLE_CYCLES: positive := max_nat(1, CLK_HZ / SAMPLE_HZ);
	constant RELEASE_US: natural := 10; -- Data low before the clock is released

	type count3_t is array (0 to 2) of unsigned(7 downto 0);

	signal kb_rx_data, ms_rx_data: std_logic_vector(7 downto 0);
	signal kb_rx_valid, ms_rx_valid: std_logic;
	signal kb_perr, kb_ferr, kb_tout: std_logic;
	signal ms_perr, ms_ferr, ms_tout: std_logic;
	signal ms_tx_data: std_logic_vector(7 downto 0);
	signal ms_tx_valid, ms_tx_ready, ms_tx_done, ms_tx_err: std_logic;
	signal keys: std_logic_vector(KEYS_N - 1 downto 0);
	signal buttons: std_logic_vector(2 downto 0);
	signal take: std_logic;
	signal mouse_dx: std_logic_vector(15 downto 0);
	signal kb_hist, ms_hist: std_logic_vector(127 downto 0) := (others => '0');
	signal kb_cnt, ms_cnt: count3_t := (others => (others => '0'));
begin
	kb_host: ps2_host
		generic map (
			SAMPLE_CYCLES => SAMPLE_CYCLES,
			RX_TIMEOUT_CYCLES => us_cycles(RX_TIMEOUT_US),
			TX_INHIBIT_CYCLES => us_cycles(TX_INHIBIT_US),
			TX_RELEASE_CYCLES => us_cycles(RELEASE_US),
			TX_TIMEOUT_CYCLES => us_cycles(TX_TIMEOUT_US)
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			en_i => enable_i,
			ps2_clk_i => kb_clk_i,
			ps2_dat_i => kb_dat_i,
			clk_pull_o => kb_clk_pull_o,
			dat_pull_o => kb_dat_pull_o,
			rx_data_o => kb_rx_data,
			rx_valid_o => kb_rx_valid,
			rx_parity_err_o => kb_perr,
			rx_frame_err_o => kb_ferr,
			rx_timeout_o => kb_tout,
			tx_data_i => x"00",
			tx_valid_i => '0', -- The keyboard needs no commands
			tx_ready_o => open,
			tx_done_o => open,
			tx_err_o => open
		);

	ms_host: ps2_host
		generic map (
			SAMPLE_CYCLES => SAMPLE_CYCLES,
			RX_TIMEOUT_CYCLES => us_cycles(RX_TIMEOUT_US),
			TX_INHIBIT_CYCLES => us_cycles(TX_INHIBIT_US),
			TX_RELEASE_CYCLES => us_cycles(RELEASE_US),
			TX_TIMEOUT_CYCLES => us_cycles(TX_TIMEOUT_US)
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			en_i => enable_i,
			ps2_clk_i => ms_clk_i,
			ps2_dat_i => ms_dat_i,
			clk_pull_o => ms_clk_pull_o,
			dat_pull_o => ms_dat_pull_o,
			rx_data_o => ms_rx_data,
			rx_valid_o => ms_rx_valid,
			rx_parity_err_o => ms_perr,
			rx_frame_err_o => ms_ferr,
			rx_timeout_o => ms_tout,
			tx_data_i => ms_tx_data,
			tx_valid_i => ms_tx_valid,
			tx_ready_o => ms_tx_ready,
			tx_done_o => ms_tx_done,
			tx_err_o => ms_tx_err
		);

	kbd: ps2_keyboard
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			en_i => enable_i,
			rx_data_i => kb_rx_data,
			rx_valid_i => kb_rx_valid,
			keys_o => keys
		);

	mouse: ps2_mouse
		generic map (
			STARTUP_CYCLES => us_cycles(MOUSE_STARTUP_US),
			RESP_TIMEOUT_CYCLES => us_cycles(MOUSE_RESP_US),
			PACKET_GAP_CYCLES => us_cycles(PACKET_GAP_US)
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			en_i => enable_i,
			rx_data_i => ms_rx_data,
			rx_valid_i => ms_rx_valid,
			tx_data_o => ms_tx_data,
			tx_valid_o => ms_tx_valid,
			tx_ready_i => ms_tx_ready,
			tx_done_i => ms_tx_done,
			tx_err_i => ms_tx_err,
			take_i => take,
			dx_o => mouse_dx,
			dy_o => open,
			buttons_o => buttons,
			x_total_o => mouse_x_total_o,
			y_total_o => mouse_y_total_o,
			state_o => mouse_state_o,
			retries_o => mouse_retries_o
		);

	snap: input_snapshot
		generic map (
			MOUSE_SHIFT => MOUSE_SHIFT,
			KEY_TURN => KEY_TURN
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			frame_start_i => frame_start_i,
			keys_i => keys,
			buttons_i => buttons,
			mouse_dx_i => mouse_dx,
			take_o => take,
			snapshot_o => snapshot_o,
			valid_o => snapshot_valid_o
		);

	-- Bring-up page: byte histories and saturating error counts
	process(clk_i, rst_i)
		variable kb_ev, ms_ev: std_logic_vector(2 downto 0);
	begin
		if (rst_i = '1') then
			kb_hist <= (others => '0');
			ms_hist <= (others => '0');
			kb_cnt <= (others => (others => '0'));
			ms_cnt <= (others => (others => '0'));
		elsif rising_edge(clk_i) then
			if (kb_rx_valid = '1') then
				kb_hist <= kb_hist(119 downto 0) & kb_rx_data; -- Newest byte in bits 7:0
			end if;
			if (ms_rx_valid = '1') then
				ms_hist <= ms_hist(119 downto 0) & ms_rx_data;
			end if;
			-- Counter (and output byte) 0 parity, 1 frame, 2 timeout errors
			kb_ev := kb_tout & kb_ferr & kb_perr;
			ms_ev := (ms_tout or ms_tx_err) & ms_ferr & ms_perr;
			for i in 0 to 2 loop
				if ((kb_ev(i) = '1') and (kb_cnt(i) /= x"FF")) then
					kb_cnt(i) <= kb_cnt(i) + 1;
				end if;
				if ((ms_ev(i) = '1') and (ms_cnt(i) /= x"FF")) then
					ms_cnt(i) <= ms_cnt(i) + 1;
				end if;
			end loop;
		end if;
	end process;

	keys_o <= keys;
	mouse_buttons_o <= buttons;
	kb_history_o <= kb_hist;
	ms_history_o <= ms_hist;
	errors: for i in 0 to 2 generate
		kb_errors_o(8 * i + 7 downto 8 * i) <= std_logic_vector(kb_cnt(i));
		ms_errors_o(8 * i + 7 downto 8 * i) <= std_logic_vector(ms_cnt(i));
	end generate;
end arch;

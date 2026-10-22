--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    PS/2 Keyboard and Mouse Input Testbench
-- Module Name:    tb_ps2_input
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for the whole PS/2 input block
--                 (ps2_input) with a keyboard model and a mouse model on
--                 open-drain lines. System clock 10 MHz (CLK_HZ generic)
--                 and a 2 ms mouse start-up delay keep it short; the
--                 PS/2 timing is real.
--                 Tests:
--                 - enable low: lines released, mouse off; enable high:
--                   full mouse start-up (FF, FA AA 00, F4, FA)
--                 - make and break codes, E0 keys, fake shift E0 12, the
--                   E1 Pause sequence, Right Shift, a keyboard parity
--                   error counted
--                 - snapshot fields: move, strafe, run, fire, duck, peek,
--                   arrow-key turn, and the edge bits (use, weapon_sel,
--                   weapon_cycle, automap, menu, debug) set only on the
--                   first frame of a press
--                 - mouse packets: negative dx, two packets summed in one
--                   frame, an overflow packet dropped, a slipped framing
--                   byte, a packet resynchronized after a long gap,
--                   buttons; running totals
--                 - AA 00 from a replugged mouse restarts the start-up
--                 - byte histories, and enable low clearing the keys
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std, tb_pkg,
--                 game_pkg, ps2_device_model, ps2_input
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
use work.game_pkg.all;

entity tb_ps2_input is
end tb_ps2_input;

architecture arch of tb_ps2_input is
	component ps2_input is
		generic(
			CLK_HZ: natural := 100_000_000;
			SAMPLE_HZ: natural := 1_000_000;
			RX_TIMEOUT_US: natural := 2_000;
			TX_INHIBIT_US: natural := 150;
			TX_TIMEOUT_US: natural := 20_000;
			MOUSE_STARTUP_US: natural := 500_000;
			MOUSE_RESP_US: natural := 1_000_000;
			PACKET_GAP_US: natural := 3_000;
			MOUSE_SHIFT: natural := 1;
			KEY_TURN: natural := 6
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			enable_i: in std_logic;
			kb_clk_i: in std_logic;
			kb_dat_i: in std_logic;
			ms_clk_i: in std_logic;
			ms_dat_i: in std_logic;
			kb_clk_pull_o: out std_logic;
			kb_dat_pull_o: out std_logic;
			ms_clk_pull_o: out std_logic;
			ms_dat_pull_o: out std_logic;
			frame_start_i: in std_logic;
			snapshot_o: out std_logic_vector(39 downto 0);
			snapshot_valid_o: out std_logic;
			keys_o: out std_logic_vector(KEYS_N - 1 downto 0);
			mouse_buttons_o: out std_logic_vector(2 downto 0);
			mouse_x_total_o: out std_logic_vector(15 downto 0);
			mouse_y_total_o: out std_logic_vector(15 downto 0);
			mouse_state_o: out std_logic_vector(3 downto 0);
			mouse_retries_o: out std_logic_vector(7 downto 0);
			kb_history_o: out std_logic_vector(127 downto 0);
			ms_history_o: out std_logic_vector(127 downto 0);
			kb_errors_o: out std_logic_vector(23 downto 0);
			ms_errors_o: out std_logic_vector(23 downto 0)
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
	constant STREAMING: natural := 10; -- ps2_mouse state code
	type bytes_t is array (natural range <>) of std_logic_vector(7 downto 0);
	constant PAUSE_SEQ: bytes_t := (x"E1", x"14", x"77", x"E1", x"F0", x"14", x"F0", x"77");
	constant HELD_KEYS: bytes_t := (x"23", x"21", x"15", x"24", x"14", x"1C");
	constant EDGE_KEYS: bytes_t := (x"29", x"1E", x"26", x"0D", x"76", x"05");
	shared variable chk: checker_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal done: boolean := false;
	signal enable: std_logic := '0';

	signal kb_clk, kb_dat, ms_clk, ms_dat: std_logic;
	signal kb_clk_pull, kb_dat_pull, ms_clk_pull, ms_dat_pull: std_logic;
	signal frame_start: std_logic := '0';
	signal snapshot: std_logic_vector(39 downto 0);
	signal snapshot_valid: std_logic;
	signal keys: std_logic_vector(KEYS_N - 1 downto 0);
	signal buttons: std_logic_vector(2 downto 0);
	signal x_total, y_total: std_logic_vector(15 downto 0);
	signal mstate: std_logic_vector(3 downto 0);
	signal retries: std_logic_vector(7 downto 0);
	signal kb_hist, ms_hist: std_logic_vector(127 downto 0);
	signal kb_errs, ms_errs: std_logic_vector(23 downto 0);

	signal kb_send, ms_send: boolean := false;
	signal kb_byte, ms_byte: std_logic_vector(7 downto 0) := (others => '0');
	signal kb_mode, ms_mode: natural := 0;
	signal kb_sent, ms_sent: natural;
	signal ms_rx_byte, kb_rx_byte: std_logic_vector(7 downto 0);
	signal ms_rx_count, kb_rx_count, ms_rx_perr, kb_rx_perr: natural;

	function turn_of(s: std_logic_vector(39 downto 0)) return integer is
	begin
		return to_integer(signed(s(SNAP_TURN_HI downto SNAP_TURN_LO)));
	end function;

	function move_of(s: std_logic_vector(39 downto 0)) return integer is
	begin
		return to_integer(signed(s(SNAP_MOVE_HI downto SNAP_MOVE_LO)));
	end function;

	function strafe_of(s: std_logic_vector(39 downto 0)) return integer is
	begin
		return to_integer(signed(s(SNAP_STRAFE_HI downto SNAP_STRAFE_LO)));
	end function;

	function wsel_of(s: std_logic_vector(39 downto 0)) return natural is
	begin
		return to_integer(unsigned(s(SNAP_WSEL_HI downto SNAP_WSEL_LO)));
	end function;
begin
	dut: ps2_input
		generic map (
			CLK_HZ => 10_000_000,
			MOUSE_STARTUP_US => 2_000,
			MOUSE_RESP_US => 20_000
		)
		port map (
			clk_i => clk,
			rst_i => rst,
			enable_i => enable,
			kb_clk_i => to_x01(kb_clk),
			kb_dat_i => to_x01(kb_dat),
			ms_clk_i => to_x01(ms_clk),
			ms_dat_i => to_x01(ms_dat),
			kb_clk_pull_o => kb_clk_pull,
			kb_dat_pull_o => kb_dat_pull,
			ms_clk_pull_o => ms_clk_pull,
			ms_dat_pull_o => ms_dat_pull,
			frame_start_i => frame_start,
			snapshot_o => snapshot,
			snapshot_valid_o => snapshot_valid,
			keys_o => keys,
			mouse_buttons_o => buttons,
			mouse_x_total_o => x_total,
			mouse_y_total_o => y_total,
			mouse_state_o => mstate,
			mouse_retries_o => retries,
			kb_history_o => kb_hist,
			ms_history_o => ms_hist,
			kb_errors_o => kb_errs,
			ms_errors_o => ms_errs
		);

	-- Open-drain buses with 10 kohm pull-ups
	kb_clk <= 'H';
	kb_dat <= 'H';
	ms_clk <= 'H';
	ms_dat <= 'H';
	kb_clk <= '0' when (kb_clk_pull = '1') else 'Z';
	kb_dat <= '0' when (kb_dat_pull = '1') else 'Z';
	ms_clk <= '0' when (ms_clk_pull = '1') else 'Z';
	ms_dat <= '0' when (ms_dat_pull = '1') else 'Z';

	kbd: ps2_device_model
		port map (
			clk_io => kb_clk,
			dat_io => kb_dat,
			send_i => kb_send,
			send_byte_i => kb_byte,
			send_mode_i => kb_mode,
			silent_i => false,
			sent_o => kb_sent,
			rx_byte_o => kb_rx_byte,
			rx_count_o => kb_rx_count,
			rx_parity_errors_o => kb_rx_perr
		);

	mouse: ps2_device_model
		generic map (
			MOUSE => true
		)
		port map (
			clk_io => ms_clk,
			dat_io => ms_dat,
			send_i => ms_send,
			send_byte_i => ms_byte,
			send_mode_i => ms_mode,
			silent_i => false,
			sent_o => ms_sent,
			rx_byte_o => ms_rx_byte,
			rx_count_o => ms_rx_count,
			rx_parity_errors_o => ms_rx_perr
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

	-- Stimulus
	process
		variable s: std_logic_vector(39 downto 0);
		variable t0: time;
		variable xt: integer;

		procedure kb_tx(b: std_logic_vector(7 downto 0); mode: natural := 0) is
			variable before: natural;
		begin
			before := kb_sent;
			kb_byte <= b;
			kb_mode <= mode;
			kb_send <= not kb_send;
			wait until (kb_sent = before + 1);
			wait for 50 us;
		end procedure;

		procedure ms_tx(b: std_logic_vector(7 downto 0)) is
			variable before: natural;
		begin
			before := ms_sent;
			ms_byte <= b;
			ms_mode <= 0;
			ms_send <= not ms_send;
			wait until (ms_sent = before + 1);
			wait for 50 us;
		end procedure;

		-- One frame start; returns the new snapshot
		procedure frame(variable snap: out std_logic_vector(39 downto 0)) is
		begin
			wait until rising_edge(clk);
			frame_start <= '1';
			wait until rising_edge(clk);
			frame_start <= '0';
			wait until rising_edge(clk);
			chk.check(snapshot_valid = '0', "snapshot not valid one cycle after frame start");
			wait until rising_edge(clk);
			snap := snapshot;
			chk.check(snapshot_valid = '1', "snapshot valid two cycles after frame start");
		end procedure;
	begin
		-- Disabled: everything released, mouse off
		wait until (rst = '0');
		wait for 1 ms;
		chk.check((kb_clk_pull = '0') and (kb_dat_pull = '0') and (ms_clk_pull = '0') and
			(ms_dat_pull = '0'), "lines released while disabled");
		chk.check(unsigned(mstate) = 0, "mouse off while disabled");
		chk.check(ms_rx_count = 0, "nothing sent to the mouse while disabled");

		-- Mouse start-up
		enable <= '1';
		t0 := now;
		wait until (unsigned(mstate) = STREAMING) for 50 ms;
		chk.check(unsigned(mstate) = STREAMING, "mouse streaming after start-up");
		chk.check((ms_rx_count = 2) and (ms_rx_byte = x"F4") and (ms_rx_perr = 0),
			"mouse got FF then F4");
		chk.check(ms_hist(31 downto 0) = x"FAAA00FA", "mouse replies FA AA 00 FA, got " &
			to_hex(ms_hist(31 downto 0)));
		chk.check(unsigned(retries) = 0, "no start-up retries");
		tb_print("mouse start-up took " & time'image(now - t0));

		-- Keyboard make and break
		kb_tx(x"1D");
		chk.check(keys(KEY_W) = '1', "W held");
		frame(s);
		chk.check(move_of(s) = 1, "W moves forward");
		kb_tx(x"F0");
		kb_tx(x"1D");
		chk.check(keys(KEY_W) = '0', "W released");

		-- Extended keys
		kb_tx(x"E0");
		kb_tx(x"72");
		chk.check(keys(KEY_DOWN) = '1', "Down held");
		frame(s);
		chk.check(move_of(s) = -1, "Down moves back");
		kb_tx(x"1D");
		frame(s);
		chk.check(move_of(s) = 0, "W and Down cancel");
		kb_tx(x"F0");
		kb_tx(x"1D");
		kb_tx(x"E0");
		kb_tx(x"F0");
		kb_tx(x"72");
		chk.check(unsigned(keys) = 0, "all keys released");

		-- Fake shift and Pause are ignored; Right Shift works
		kb_tx(x"E0");
		kb_tx(x"12");
		chk.check(keys(KEY_LSHIFT) = '0', "E0 12 fake shift ignored");
		for i in PAUSE_SEQ'range loop
			kb_tx(PAUSE_SEQ(i));
		end loop;
		chk.check(unsigned(keys) = 0, "Pause sequence changes no key");
		kb_tx(x"59");
		frame(s);
		chk.check(s(SNAP_RUN) = '1', "Right Shift runs");
		kb_tx(x"F0");
		kb_tx(x"59");

		-- Held keys into the snapshot
		kb_tx(x"23"); -- D
		kb_tx(x"21"); -- C
		kb_tx(x"15"); -- Q
		kb_tx(x"24"); -- E
		kb_tx(x"14"); -- Left Ctrl
		kb_tx(x"E0");
		kb_tx(x"74"); -- Right arrow
		frame(s);
		chk.check(strafe_of(s) = 1, "D strafes right");
		chk.check((s(SNAP_DUCK) = '1') and (s(SNAP_PEEK_L) = '1') and (s(SNAP_PEEK_R) = '1'),
			"duck and peek bits");
		chk.check(s(SNAP_FIRE) = '1', "Ctrl fires");
		chk.check(turn_of(s) = 6, "Right arrow turns +6, got " & integer'image(turn_of(s)));
		chk.check(s(39 downto 28) = x"000", "spare bits zero");
		kb_tx(x"1C"); -- A as well
		kb_tx(x"E0");
		kb_tx(x"6B"); -- Left arrow as well
		frame(s);
		chk.check((strafe_of(s) = 0) and (turn_of(s) = 0), "opposite keys cancel");
		for i in HELD_KEYS'range loop
			kb_tx(x"F0");
			kb_tx(HELD_KEYS(i));
		end loop;
		kb_tx(x"E0");
		kb_tx(x"F0");
		kb_tx(x"74");
		kb_tx(x"E0");
		kb_tx(x"F0");
		kb_tx(x"6B");
		chk.check(unsigned(keys) = 0, "all keys released again");

		-- Edge bits: set on the first frame of a press only
		kb_tx(x"29"); -- Space
		kb_tx(x"1E"); -- 2
		kb_tx(x"26"); -- 3
		kb_tx(x"0D"); -- Tab
		kb_tx(x"76"); -- Esc
		kb_tx(x"05"); -- F1
		frame(s);
		chk.check(s(SNAP_USE) = '1', "use on press");
		chk.check(wsel_of(s) = 2, "weapon 2 wins over 3");
		chk.check((s(SNAP_AUTOMAP) = '1') and (s(SNAP_MENU) = '1') and (s(SNAP_DEBUG) = '1'),
			"automap, menu, debug edges");
		frame(s);
		chk.check((s(SNAP_USE) = '0') and (wsel_of(s) = 0) and (s(SNAP_AUTOMAP) = '0') and
			(s(SNAP_MENU) = '0') and (s(SNAP_DEBUG) = '0'), "edges clear while held");
		for i in EDGE_KEYS'range loop
			kb_tx(x"F0");
			kb_tx(EDGE_KEYS(i));
		end loop;

		-- Keyboard parity error is counted
		kb_tx(x"1D", 1);
		chk.check(unsigned(kb_errs(7 downto 0)) = 1, "keyboard parity error counted");
		chk.check(keys(KEY_W) = '0', "bad byte not decoded");
		chk.check(kb_hist(15 downto 0) = x"F005", "keyboard history newest bytes F0 05, got " &
			to_hex(kb_hist(15 downto 0)));

		-- Mouse: negative dx, positive dy (packets are flags, dx, dy; flags bit 3 is always
		-- set, bit 4 is the X sign, bit 6 X overflow, bits 1..0 the right and left buttons)
		frame(s); -- clear any motion
		ms_tx(x"18"); -- bit 3, X sign
		ms_tx(x"F6"); -- dx = -10
		ms_tx(x"05"); -- dy = +5
		chk.check(to_integer(signed(x_total)) = -10, "x total -10, got " &
			integer'image(to_integer(signed(x_total))));
		chk.check(to_integer(signed(y_total)) = 5, "y total +5");
		frame(s);
		chk.check(turn_of(s) = -5, "dx -10 turns -5, got " & integer'image(turn_of(s)));
		frame(s);
		chk.check(turn_of(s) = 0, "motion cleared after a frame");

		-- Two packets in one frame add up
		ms_tx(x"08");
		ms_tx(x"14"); -- +20
		ms_tx(x"00");
		ms_tx(x"08");
		ms_tx(x"1E"); -- +30
		ms_tx(x"00");
		frame(s);
		chk.check(turn_of(s) = 25, "two packets summed, got " & integer'image(turn_of(s)));

		-- Overflow packet dropped
		xt := to_integer(signed(x_total));
		ms_tx(x"48"); -- X overflow
		ms_tx(x"10");
		ms_tx(x"10");
		chk.check(to_integer(signed(x_total)) = xt, "overflow packet dropped");

		-- Slipped framing byte dropped, next packet good
		ms_tx(x"00"); -- bit 3 clear: not a first byte
		ms_tx(x"08");
		ms_tx(x"04");
		ms_tx(x"00");
		chk.check(to_integer(signed(x_total)) = xt + 4, "resynchronized after a bad first byte");

		-- A lone first byte, then silence: the next byte starts a packet
		ms_tx(x"09");
		wait for 5 ms;
		ms_tx(x"08");
		ms_tx(x"02");
		ms_tx(x"00");
		chk.check(to_integer(signed(x_total)) = xt + 6, "resynchronized after a gap");
		chk.check(buttons = "000", "buttons from the resynchronized packet");

		-- Buttons: fire and the right-button edge
		ms_tx(x"0B"); -- left and right
		ms_tx(x"00");
		ms_tx(x"00");
		chk.check(buttons = "011", "left and right buttons");
		frame(s);
		chk.check((s(SNAP_FIRE) = '1') and (s(SNAP_WCYCLE) = '1'), "fire and weapon cycle");
		frame(s);
		chk.check((s(SNAP_FIRE) = '1') and (s(SNAP_WCYCLE) = '0'), "weapon cycle is an edge");
		ms_tx(x"08");
		ms_tx(x"00");
		ms_tx(x"00");
		chk.check(buttons = "000", "buttons released");

		-- Replugged mouse: AA 00 restarts the start-up
		ms_tx(x"AA");
		ms_tx(x"00");
		wait for 1 ms;
		chk.check(unsigned(mstate) /= STREAMING, "AA 00 restarts the mouse start-up");
		wait until (unsigned(mstate) = STREAMING) for 50 ms;
		chk.check((unsigned(mstate) = STREAMING) and (ms_rx_count = 4), "mouse streaming again");
		wait for 1 ms; -- The model finishes its FA reply before the next byte
		ms_tx(x"08");
		ms_tx(x"01");
		ms_tx(x"00");
		chk.check(to_integer(signed(x_total)) = xt + 7, "packets after the restart");

		-- Disable: keys cleared, lines released, mouse off
		kb_tx(x"1D");
		chk.check(keys(KEY_W) = '1', "W held before disable");
		enable <= '0';
		wait for 1 us;
		chk.check(unsigned(keys) = 0, "keys cleared while disabled");
		chk.check(unsigned(mstate) = 0, "mouse off while disabled");
		chk.check((kb_clk_pull = '0') and (kb_dat_pull = '0') and (ms_clk_pull = '0') and
			(ms_dat_pull = '0'), "lines released after disable");
		chk.check((unsigned(kb_errs(23 downto 8)) = 0) and (unsigned(ms_errs) = 0),
			"no unexpected errors");

		done <= true;
		tb_finish("tb_ps2_input", chk.checks, chk.errors);
		wait;
	end process;
end arch;

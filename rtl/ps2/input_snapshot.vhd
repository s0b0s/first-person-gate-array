--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Input Snapshot
-- Module Name:    input_snapshot
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Latches the per-frame input snapshot (40 bits, field
--                 positions SNAP_* in game_pkg) on
--                 frame_start_i, so the game and the replay recorder see
--                 actions, not keys:
--                   turn    (mouse dx this frame >>> MOUSE_SHIFT)
--                           + KEY_TURN if Right held - KEY_TURN if Left
--                           held, saturated to 12-bit signed,
--                           positive = clockwise (turn right)
--                   move    +1 W or Up, -1 S or Down, 0 both or neither
--                   strafe  +1 D, -1 A, 0 both or neither
--                   held    run (either Shift), fire (left button or
--                           either Ctrl), duck C, peek_l Q, peek_r E
--                   edges   pressed now and not at the previous frame
--                           start: use Space, weapon_sel 1/2/3 (lowest
--                           number wins), weapon_cycle right button,
--                           automap Tab, menu Esc, debug F1
--                   39:28   zero
--                 take_o is frame_start_i: the mouse driver returns the
--                 motion summed since the last frame on mouse_dx_i in
--                 the same cycle and clears its sum at that edge.
--                 Pipeline: at frame_start_i the inputs (mouse sum, keys,
--                 buttons, and the keys of the previous frame start) are
--                 registered; the snapshot is computed from those
--                 registers and latched one cycle later. The split keeps
--                 the mouse driver's saturating sum and the turn
--                 arithmetic out of the same clock cycle (together they
--                 missed 100 MHz by 0.74 ns).
--                 Clock domain: clk_i (system). snapshot_o and the
--                 valid_o pulse appear two cycles after frame_start_i.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, game_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - Registered inputs before the turn arithmetic
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.game_pkg.all;

entity input_snapshot is
	generic(
		MOUSE_SHIFT: natural := 1; -- Mouse sensitivity: dx is divided by 2^MOUSE_SHIFT
		KEY_TURN: natural := 6 -- Turn per frame from an arrow key (1024 per circle)
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		frame_start_i: in std_logic; -- Pulse: take a snapshot
		keys_i: in std_logic_vector(KEYS_N - 1 downto 0); -- Held keys
		buttons_i: in std_logic_vector(2 downto 0); -- Mouse buttons
		mouse_dx_i: in std_logic_vector(15 downto 0); -- Motion since the last take
		take_o: out std_logic; -- Pulse to the mouse driver: clear its sum
		snapshot_o: out std_logic_vector(SNAP_BITS - 1 downto 0); -- Last snapshot
		valid_o: out std_logic -- Pulse: new snapshot on snapshot_o
	);
end input_snapshot;

architecture arch of input_snapshot is
	signal snapshot: std_logic_vector(SNAP_BITS - 1 downto 0) := (others => '0');
	signal snapshot_next: std_logic_vector(SNAP_BITS - 1 downto 0);
	-- Stage 1: inputs sampled at frame_start_i
	signal dx_q: std_logic_vector(15 downto 0) := (others => '0');
	signal keys_q: std_logic_vector(KEYS_N - 1 downto 0) := (others => '0');
	signal keys_prev_q: std_logic_vector(KEYS_N - 1 downto 0) := (others => '0');
	signal buttons_q: std_logic_vector(2 downto 0) := (others => '0');
	signal right_prev_q: std_logic := '0';
	signal stage1: std_logic := '0';
	signal valid: std_logic := '0';

	-- -1, 0 or +1 as a 2-bit two's complement value
	function axis(plus: std_logic; minus: std_logic) return std_logic_vector is
	begin
		if ((plus = '1') and (minus = '0')) then
			return "01";
		elsif ((plus = '0') and (minus = '1')) then
			return "11";
		end if;
		return "00";
	end function;
begin
	-- Stage 2: the snapshot from the registered inputs
	process(keys_q, keys_prev_q, buttons_q, dx_q, right_prev_q)
		variable turn: signed(17 downto 0);
		variable k: std_logic_vector(KEYS_N - 1 downto 0);
		variable pressed: std_logic_vector(KEYS_N - 1 downto 0);
		variable s: std_logic_vector(SNAP_BITS - 1 downto 0);
	begin
		k := keys_q;
		pressed := keys_q and (not keys_prev_q);
		s := (others => '0');

		-- Turn: mouse then arrows, in 18 bits so nothing overflows before
		-- the 12-bit saturation
		turn := resize(shift_right(signed(dx_q), MOUSE_SHIFT), 18);
		if (k(KEY_RIGHT) = '1') then
			turn := turn + KEY_TURN;
		end if;
		if (k(KEY_LEFT) = '1') then
			turn := turn - KEY_TURN;
		end if;
		if (turn > 2047) then
			turn := to_signed(2047, 18);
		elsif (turn < -2048) then
			turn := to_signed(-2048, 18);
		end if;
		s(SNAP_TURN_HI downto SNAP_TURN_LO) := std_logic_vector(turn(11 downto 0));

		s(SNAP_MOVE_HI downto SNAP_MOVE_LO) := axis(k(KEY_W) or k(KEY_UP),
			k(KEY_S) or k(KEY_DOWN));
		s(SNAP_STRAFE_HI downto SNAP_STRAFE_LO) := axis(k(KEY_D), k(KEY_A));
		s(SNAP_RUN) := k(KEY_LSHIFT) or k(KEY_RSHIFT);
		s(SNAP_FIRE) := buttons_q(BTN_LEFT) or k(KEY_LCTRL) or k(KEY_RCTRL);
		s(SNAP_DUCK) := k(KEY_C);
		s(SNAP_PEEK_L) := k(KEY_Q);
		s(SNAP_PEEK_R) := k(KEY_E);
		s(SNAP_USE) := pressed(KEY_SPACE);
		if (pressed(KEY_1) = '1') then
			s(SNAP_WSEL_HI downto SNAP_WSEL_LO) := "01";
		elsif (pressed(KEY_2) = '1') then
			s(SNAP_WSEL_HI downto SNAP_WSEL_LO) := "10";
		elsif (pressed(KEY_3) = '1') then
			s(SNAP_WSEL_HI downto SNAP_WSEL_LO) := "11";
		end if;
		s(SNAP_WCYCLE) := buttons_q(BTN_RIGHT) and (not right_prev_q);
		s(SNAP_AUTOMAP) := pressed(KEY_TAB);
		s(SNAP_MENU) := pressed(KEY_ESC);
		s(SNAP_DEBUG) := pressed(KEY_F1);
		snapshot_next <= s;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			dx_q <= (others => '0');
			keys_q <= (others => '0');
			keys_prev_q <= (others => '0');
			buttons_q <= (others => '0');
			right_prev_q <= '0';
			stage1 <= '0';
			snapshot <= (others => '0');
			valid <= '0';
		elsif rising_edge(clk_i) then
			stage1 <= frame_start_i;
			valid <= stage1;
			if (frame_start_i = '1') then
				dx_q <= mouse_dx_i;
				keys_q <= keys_i;
				keys_prev_q <= keys_q; -- Keys at the previous frame start
				buttons_q <= buttons_i;
				right_prev_q <= buttons_q(BTN_RIGHT);
			end if;
			if (stage1 = '1') then
				snapshot <= snapshot_next;
			end if;
		end if;
	end process;

	take_o <= frame_start_i;
	snapshot_o <= snapshot;
	valid_o <= valid;
end arch;

--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    PS/2 Keyboard
-- Module Name:    ps2_keyboard
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Scan code set 2 decoder (the keyboard's default set, no
--                 setup commands needed). A key going down sends its make
--                 code (repeated while held); going up sends F0 and the
--                 code. Extended keys send E0 first (E0 code, E0 F0
--                 code). Only the keys the game uses are kept, one bit
--                 each in keys_o (game_pkg KEY_* positions):
--                   plain: W 1D, A 1C, S 1B, D 23, C 21, Q 15, E 24,
--                          Esc 76, Space 29, LShift 12, RShift 59,
--                          LCtrl 14, 1 16, 2 1E, 3 26, Tab 0D, F1 05
--                   E0:    Up 75, Down 72, Left 6B, Right 74, RCtrl 14
--                 The fake shifts that some keyboards wrap around
--                 extended keys (E0 12, E0 59) are not in the E0 table,
--                 so they are ignored. Pause sends E1 14 77 E1 F0 14 F0
--                 77 with no break code; after E1 the next 7 bytes are
--                 skipped. Other bytes (AA self-test, FA, errors) only
--                 clear the prefix flags.
--                 en_i = '0' releases every key.
--                 Clock domain: clk_i (system). keys_o changes one cycle
--                 after the byte that completes a code.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, game_pkg
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
use work.game_pkg.all;

entity ps2_keyboard is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		en_i: in std_logic; -- '0' releases every key
		rx_data_i: in std_logic_vector(7 downto 0); -- Byte from the PS/2 host
		rx_valid_i: in std_logic; -- Byte present (one cycle)
		keys_o: out std_logic_vector(KEYS_N - 1 downto 0) -- '1' while held
	);
end ps2_keyboard;

architecture arch of ps2_keyboard is
	constant NO_KEY: natural := KEYS_N;
	signal keys: std_logic_vector(KEYS_N - 1 downto 0) := (others => '0');
	signal keys_next: std_logic_vector(KEYS_N - 1 downto 0);
	signal ext: std_logic := '0'; -- E0 seen
	signal ext_next: std_logic;
	signal brk: std_logic := '0'; -- F0 seen
	signal brk_next: std_logic;
	signal skip: natural range 0 to 7 := 0; -- Pause bytes still to ignore
	signal skip_next: natural range 0 to 7;

	-- Key index of a scan code, NO_KEY if the game does not use it
	function key_of(e: std_logic; code: std_logic_vector(7 downto 0)) return natural is
	begin
		if (e = '1') then
			case code is
				when x"75" => return KEY_UP;
				when x"72" => return KEY_DOWN;
				when x"6B" => return KEY_LEFT;
				when x"74" => return KEY_RIGHT;
				when x"14" => return KEY_RCTRL;
				when others => return NO_KEY;
			end case;
		else
			case code is
				when x"1D" => return KEY_W;
				when x"1C" => return KEY_A;
				when x"1B" => return KEY_S;
				when x"23" => return KEY_D;
				when x"21" => return KEY_C;
				when x"15" => return KEY_Q;
				when x"24" => return KEY_E;
				when x"76" => return KEY_ESC;
				when x"29" => return KEY_SPACE;
				when x"12" => return KEY_LSHIFT;
				when x"59" => return KEY_RSHIFT;
				when x"14" => return KEY_LCTRL;
				when x"16" => return KEY_1;
				when x"1E" => return KEY_2;
				when x"26" => return KEY_3;
				when x"0D" => return KEY_TAB;
				when x"05" => return KEY_F1;
				when others => return NO_KEY;
			end case;
		end if;
	end function;
begin
	process(en_i, rx_valid_i, rx_data_i, keys, ext, brk, skip)
		variable k: natural range 0 to NO_KEY;
	begin
		keys_next <= keys;
		ext_next <= ext;
		brk_next <= brk;
		skip_next <= skip;
		if (en_i = '0') then
			keys_next <= (others => '0');
			ext_next <= '0';
			brk_next <= '0';
			skip_next <= 0;
		elsif (rx_valid_i = '1') then
			if (skip /= 0) then
				skip_next <= skip - 1;
			elsif (rx_data_i = x"E1") then
				skip_next <= 7;
				ext_next <= '0';
				brk_next <= '0';
			elsif (rx_data_i = x"E0") then
				ext_next <= '1';
			elsif (rx_data_i = x"F0") then
				brk_next <= '1';
			else
				k := key_of(ext, rx_data_i);
				if (k /= NO_KEY) then
					keys_next(k) <= not brk; -- Make code presses, F0 code releases
				end if;
				ext_next <= '0';
				brk_next <= '0';
			end if;
		end if;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			keys <= (others => '0');
			ext <= '0';
			brk <= '0';
			skip <= 0;
		elsif rising_edge(clk_i) then
			keys <= keys_next;
			ext <= ext_next;
			brk <= brk_next;
			skip <= skip_next;
		end if;
	end process;

	keys_o <= keys;
end arch;

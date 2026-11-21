--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    2D Overlay
-- Module Name:    overlay
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    2D overlay, drawn last into the back buffer: status bar,
--                 crosshair, weapon, messages, minimap or automap, PAUSED
--                 box, death text, debug counters, and the full-screen
--                 title, briefing, score and ending pages. Matches
--                 draw_overlay() in tools/model/overlay.py bit for bit.
--
--                 Structure: a small program of draw commands per screen
--                 (PROG, picked by the game flow in the HUD word) runs in
--                 order, so later commands overwrite earlier ones exactly as
--                 in the model. Commands:
--                   RECT  solid fill (also single pixels: the crosshair)
--                   TEXT  a string of the string ROM, font 8x8, scale 1 or
--                         2, only lit pixels written; optionally centered
--                   BLIT  the weapon art frame scaled x2 from SRAM, texel
--                         255 transparent
--                   MAP   minimap or automap: every seen tile as a cell x
--                         cell square, then the keys, the player and the
--                         direction cell at (p + 2 cos, sin) >> 16
--                 Each command has a condition on the HUD word (automap,
--                 not dead, message, paused, dead, debug).
--                 Strings: one ROM of 51 strings of up to 40 characters.
--                 Lowercase letters in a string are digit placeholders:
--                 a run of the same letter is one number field, printed
--                 right-aligned with leading spaces (the seconds field is
--                 zero padded), like num() in the model. The 17 number
--                 fields are converted to decimal once at the start
--                 (overlay_bcd, about 25 clocks each).
--                 Every pixel goes through one output register with
--                 valid/ready; pixels outside the screen are dropped there
--                 (the model's put() clips the same way).
--                 Clock domain: clk_i (system). Inputs must be stable from
--                 start_i until done_o; done_o pulses when the last pixel
--                 has been taken by the pixel port.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, game_pkg,
--                 render_types_pkg, render_pkg, game_tables_pkg, hw_pkg,
--                 palette_pkg, text_pkg, font_rom, overlay_bcd
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.02 - Character ROM output registered, pixel address
--                 by shift-add (full-design timing)
-- Revision 1.03 - Plain signals instead of records; one-process state machine;
--                 PROG entries are 64-bit command words (CMD_* fields)
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;
use work.game_pkg.all;
use work.render_types_pkg.all;
use work.render_pkg.all;
use work.game_tables_pkg.all;
use work.palette_pkg.all;
use work.text_pkg.all;

entity overlay is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		start_i: in std_logic; -- Pulse: draw the overlay
		buf_i: in std_logic; -- Framebuffer to draw into
		hud_i: in std_logic_vector(HUD_BITS - 1 downto 0); -- HUD word (render_types_pkg)
		player_x_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Player x, Q6.16 (map marker)
		player_y_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Player y, Q6.16
		angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0); -- Player angle (map arrow)
		keypos_i: in std_logic_vector(KEYPOS_BITS - 1 downto 0); -- Keys on the floor
		debug_i: in std_logic_vector(4 * 24 - 1 downto 0); -- Debug counters 0..3
		map_addr_o: out std_logic_vector(11 downto 0); -- Tile map read, y * 64 + x
		map_data_i: in std_logic_vector(23 downto 0); -- Tile word, 1 clock later
		seen_addr_o: out std_logic_vector(11 downto 0); -- Seen bit read, y * 64 + x
		seen_data_i: in std_logic; -- Seen bit, 1 clock later
		m_req_o: out std_logic; -- SRAM arbiter master (weapon art reads)
		m_addr_o: out std_logic_vector(18 downto 0);
		m_gnt_i: in std_logic;
		m_rvalid_i: in std_logic;
		m_rdata_i: in std_logic_vector(7 downto 0);
		pix_valid_o: out std_logic; -- Pixel write port
		pix_ready_i: in std_logic;
		pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
		busy_o: out std_logic; -- Drawing
		done_o: out std_logic -- Pulse: every pixel taken
	);
end overlay;

architecture arch of overlay is
	component font_rom is
		port(
			clk_i: in std_logic;
			char_i: in std_logic_vector(6 downto 0);
			row_i: in std_logic_vector(2 downto 0);
			bits_o: out std_logic_vector(7 downto 0)
		);
	end component;
	component overlay_bcd is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			value_i: in std_logic_vector(23 downto 0);
			done_o: out std_logic;
			digits_o: out std_logic_vector(31 downto 0)
		);
	end component;

	------------------------------------------------------------------
	-- Colors (tools/model/overlay.py)
	------------------------------------------------------------------
	-- 16 * ramp + shade: palette ramps of 16 shades, darkest first
	constant C_BAR: natural := 16 * 14 + 3;
	constant C_BLUE_KEY: natural := 16 * 10 + 13;
	constant C_RED_KEY: natural := 16 * 4 + 13;
	constant C_TITLE_BG: natural := 16 * 4 + 2;
	constant C_BRIEF_BG: natural := 16 * 10 + 2;
	constant C_SCORE_BG: natural := 16 * 7 + 2;
	constant C_END_BG: natural := 16 * 11 + 2;
	constant MAP_WALL: natural := COLOR_LIGHT_GRAY;
	constant MAP_OPEN: natural := COLOR_DARK_GRAY;
	constant MAP_DOOR: natural := COLOR_YELLOW;
	constant MAP_EXIT: natural := COLOR_LIGHT_GREEN;
	constant MAP_PLAYER: natural := COLOR_LIGHT_RED;
	constant MAP_DIR: natural := COLOR_YELLOW;

	------------------------------------------------------------------
	-- String ROM: 51 strings, 40 characters each (padded)
	------------------------------------------------------------------
	-- Placeholders: a health, b armor, c ammo, d weapon, e level, f kills,
	-- g total kills, h items, i total items, j secrets, k total secrets,
	-- l minutes, m seconds (zero padded), n o p q debug counters 0..3
	constant STR_LEVEL: string := "LEVEL e";
	constant STR_LEVEL_DONE: string := "LEVEL e DONE";
	constant STR_KILLS: string := "KILLS   fff / ggg";
	constant STR_ITEMS: string := "ITEMS   hhh / iii";
	constant STR_SECRETS: string := "SECRETS jjj / kkk";
	constant STR_TIME: string := "TIME     ll:mm";
	constant STR_HEALTH: string := "HEALTH";
	constant STR_ARMOR: string := "ARMOR";
	constant STR_AMMO: string := "AMMO";
	constant STR_WEAPON: string := "WEAPON";
	constant STR_KEYS: string := "KEYS";
	constant STR_V_HEALTH: string := "aaa%";
	constant STR_V_ARMOR: string := "bbb%";
	constant STR_V_AMMO: string := "ccc";
	constant STR_V_WEAPON: string := "d";
	constant STR_DBG0: string := "RENDER  nnnnnnn";
	constant STR_DBG1: string := "SRAM    ooooooo";
	constant STR_DBG2: string := "LATE    ppppppp";
	constant STR_DBG3: string := "SPRITES qqqqqqq";

	constant STR_COUNT: natural := 51;
	constant STR_LEN: natural := 40;
	constant MSG_BASE: natural := 28; -- String of message id m is MSG_BASE + m - 1
	constant BRIEF_BASE: natural := 39; -- Briefing line k of level n: BRIEF_BASE + 4 (n - 1) + k
	subtype str40_t is string(1 to STR_LEN);
	type str_table_t is array (0 to STR_COUNT - 1) of str40_t;
	type len_table_t is array (0 to STR_COUNT - 1) of natural;

	function pad(s: string) return str40_t is
		variable r: str40_t := (others => ' ');
	begin
		for i in 1 to s'length loop
			r(i) := s(s'low + i - 1);
		end loop;
		return r;
	end function;

	constant STRS: str_table_t := (
		pad(TITLE_0), pad(TITLE_1), pad(TITLE_2), pad(PRESS), pad(STR_LEVEL),
		pad(STR_LEVEL_DONE), pad(STR_KILLS), pad(STR_ITEMS), pad(STR_SECRETS), pad(STR_TIME),
		pad(END_0), pad(END_1), pad(END_2), pad(STR_HEALTH), pad(STR_ARMOR),
		pad(STR_AMMO), pad(STR_WEAPON), pad(STR_KEYS), pad(STR_V_HEALTH), pad(STR_V_ARMOR),
		pad(STR_V_AMMO), pad(STR_V_WEAPON), pad(PAUSED), pad(DIED), pad(STR_DBG0),
		pad(STR_DBG1), pad(STR_DBG2), pad(STR_DBG3), pad(MSG_1), pad(MSG_2),
		pad(MSG_3), pad(MSG_4), pad(MSG_5), pad(MSG_6), pad(MSG_7),
		pad(MSG_8), pad(MSG_9), pad(MSG_10), pad(MSG_11), pad(BRIEF_1_0),
		pad(BRIEF_1_1), pad(BRIEF_1_2), pad(BRIEF_1_3), pad(BRIEF_2_0), pad(BRIEF_2_1),
		pad(BRIEF_2_2), pad(BRIEF_2_3), pad(BRIEF_3_0), pad(BRIEF_3_1), pad(BRIEF_3_2),
		pad(BRIEF_3_3)
	);
	constant LENS: len_table_t := (
		TITLE_0'length, TITLE_1'length, TITLE_2'length, PRESS'length, STR_LEVEL'length,
		STR_LEVEL_DONE'length, STR_KILLS'length, STR_ITEMS'length, STR_SECRETS'length,
		STR_TIME'length, END_0'length, END_1'length, END_2'length, STR_HEALTH'length,
		STR_ARMOR'length, STR_AMMO'length, STR_WEAPON'length, STR_KEYS'length,
		STR_V_HEALTH'length, STR_V_ARMOR'length, STR_V_AMMO'length, STR_V_WEAPON'length,
		PAUSED'length, DIED'length, STR_DBG0'length, STR_DBG1'length, STR_DBG2'length,
		STR_DBG3'length, MSG_1'length, MSG_2'length, MSG_3'length, MSG_4'length,
		MSG_5'length, MSG_6'length, MSG_7'length, MSG_8'length, MSG_9'length,
		MSG_10'length, MSG_11'length, BRIEF_1_0'length, BRIEF_1_1'length, BRIEF_1_2'length,
		BRIEF_1_3'length, BRIEF_2_0'length, BRIEF_2_1'length, BRIEF_2_2'length,
		BRIEF_2_3'length, BRIEF_3_0'length, BRIEF_3_1'length, BRIEF_3_2'length,
		BRIEF_3_3'length
	);

	-- Character ROM entries, 9 bits: bit 8 = 0: ASCII in 6:0; bit 8 = 1: a
	-- digit of a number field, field in 4:0, digit position in 7:5 (0 =
	-- ones; the position of a placeholder is how many of the same letter
	-- follow it in its run)
	type char_rom_t is array (0 to 2047) of std_logic_vector(8 downto 0);

	function build_char_rom return char_rom_t is
		variable rom: char_rom_t := (others => (others => '0'));
		variable c: character;
		variable run: natural;
		variable code: natural;
	begin
		for s in 0 to STR_COUNT - 1 loop
			for i in 1 to STR_LEN loop
				c := STRS(s)(i);
				code := character'pos(c);
				if ((c >= 'a') and (c <= 'q')) then
					-- Placeholder: its digit position is the number of the same letter after it
					run := 0;
					for j in i + 1 to STR_LEN loop
						exit when STRS(s)(j) /= c;
						run := run + 1;
					end loop;
					rom(s * STR_LEN + i - 1) := '1' & std_logic_vector(to_unsigned(run, 3)) &
						std_logic_vector(to_unsigned(code - character'pos('a'), 5));
				else
					rom(s * STR_LEN + i - 1) := "00" & std_logic_vector(to_unsigned(code, 7));
				end if;
			end loop;
		end loop;
		return rom;
	end function;

	constant CHAR_ROM: char_rom_t := build_char_rom;

	------------------------------------------------------------------
	-- Draw programs
	------------------------------------------------------------------
	constant OP_RECT: natural := 0;
	constant OP_TEXT: natural := 1;
	constant OP_BLIT: natural := 2;
	constant OP_MAP: natural := 3;
	constant OP_END: natural := 4;
	constant C_ALWAYS: natural := 0;
	constant C_AUTOMAP: natural := 1; -- Automap on
	constant C_NOAUTO: natural := 2; -- Automap off
	constant C_NOAUTO_ALIVE: natural := 3; -- Automap off and not dead
	constant C_MSG: natural := 4; -- A message is shown
	constant C_PAUSED: natural := 5;
	constant C_DEAD: natural := 6;
	constant C_DEBUG: natural := 7;
	constant SEL_STATIC: natural := 0; -- String number from the command
	constant SEL_MSG: natural := 1; -- Message of the HUD word
	constant SEL_BRIEF: natural := 2; -- Briefing line (str) of the level
	constant CM_FIXED: natural := 0; -- Color from the command
	constant CM_KEY1: natural := 1; -- Blue if key 1 held, else dark gray
	constant CM_KEY2: natural := 2; -- Red if key 2 held, else dark gray

	-- Command word fields
	constant CMD_BITS: natural := 64;
	constant CMD_OP_LO: natural := 0; -- 2:0 OP_*
	constant CMD_OP_HI: natural := 2;
	constant CMD_COND_LO: natural := 3; -- 5:3 condition C_*
	constant CMD_COND_HI: natural := 5;
	constant CMD_X_LO: natural := 6; -- 16:6 x, signed
	constant CMD_X_HI: natural := 16;
	constant CMD_Y_LO: natural := 17; -- 27:17 y, signed
	constant CMD_Y_HI: natural := 27;
	constant CMD_W_LO: natural := 28; -- 36:28 rect width; map cell size
	constant CMD_W_HI: natural := 36;
	constant CMD_H_LO: natural := 37; -- 45:37 rect height
	constant CMD_H_HI: natural := 45;
	constant CMD_COLOR_LO: natural := 46; -- 53:46 palette index
	constant CMD_COLOR_HI: natural := 53;
	constant CMD_MODE_LO: natural := 54; -- 55:54 RECT: color mode CM_*; TEXT: string select SEL_*
	constant CMD_MODE_HI: natural := 55;
	constant CMD_SCALE2: natural := 56; -- TEXT: scale 2 (else 1)
	constant CMD_CENTER: natural := 57; -- TEXT: centered (x ignored)
	constant CMD_STR_LO: natural := 58; -- 63:58 TEXT: string number
	constant CMD_STR_HI: natural := 63;

	subtype cmd_word_type is std_logic_vector(CMD_BITS - 1 downto 0);

	function cmd(op, cond, x, y, w, h, color, mode, scale, center, str: integer) return cmd_word_type is
		variable word: cmd_word_type := (others => '0');
	begin
		word(CMD_OP_HI downto CMD_OP_LO) := std_logic_vector(to_unsigned(op, 3));
		word(CMD_COND_HI downto CMD_COND_LO) := std_logic_vector(to_unsigned(cond, 3));
		word(CMD_X_HI downto CMD_X_LO) := std_logic_vector(to_signed(x, 11));
		word(CMD_Y_HI downto CMD_Y_LO) := std_logic_vector(to_signed(y, 11));
		word(CMD_W_HI downto CMD_W_LO) := std_logic_vector(to_unsigned(w, 9));
		word(CMD_H_HI downto CMD_H_LO) := std_logic_vector(to_unsigned(h, 9));
		word(CMD_COLOR_HI downto CMD_COLOR_LO) := std_logic_vector(to_unsigned(color, 8));
		word(CMD_MODE_HI downto CMD_MODE_LO) := std_logic_vector(to_unsigned(mode, 2));
		if (scale = 2) then
			word(CMD_SCALE2) := '1';
		end if;
		if (center = 1) then
			word(CMD_CENTER) := '1';
		end if;
		word(CMD_STR_HI downto CMD_STR_LO) := std_logic_vector(to_unsigned(str, 6));
		return word;
	end function;

	constant NOP: cmd_word_type := cmd(OP_END, C_ALWAYS, 0, 0, 0, 0, 0, 0, 1, 0, 0);

	constant PROG_TITLE: natural := 0;
	constant PROG_BRIEF: natural := 6;
	constant PROG_SCORE: natural := 14;
	constant PROG_END: natural := 22;
	constant PROG_HUD: natural := 28;
	type prog_type is array (0 to 63) of cmd_word_type;
	-- cmd(op, cond, x, y, w, h, color, mode, scale, center, str)
	constant PROG: prog_type := (
		-- Title page
		0 => cmd(OP_RECT, C_ALWAYS, 0, 0, 320, 240, C_TITLE_BG, CM_FIXED, 1, 0, 0),
		1 => cmd(OP_TEXT, C_ALWAYS, 0, 52, 0, 0, COLOR_YELLOW, SEL_STATIC, 2, 1, 0), -- FIRST-PERSON
		2 => cmd(OP_TEXT, C_ALWAYS, 0, 72, 0, 0, COLOR_YELLOW, SEL_STATIC, 2, 1, 1), -- GATE ARRAY
		3 => cmd(OP_TEXT, C_ALWAYS, 0, 106, 0, 0, COLOR_WHITE, SEL_STATIC, 1, 1, 2),
		4 => cmd(OP_TEXT, C_ALWAYS, 0, 184, 0, 0, COLOR_WHITE, SEL_STATIC, 1, 1, 3),
		5 => NOP,
		-- Briefing page
		6 => cmd(OP_RECT, C_ALWAYS, 0, 0, 320, 240, C_BRIEF_BG, CM_FIXED, 1, 0, 0),
		7 => cmd(OP_TEXT, C_ALWAYS, 0, 30, 0, 0, COLOR_YELLOW, SEL_STATIC, 2, 1, 4),
		8 => cmd(OP_TEXT, C_ALWAYS, 0, 80, 0, 0, COLOR_WHITE, SEL_BRIEF, 1, 1, 0),
		9 => cmd(OP_TEXT, C_ALWAYS, 0, 94, 0, 0, COLOR_WHITE, SEL_BRIEF, 1, 1, 1),
		10 => cmd(OP_TEXT, C_ALWAYS, 0, 108, 0, 0, COLOR_WHITE, SEL_BRIEF, 1, 1, 2),
		11 => cmd(OP_TEXT, C_ALWAYS, 0, 122, 0, 0, COLOR_WHITE, SEL_BRIEF, 1, 1, 3),
		12 => cmd(OP_TEXT, C_ALWAYS, 0, 196, 0, 0, COLOR_LIGHT_GRAY, SEL_STATIC, 1, 1, 3),
		13 => NOP,
		-- Score page
		14 => cmd(OP_RECT, C_ALWAYS, 0, 0, 320, 240, C_SCORE_BG, CM_FIXED, 1, 0, 0),
		15 => cmd(OP_TEXT, C_ALWAYS, 0, 30, 0, 0, COLOR_YELLOW, SEL_STATIC, 2, 1, 5),
		16 => cmd(OP_TEXT, C_ALWAYS, 64, 80, 0, 0, COLOR_WHITE, SEL_STATIC, 1, 0, 6),
		17 => cmd(OP_TEXT, C_ALWAYS, 64, 96, 0, 0, COLOR_WHITE, SEL_STATIC, 1, 0, 7),
		18 => cmd(OP_TEXT, C_ALWAYS, 64, 112, 0, 0, COLOR_WHITE, SEL_STATIC, 1, 0, 8),
		19 => cmd(OP_TEXT, C_ALWAYS, 64, 128, 0, 0, COLOR_WHITE, SEL_STATIC, 1, 0, 9),
		20 => cmd(OP_TEXT, C_ALWAYS, 0, 196, 0, 0, COLOR_LIGHT_GRAY, SEL_STATIC, 1, 1, 3),
		21 => NOP,
		-- Ending page
		22 => cmd(OP_RECT, C_ALWAYS, 0, 0, 320, 240, C_END_BG, CM_FIXED, 1, 0, 0),
		23 => cmd(OP_TEXT, C_ALWAYS, 0, 60, 0, 0, COLOR_YELLOW, SEL_STATIC, 2, 1, 10),
		24 => cmd(OP_TEXT, C_ALWAYS, 0, 100, 0, 0, COLOR_WHITE, SEL_STATIC, 1, 1, 11),
		25 => cmd(OP_TEXT, C_ALWAYS, 0, 114, 0, 0, COLOR_WHITE, SEL_STATIC, 1, 1, 12),
		26 => cmd(OP_TEXT, C_ALWAYS, 0, 196, 0, 0, COLOR_LIGHT_GRAY, SEL_STATIC, 1, 1, 3),
		27 => NOP,
		-- HUD over the 3D view (playing, paused, dead)
		28 => cmd(OP_RECT, C_AUTOMAP, 0, 0, 320, 208, COLOR_BLACK, CM_FIXED, 1, 0, 0),
		29 => cmd(OP_MAP, C_AUTOMAP, 64, 8, 3, 3, 0, 0, 1, 0, 0), -- Automap, 3 x 3 cells
		30 => cmd(OP_BLIT, C_NOAUTO_ALIVE, 96, 88, 0, 0, 0, 0, 1, 0, 0), -- Weapon at y + bob
		-- Crosshair
		31 => cmd(OP_RECT, C_NOAUTO, 160, 118, 1, 1, COLOR_WHITE, CM_FIXED, 1, 0, 0),
		32 => cmd(OP_RECT, C_NOAUTO, 160, 119, 1, 1, COLOR_WHITE, CM_FIXED, 1, 0, 0),
		33 => cmd(OP_RECT, C_NOAUTO, 160, 121, 1, 1, COLOR_WHITE, CM_FIXED, 1, 0, 0),
		34 => cmd(OP_RECT, C_NOAUTO, 160, 122, 1, 1, COLOR_WHITE, CM_FIXED, 1, 0, 0),
		35 => cmd(OP_RECT, C_NOAUTO, 158, 120, 1, 1, COLOR_WHITE, CM_FIXED, 1, 0, 0),
		36 => cmd(OP_RECT, C_NOAUTO, 159, 120, 1, 1, COLOR_WHITE, CM_FIXED, 1, 0, 0),
		37 => cmd(OP_RECT, C_NOAUTO, 161, 120, 1, 1, COLOR_WHITE, CM_FIXED, 1, 0, 0),
		38 => cmd(OP_RECT, C_NOAUTO, 162, 120, 1, 1, COLOR_WHITE, CM_FIXED, 1, 0, 0),
		-- Minimap, 1 x 1 cells
		39 => cmd(OP_RECT, C_NOAUTO, 256, 4, 64, 64, COLOR_BLACK, CM_FIXED, 1, 0, 0),
		40 => cmd(OP_MAP, C_NOAUTO, 256, 4, 1, 1, 0, 0, 1, 0, 0),
		-- Status bar
		41 => cmd(OP_RECT, C_ALWAYS, 0, 208, 320, 32, C_BAR, CM_FIXED, 1, 0, 0),
		42 => cmd(OP_TEXT, C_ALWAYS, 4, 211, 0, 0, COLOR_LIGHT_GRAY, SEL_STATIC, 1, 0, 13),
		43 => cmd(OP_TEXT, C_ALWAYS, 76, 211, 0, 0, COLOR_LIGHT_GRAY, SEL_STATIC, 1, 0, 14),
		44 => cmd(OP_TEXT, C_ALWAYS, 148, 211, 0, 0, COLOR_LIGHT_GRAY, SEL_STATIC, 1, 0, 15),
		45 => cmd(OP_TEXT, C_ALWAYS, 204, 211, 0, 0, COLOR_LIGHT_GRAY, SEL_STATIC, 1, 0, 16),
		46 => cmd(OP_TEXT, C_ALWAYS, 268, 211, 0, 0, COLOR_LIGHT_GRAY, SEL_STATIC, 1, 0, 17),
		47 => cmd(OP_TEXT, C_ALWAYS, 4, 221, 0, 0, COLOR_YELLOW, SEL_STATIC, 2, 0, 18),
		48 => cmd(OP_TEXT, C_ALWAYS, 76, 221, 0, 0, COLOR_YELLOW, SEL_STATIC, 2, 0, 19),
		49 => cmd(OP_TEXT, C_ALWAYS, 148, 221, 0, 0, COLOR_YELLOW, SEL_STATIC, 2, 0, 20),
		50 => cmd(OP_TEXT, C_ALWAYS, 220, 221, 0, 0, COLOR_YELLOW, SEL_STATIC, 2, 0, 21),
		51 => cmd(OP_RECT, C_ALWAYS, 268, 222, 12, 12, 0, CM_KEY1, 1, 0, 0),
		52 => cmd(OP_RECT, C_ALWAYS, 286, 222, 12, 12, 0, CM_KEY2, 1, 0, 0),
		-- Message, PAUSED box, death text, debug counters
		53 => cmd(OP_TEXT, C_MSG, 4, 4, 0, 0, COLOR_YELLOW, SEL_MSG, 1, 0, 0),
		54 => cmd(OP_RECT, C_PAUSED, 100, 96, 120, 24, COLOR_BLACK, CM_FIXED, 1, 0, 0),
		55 => cmd(OP_TEXT, C_PAUSED, 0, 100, 0, 0, COLOR_WHITE, SEL_STATIC, 2, 1, 22),
		56 => cmd(OP_TEXT, C_DEAD, 0, 100, 0, 0, COLOR_WHITE, SEL_STATIC, 1, 1, 23),
		57 => cmd(OP_TEXT, C_DEBUG, 4, 16, 0, 0, COLOR_LIGHT_CYAN, SEL_STATIC, 1, 0, 24),
		58 => cmd(OP_TEXT, C_DEBUG, 4, 26, 0, 0, COLOR_LIGHT_CYAN, SEL_STATIC, 1, 0, 25),
		59 => cmd(OP_TEXT, C_DEBUG, 4, 36, 0, 0, COLOR_LIGHT_CYAN, SEL_STATIC, 1, 0, 26),
		60 => cmd(OP_TEXT, C_DEBUG, 4, 46, 0, 0, COLOR_LIGHT_CYAN, SEL_STATIC, 1, 0, 27),
		others => NOP
	);

	------------------------------------------------------------------
	-- State
	------------------------------------------------------------------
	type overlay_state_type is (
		OVERLAY_IDLE, -- Wait for start_i
		OVERLAY_BCD_GO, -- Convert number field
		OVERLAY_BCD_WAIT,
		OVERLAY_FETCH, -- Read command pc, check its condition, dispatch
		OVERLAY_NEXT, -- Command finished
		OVERLAY_RECT, -- Fill rx, ry, rw x rh, then go to rect_ret
		OVERLAY_TXT_CHAR, -- Character ROM read
		OVERLAY_TXT_REG, -- ROM output register (timing: the BRAM read alone is 2.4 ns)
		OVERLAY_TXT_DEC, -- Character (or digit) known
		OVERLAY_TXT_FONT, -- Font ROM read of (ch, row)
		OVERLAY_TXT_BITS, -- Font row known
		OVERLAY_TXT_EMIT, -- Lit pixels of the row
		OVERLAY_BLIT_REQ, -- Ask the SRAM for one art texel
		OVERLAY_BLIT_WAIT, -- Wait for it
		OVERLAY_BLIT_EMIT, -- Its 2x2 pixels
		OVERLAY_BLIT_ADV, -- Next texel
		OVERLAY_MAP_RD, -- Tile and seen bit read of tile n
		OVERLAY_MAP_CHK, -- Draw the cell if seen
		OVERLAY_MAP_ADV, -- Next tile
		OVERLAY_KEY_SETUP, -- Key slot (blue, then red)
		OVERLAY_KEY_RD,
		OVERLAY_KEY_CHK,
		OVERLAY_KEY_ADV,
		OVERLAY_TRIG_A, -- Read sin(angle)
		OVERLAY_TRIG_B,
		OVERLAY_TRIG_C, -- Read cos(angle) = sin(angle + 256)
		OVERLAY_TRIG_D,
		OVERLAY_TRIG_E, -- Player cell
		OVERLAY_DIR, -- Direction cell
		OVERLAY_FLUSH, -- Wait for the last pixel to leave
		OVERLAY_DONE
	);

	type digits_type is array (0 to 16) of std_logic_vector(31 downto 0);

	signal overlay_state: overlay_state_type := OVERLAY_IDLE;
	signal rect_ret: overlay_state_type := OVERLAY_NEXT; -- Where OVERLAY_RECT returns to
	signal pc: natural range 0 to 63 := 0;
	signal field: natural range 0 to 16 := 0; -- Number field being converted
	signal digits: digits_type := (others => (others => '0'));
	-- Rect
	signal rx, ry: integer range -2048 to 2047 := 0;
	signal rw, rh: natural range 0 to 511 := 0;
	signal rc: natural range 0 to 255 := 0;
	signal i, j: natural range 0 to 511 := 0;
	-- Text
	signal caddr: natural range 0 to 2047 := 0;
	signal len: natural range 0 to 40 := 0;
	signal k: natural range 0 to 40 := 0;
	signal cx: integer range -2048 to 2047 := 0;
	signal ty: integer range -2048 to 2047 := 0;
	signal scale: natural range 1 to 2 := 1;
	signal tc: natural range 0 to 255 := 0;
	signal ch: std_logic_vector(6 downto 0) := (others => '0');
	signal row: natural range 0 to 7 := 0;
	signal bits: std_logic_vector(7 downto 0) := (others => '0'); -- Font row, or the blit texel
	signal b: natural range 0 to 7 := 0;
	signal dx, dy: natural range 0 to 1 := 0;
	-- Blit
	signal addr: unsigned(18 downto 0) := (others => '0');
	signal u, v: natural range 0 to 127 := 0;
	signal fw, fh: natural range 0 to 127 := 0;
	signal bx, by: integer range -2048 to 2047 := 0;
	signal d: natural range 0 to 3 := 0;
	-- Map
	signal n: unsigned(11 downto 0) := (others => '0');
	signal cell: natural range 0 to 3 := 1;
	signal mx0, my0: integer range -2048 to 2047 := 0;
	signal key: natural range 0 to 1 := 0;
	signal taddr: unsigned(9 downto 0) := (others => '0');
	signal sn, cs: integer range -65536 to 65536 := 0;
	signal done: std_logic := '0';

	-- HUD fields
	signal flow: natural range 0 to 7;
	signal level: natural range 0 to 3;
	signal keys: std_logic_vector(1 downto 0);
	signal wframe: natural range 0 to 255;
	signal bob: natural range 0 to 7;
	signal msg: natural range 0 to 15;
	signal automap, debug_on: std_logic;

	-- Current command (PROG(pc)) and what it selects
	signal cmd_word: cmd_word_type;
	signal cmd_op: natural range 0 to 7;
	signal cmd_cond: natural range 0 to 7;
	signal cmd_x, cmd_y: integer range -1024 to 1023;
	signal cmd_w, cmd_h: natural range 0 to 511;
	signal cmd_color: natural range 0 to 255;
	signal cmd_mode: natural range 0 to 3;
	signal cmd_scale: natural range 1 to 2;
	signal cmd_str: natural range 0 to 63;
	signal cond_ok: std_logic; -- The command's condition holds
	signal str_raw: natural range 0 to 127;
	signal str_sel: natural range 0 to STR_COUNT - 1; -- String the TEXT command prints
	signal text_len: natural range 0 to 40;
	signal wf: natural range 0 to 60; -- Weapon frame
	signal tile_color: natural range 0 to 255;
	signal key_tile: unsigned(11 downto 0); -- Tile of key slot key, y * 64 + x
	signal key_on: std_logic; -- Key slot key is on the floor

	-- Character decode: a literal, or a digit (or a leading space) of a number field
	signal dec_f: natural range 0 to 16;
	signal dec_pos: natural range 0 to 7;
	signal dec_dg: std_logic_vector(31 downto 0);
	signal dec_val: unsigned(3 downto 0);
	signal ndig: natural range 1 to 8;
	signal dec_ch: std_logic_vector(6 downto 0);

	-- ROM outputs
	signal char_q: std_logic_vector(8 downto 0) := (others => '0');
	signal char_r: std_logic_vector(8 downto 0) := (others => '0'); -- char_q one clock later
	signal font_bits: std_logic_vector(7 downto 0);
	signal font_row: std_logic_vector(2 downto 0); -- row as 3 bits
	signal sin_q: integer range -65536 to 65536 := 0;
	signal bcd_start, bcd_done: std_logic;
	signal bcd_value: std_logic_vector(23 downto 0);
	signal bcd_digits: std_logic_vector(31 downto 0);

	-- Pixel output stage
	signal emit_req: std_logic;
	signal emit_ack: std_logic;
	signal ex, ey: integer range -4096 to 4095;
	signal ecolor: natural range 0 to 255;
	signal can_load: std_logic;
	signal pix_valid: std_logic := '0';
	signal pix_data: std_logic_vector(PIXW_BITS - 1 downto 0) := (others => '0');
begin
	flow <= to_integer(unsigned(hud_i(HUD_FLOW_HI downto HUD_FLOW_LO)));
	level <= to_integer(unsigned(hud_i(HUD_LEVEL_HI downto HUD_LEVEL_LO)));
	keys <= hud_i(HUD_KEYS_HI downto HUD_KEYS_LO);
	wframe <= to_integer(unsigned(hud_i(HUD_WFRAME_HI downto HUD_WFRAME_LO)));
	bob <= to_integer(unsigned(hud_i(HUD_BOB_HI downto HUD_BOB_LO)));
	msg <= to_integer(unsigned(hud_i(HUD_MSG_HI downto HUD_MSG_LO)));
	automap <= hud_i(HUD_AUTOMAP);
	debug_on <= hud_i(HUD_DEBUG);

	------------------------------------------------------------------
	-- Current command
	------------------------------------------------------------------
	cmd_word <= PROG(pc);
	cmd_op <= to_integer(unsigned(cmd_word(CMD_OP_HI downto CMD_OP_LO)));
	cmd_cond <= to_integer(unsigned(cmd_word(CMD_COND_HI downto CMD_COND_LO)));
	cmd_x <= to_integer(signed(cmd_word(CMD_X_HI downto CMD_X_LO)));
	cmd_y <= to_integer(signed(cmd_word(CMD_Y_HI downto CMD_Y_LO)));
	cmd_w <= to_integer(unsigned(cmd_word(CMD_W_HI downto CMD_W_LO)));
	cmd_h <= to_integer(unsigned(cmd_word(CMD_H_HI downto CMD_H_LO)));
	cmd_color <= to_integer(unsigned(cmd_word(CMD_COLOR_HI downto CMD_COLOR_LO)));
	cmd_mode <= to_integer(unsigned(cmd_word(CMD_MODE_HI downto CMD_MODE_LO)));
	cmd_scale <= 2 when (cmd_word(CMD_SCALE2) = '1') else 1;
	cmd_str <= to_integer(unsigned(cmd_word(CMD_STR_HI downto CMD_STR_LO)));

	-- A command is skipped when its condition on the HUD word fails
	cond_ok <= '0' when (((cmd_cond = C_AUTOMAP) and (automap = '0')) or
		((cmd_cond = C_NOAUTO) and (automap = '1')) or
		((cmd_cond = C_NOAUTO_ALIVE) and ((automap = '1') or (flow = 4))) or
		((cmd_cond = C_MSG) and (msg = 0)) or
		((cmd_cond = C_PAUSED) and (flow /= 3)) or
		((cmd_cond = C_DEAD) and (flow /= 4)) or
		((cmd_cond = C_DEBUG) and (debug_on = '0'))) else '1';

	-- String of a TEXT command; numbers past the ROM read string 0
	str_raw <= MSG_BASE + msg - 1 when (cmd_mode = SEL_MSG) else
		BRIEF_BASE + 4 * (level - 1) + cmd_str when (cmd_mode = SEL_BRIEF) else
		cmd_str;
	str_sel <= 0 when (str_raw > STR_COUNT - 1) else str_raw;
	text_len <= LENS(str_sel);

	-- Guard: a weapon frame number past the table (60) reads frame 55
	wf <= wframe when (wframe <= 60) else 55;

	-- Map cell color of the tile word: special 16:14 (1..3 doors, 4 exit), texture 3:0 (0 open)
	tile_color <= MAP_OPEN when (unsigned(map_data_i(3 downto 0)) = 0) else
		MAP_DOOR when ((unsigned(map_data_i(16 downto 14)) >= 1) and (unsigned(map_data_i(16 downto 14)) <= 3)) else
		MAP_EXIT when (unsigned(map_data_i(16 downto 14)) = 4) else
		MAP_WALL;

	-- Key slot, from its base bit: + 0 on the floor, + 6..1 x, + 12..7 y
	key_tile <= unsigned(keypos_i(KEYPOS_BLUE + 12 downto KEYPOS_BLUE + 7)) &
		unsigned(keypos_i(KEYPOS_BLUE + 6 downto KEYPOS_BLUE + 1)) when (key = 0) else
		unsigned(keypos_i(KEYPOS_RED + 12 downto KEYPOS_RED + 7)) &
		unsigned(keypos_i(KEYPOS_RED + 6 downto KEYPOS_RED + 1));
	key_on <= keypos_i(KEYPOS_BLUE) when (key = 0) else keypos_i(KEYPOS_RED);

	------------------------------------------------------------------
	-- Character decode, like num(v, width) in the model. The ROM entry
	-- (char_r) is a literal, or digit dec_pos (0 = ones) of number field
	-- dec_f, printed as a space when it is a leading zero
	------------------------------------------------------------------
	dec_f <= 16 when (unsigned(char_r(4 downto 0)) > 16) else to_integer(unsigned(char_r(4 downto 0)));
	dec_pos <= to_integer(unsigned(char_r(7 downto 5)));
	dec_dg <= digits(dec_f);
	dec_val <= unsigned(dec_dg(4 * dec_pos + 3 downto 4 * dec_pos));
	-- Significant digits: one past the highest nonzero digit (at least 1)
	ndig <= 8 when (dec_dg(31 downto 28) /= "0000") else
		7 when (dec_dg(27 downto 24) /= "0000") else
		6 when (dec_dg(23 downto 20) /= "0000") else
		5 when (dec_dg(19 downto 16) /= "0000") else
		4 when (dec_dg(15 downto 12) /= "0000") else
		3 when (dec_dg(11 downto 8) /= "0000") else
		2 when (dec_dg(7 downto 4) /= "0000") else
		1;
	-- Seconds (field 12) are zero padded; other fields blank their leading zeros
	dec_ch <= char_r(6 downto 0) when (char_r(8) = '0') else
		std_logic_vector(resize(dec_val, 7) + 16#30#) when ((dec_f = 12) or (dec_pos = 0) or (dec_pos < ndig)) else
		"0100000"; -- 16#30# = ASCII '0'; "0100000" = space

	------------------------------------------------------------------
	-- ROMs and helpers
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			char_q <= CHAR_ROM(caddr);
			-- Second register: packs into the block RAM's output register,
			-- so the character decode starts from a fast flip-flop (full-design timing)
			char_r <= char_q;
			sin_q <= SIN_TABLE(to_integer(taddr));
		end if;
	end process;

	font_row <= std_logic_vector(to_unsigned(row, 3));

	fonts: font_rom
		port map (
			clk_i => clk_i,
			char_i => ch,
			row_i => font_row,
			bits_o => font_bits
		);

	-- Value of number field f (placeholder letter 'a' + f)
	with field select bcd_value <=
		std_logic_vector(resize(unsigned(hud_i(HUD_HEALTH_HI downto HUD_HEALTH_LO)), 24)) when 0,
		std_logic_vector(resize(unsigned(hud_i(HUD_ARMOR_HI downto HUD_ARMOR_LO)), 24)) when 1,
		std_logic_vector(resize(unsigned(hud_i(HUD_AMMO_HI downto HUD_AMMO_LO)), 24)) when 2,
		std_logic_vector(resize(unsigned(hud_i(HUD_WEAPON_HI downto HUD_WEAPON_LO)), 24)) when 3,
		std_logic_vector(resize(unsigned(hud_i(HUD_LEVEL_HI downto HUD_LEVEL_LO)), 24)) when 4,
		std_logic_vector(resize(unsigned(hud_i(HUD_KILLS_HI downto HUD_KILLS_LO)), 24)) when 5,
		std_logic_vector(resize(unsigned(hud_i(HUD_TKILLS_HI downto HUD_TKILLS_LO)), 24)) when 6,
		std_logic_vector(resize(unsigned(hud_i(HUD_ITEMS_HI downto HUD_ITEMS_LO)), 24)) when 7,
		std_logic_vector(resize(unsigned(hud_i(HUD_TITEMS_HI downto HUD_TITEMS_LO)), 24)) when 8,
		std_logic_vector(resize(unsigned(hud_i(HUD_SECRETS_HI downto HUD_SECRETS_LO)), 24)) when 9,
		std_logic_vector(resize(unsigned(hud_i(HUD_TSECRETS_HI downto HUD_TSECRETS_LO)), 24)) when 10,
		std_logic_vector(resize(unsigned(hud_i(HUD_TMIN_HI downto HUD_TMIN_LO)), 24)) when 11,
		std_logic_vector(resize(unsigned(hud_i(HUD_TSEC_HI downto HUD_TSEC_LO)), 24)) when 12,
		debug_i(23 downto 0) when 13,
		debug_i(47 downto 24) when 14,
		debug_i(71 downto 48) when 15,
		debug_i(95 downto 72) when others;
	bcd_start <= '1' when (overlay_state = OVERLAY_BCD_GO) else '0';

	bcd: overlay_bcd
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			start_i => bcd_start,
			value_i => bcd_value,
			done_o => bcd_done,
			digits_o => bcd_digits
		);

	------------------------------------------------------------------
	-- Pixel being offered this cycle
	------------------------------------------------------------------
	process(overlay_state, rx, ry, i, j, rc, bits, b, cx, scale, dx, ty, row, dy, tc, bx, by, u, v, d)
	begin
		emit_req <= '0';
		ex <= 0;
		ey <= 0;
		ecolor <= 0;
		case overlay_state is
			when OVERLAY_RECT =>
				emit_req <= '1';
				ex <= rx + i;
				ey <= ry + j;
				ecolor <= rc;
			when OVERLAY_TXT_EMIT =>
				-- Font rows are MSB first: bit 7 is the leftmost pixel
				if (bits(7 - b) = '1') then
					emit_req <= '1';
				end if;
				ex <= cx + b * scale + dx;
				ey <= ty + row * scale + dy;
				ecolor <= tc;
			when OVERLAY_BLIT_EMIT =>
				emit_req <= '1';
				-- d = 0..3 walks the 2x2 block: bit 0 is the x offset, bit 1 the y offset
				ex <= bx + 2 * u + (d mod 2);
				ey <= by + 2 * v + (d / 2);
				ecolor <= to_integer(unsigned(bits));
			when others =>
				null;
		end case;
	end process;

	-- The output register takes a new pixel when it is empty or its pixel is being taken
	can_load <= (not pix_valid) or pix_ready_i;
	emit_ack <= emit_req and can_load;

	-- Output register: pixels outside the screen are accepted and dropped.
	-- Address y * 320 + x as (y << 8) + (y << 6) + x: carry chains instead
	-- of a DSP multiply, whose input setup broke 100 MHz in the full design
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			pix_valid <= '0';
			pix_data <= (others => '0');
		elsif rising_edge(clk_i) then
			if (can_load = '1') then
				if ((emit_req = '1') and (ex >= 0) and (ex < 320) and (ey >= 0) and (ey < 240)) then
					pix_valid <= '1';
					pix_data <= buf_i & std_logic_vector(shift_left(to_unsigned(ey, 17), 8) +
						shift_left(to_unsigned(ey, 17), 6) + to_unsigned(ex, 17)) &
						std_logic_vector(to_unsigned(ecolor, 8));
				else
					pix_valid <= '0';
				end if;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- State machine
	------------------------------------------------------------------
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			overlay_state <= OVERLAY_IDLE;
			rect_ret <= OVERLAY_NEXT;
			pc <= 0;
			field <= 0;
			digits <= (others => (others => '0'));
			rx <= 0;
			ry <= 0;
			rw <= 0;
			rh <= 0;
			rc <= 0;
			i <= 0;
			j <= 0;
			caddr <= 0;
			len <= 0;
			k <= 0;
			cx <= 0;
			ty <= 0;
			scale <= 1;
			tc <= 0;
			ch <= (others => '0');
			row <= 0;
			bits <= (others => '0');
			b <= 0;
			dx <= 0;
			dy <= 0;
			addr <= (others => '0');
			u <= 0;
			v <= 0;
			fw <= 0;
			fh <= 0;
			bx <= 0;
			by <= 0;
			d <= 0;
			n <= (others => '0');
			cell <= 1;
			mx0 <= 0;
			my0 <= 0;
			key <= 0;
			taddr <= (others => '0');
			sn <= 0;
			cs <= 0;
			done <= '0';
		elsif rising_edge(clk_i) then
			done <= '0';
			case overlay_state is
				when OVERLAY_IDLE =>
					if (start_i = '1') then
						field <= 0;
						overlay_state <= OVERLAY_BCD_GO;
					end if;

				when OVERLAY_BCD_GO =>
					overlay_state <= OVERLAY_BCD_WAIT;

				when OVERLAY_BCD_WAIT =>
					if (bcd_done = '1') then
						digits(field) <= bcd_digits;
						if (field = 16) then
							-- All 17 fields converted: pick the screen's program
							case flow is
								when 0 =>
									pc <= PROG_TITLE;
								when 1 =>
									pc <= PROG_BRIEF;
								when 5 =>
									pc <= PROG_SCORE;
								when 6 =>
									pc <= PROG_END;
								when others =>
									pc <= PROG_HUD;
							end case;
							overlay_state <= OVERLAY_FETCH;
						else
							field <= field + 1;
							overlay_state <= OVERLAY_BCD_GO;
						end if;
					end if;

				when OVERLAY_FETCH =>
					if (cmd_op = OP_END) then
						overlay_state <= OVERLAY_FLUSH;
					elsif (cond_ok = '0') then
						pc <= pc + 1;
					else
						case cmd_op is
							when OP_RECT =>
								rx <= cmd_x;
								ry <= cmd_y;
								rw <= cmd_w;
								rh <= cmd_h;
								i <= 0;
								j <= 0;
								rect_ret <= OVERLAY_NEXT;
								if (cmd_mode = CM_KEY1) then
									if (keys(0) = '1') then
										rc <= C_BLUE_KEY;
									else
										rc <= COLOR_DARK_GRAY;
									end if;
								elsif (cmd_mode = CM_KEY2) then
									if (keys(1) = '1') then
										rc <= C_RED_KEY;
									else
										rc <= COLOR_DARK_GRAY;
									end if;
								else
									rc <= cmd_color;
								end if;
								overlay_state <= OVERLAY_RECT;
							when OP_TEXT =>
								len <= text_len;
								caddr <= str_sel * STR_LEN;
								k <= 0;
								scale <= cmd_scale;
								tc <= cmd_color;
								ty <= cmd_y;
								if (cmd_word(CMD_CENTER) = '1') then
									-- (320 - len * 8 * scale) // 2, the model's text_center: an
									-- arithmetic shift rounds down like Python's //, and is
									-- cheaper than "/ 2" (which rounds toward zero)
									cx <= to_integer(shift_right(to_signed(320 - text_len * 8 * cmd_scale, 12), 1));
								else
									cx <= cmd_x;
								end if;
								overlay_state <= OVERLAY_TXT_CHAR;
							when OP_BLIT =>
								addr <= to_unsigned(ART_BASE + FRAME_TABLE(wf)(0), 19);
								fw <= FRAME_TABLE(wf)(1);
								fh <= FRAME_TABLE(wf)(2);
								u <= 0;
								v <= 0;
								bx <= cmd_x;
								by <= cmd_y + bob;
								overlay_state <= OVERLAY_BLIT_REQ;
							when OP_MAP =>
								cell <= cmd_w;
								mx0 <= cmd_x;
								my0 <= cmd_y;
								n <= (others => '0');
								overlay_state <= OVERLAY_MAP_RD;
							when others =>
								overlay_state <= OVERLAY_FLUSH;
						end case;
					end if;

				when OVERLAY_NEXT =>
					pc <= pc + 1;
					overlay_state <= OVERLAY_FETCH;

				when OVERLAY_RECT =>
					-- Row by row: i steps across, j down
					if (emit_ack = '1') then
						if (i = rw - 1) then
							i <= 0;
							if (j = rh - 1) then
								j <= 0;
								overlay_state <= rect_ret;
							else
								j <= j + 1;
							end if;
						else
							i <= i + 1;
						end if;
					end if;

				-- Text: one character at a time, one font row at a time
				when OVERLAY_TXT_CHAR =>
					overlay_state <= OVERLAY_TXT_REG;

				when OVERLAY_TXT_REG =>
					overlay_state <= OVERLAY_TXT_DEC;

				when OVERLAY_TXT_DEC =>
					ch <= dec_ch;
					row <= 0;
					if (dec_ch = "0100000") then
						-- A space has no lit pixels: go straight to the last bit
						row <= 7;
						b <= 7;
						bits <= (others => '0');
						overlay_state <= OVERLAY_TXT_EMIT;
					else
						overlay_state <= OVERLAY_TXT_FONT;
					end if;

				when OVERLAY_TXT_FONT =>
					overlay_state <= OVERLAY_TXT_BITS;

				when OVERLAY_TXT_BITS =>
					bits <= font_bits;
					b <= 0;
					dx <= 0;
					dy <= 0;
					overlay_state <= OVERLAY_TXT_EMIT;

				when OVERLAY_TXT_EMIT =>
					if ((bits(7 - b) = '0') or (emit_ack = '1')) then
						-- Next scale step, next bit, next row, next character
						if ((bits(7 - b) = '1') and (dx /= scale - 1)) then
							dx <= dx + 1;
						elsif ((bits(7 - b) = '1') and (dy /= scale - 1)) then
							dx <= 0;
							dy <= dy + 1;
						else
							dx <= 0;
							dy <= 0;
							if (b /= 7) then
								b <= b + 1;
							elsif (row /= 7) then
								row <= row + 1;
								overlay_state <= OVERLAY_TXT_FONT;
							elsif (k = len - 1) then
								overlay_state <= OVERLAY_NEXT;
							else
								k <= k + 1;
								caddr <= caddr + 1;
								cx <= cx + 8 * scale;
								overlay_state <= OVERLAY_TXT_CHAR;
							end if;
						end if;
					end if;

				-- Weapon blit: texel by texel, column-major, 2x2 pixels each
				when OVERLAY_BLIT_REQ =>
					if (m_gnt_i = '1') then
						overlay_state <= OVERLAY_BLIT_WAIT;
					end if;

				when OVERLAY_BLIT_WAIT =>
					if (m_rvalid_i = '1') then
						bits <= m_rdata_i;
						d <= 0;
						if (m_rdata_i = x"FF") then -- Texel 255 is transparent
							overlay_state <= OVERLAY_BLIT_ADV;
						else
							overlay_state <= OVERLAY_BLIT_EMIT;
						end if;
					end if;

				when OVERLAY_BLIT_EMIT =>
					if (emit_ack = '1') then
						if (d = 3) then
							overlay_state <= OVERLAY_BLIT_ADV;
						else
							d <= d + 1;
						end if;
					end if;

				when OVERLAY_BLIT_ADV =>
					addr <= addr + 1;
					overlay_state <= OVERLAY_BLIT_REQ;
					if (v = fh - 1) then
						v <= 0;
						if (u = fw - 1) then
							overlay_state <= OVERLAY_NEXT;
						else
							u <= u + 1;
						end if;
					else
						v <= v + 1;
					end if;

				-- Map: tiles 0..4095, then keys, player, direction
				when OVERLAY_MAP_RD =>
					overlay_state <= OVERLAY_MAP_CHK;

				when OVERLAY_MAP_CHK =>
					if (seen_data_i = '1') then
						rc <= tile_color;
						rx <= mx0 + to_integer(n(5 downto 0)) * cell;
						ry <= my0 + to_integer(n(11 downto 6)) * cell;
						rw <= cell;
						rh <= cell;
						i <= 0;
						j <= 0;
						rect_ret <= OVERLAY_MAP_ADV;
						overlay_state <= OVERLAY_RECT;
					elsif (n = 4095) then
						key <= 0;
						overlay_state <= OVERLAY_KEY_SETUP;
					else
						-- Unseen tile: straight to the next read (2 clocks per tile)
						n <= n + 1;
						overlay_state <= OVERLAY_MAP_RD;
					end if;

				when OVERLAY_MAP_ADV =>
					if (n = 4095) then
						key <= 0;
						overlay_state <= OVERLAY_KEY_SETUP;
					else
						n <= n + 1;
						overlay_state <= OVERLAY_MAP_RD;
					end if;

				when OVERLAY_KEY_SETUP =>
					n <= key_tile;
					if (key_on = '1') then
						overlay_state <= OVERLAY_KEY_RD;
					else
						overlay_state <= OVERLAY_KEY_ADV;
					end if;

				when OVERLAY_KEY_RD =>
					overlay_state <= OVERLAY_KEY_CHK;

				when OVERLAY_KEY_CHK =>
					if (seen_data_i = '1') then
						if (key = 0) then
							rc <= C_BLUE_KEY;
						else
							rc <= C_RED_KEY;
						end if;
						rx <= mx0 + to_integer(n(5 downto 0)) * cell;
						ry <= my0 + to_integer(n(11 downto 6)) * cell;
						rw <= cell;
						rh <= cell;
						i <= 0;
						j <= 0;
						rect_ret <= OVERLAY_KEY_ADV;
						overlay_state <= OVERLAY_RECT;
					else
						overlay_state <= OVERLAY_KEY_ADV;
					end if;

				when OVERLAY_KEY_ADV =>
					if (key = 0) then
						key <= 1;
						overlay_state <= OVERLAY_KEY_SETUP;
					else
						overlay_state <= OVERLAY_TRIG_A;
					end if;

				when OVERLAY_TRIG_A =>
					taddr <= unsigned(angle_i);
					overlay_state <= OVERLAY_TRIG_B;

				when OVERLAY_TRIG_B =>
					overlay_state <= OVERLAY_TRIG_C;

				when OVERLAY_TRIG_C =>
					sn <= sin_q;
					taddr <= unsigned(angle_i) + 256;
					overlay_state <= OVERLAY_TRIG_D;

				when OVERLAY_TRIG_D =>
					overlay_state <= OVERLAY_TRIG_E;

				when OVERLAY_TRIG_E =>
					-- Player cell
					cs <= sin_q;
					rc <= MAP_PLAYER;
					rx <= mx0 + to_integer(unsigned(player_x_i(21 downto 16))) * cell;
					ry <= my0 + to_integer(unsigned(player_y_i(21 downto 16))) * cell;
					rw <= cell;
					rh <= cell;
					i <= 0;
					j <= 0;
					rect_ret <= OVERLAY_DIR;
					overlay_state <= OVERLAY_RECT;

				when OVERLAY_DIR =>
					-- Direction cell: (p + 2 * cos) >> 16, (p + 2 * sin) >> 16
					-- (floor division; can be -1 or 64 near the map border)
					rx <= mx0 + to_integer(shift_right(to_signed(to_integer(unsigned(player_x_i)) + 2 * cs, 24), 16)) * cell;
					ry <= my0 + to_integer(shift_right(to_signed(to_integer(unsigned(player_y_i)) + 2 * sn, 24), 16)) * cell;
					rc <= MAP_DIR;
					rw <= cell;
					rh <= cell;
					i <= 0;
					j <= 0;
					rect_ret <= OVERLAY_NEXT;
					overlay_state <= OVERLAY_RECT;

				when OVERLAY_FLUSH =>
					if (pix_valid = '0') then
						overlay_state <= OVERLAY_DONE;
					end if;

				when OVERLAY_DONE =>
					done <= '1';
					overlay_state <= OVERLAY_IDLE;

				when others =>
					null;
			end case;
		end if;
	end process;

	map_addr_o <= std_logic_vector(n);
	seen_addr_o <= std_logic_vector(n);
	m_req_o <= '1' when (overlay_state = OVERLAY_BLIT_REQ) else '0';
	m_addr_o <= std_logic_vector(addr);
	pix_valid_o <= pix_valid;
	pix_data_o <= pix_data;
	busy_o <= '0' when (overlay_state = OVERLAY_IDLE) else '1';
	done_o <= done;
end arch;

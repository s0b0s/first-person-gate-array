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
-- Revision 1.02 - Stage 2/3; character ROM output registered, pixel address
--                 by shift-add (full-design timing)
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
	type op_t is (OP_RECT, OP_TEXT, OP_BLIT, OP_MAP, OP_END);
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

	type cmd_t is record
		op: op_t;
		cond: natural range 0 to 7;
		x: integer range -1024 to 1023;
		y: integer range -1024 to 1023;
		w: natural range 0 to 511; -- Rect width; map cell size
		h: natural range 0 to 511;
		color: natural range 0 to 255;
		cmode: natural range 0 to 2;
		scale: natural range 1 to 2;
		center: boolean;
		str: natural range 0 to 63;
		sel: natural range 0 to 2;
		bob: boolean; -- y + weapon bob
	end record;

	constant NOP: cmd_t := (OP_END, 0, 0, 0, 0, 0, 0, 0, 1, false, 0, 0, false);

	function rect(x, y, w, h, c: integer; cond: natural := C_ALWAYS) return cmd_t is
	begin
		return (OP_RECT, cond, x, y, w, h, c, CM_FIXED, 1, false, 0, SEL_STATIC, false);
	end function;

	function keyrect(x, y: integer; cm: natural) return cmd_t is
	begin
		return (OP_RECT, C_ALWAYS, x, y, 12, 12, 0, cm, 1, false, 0, SEL_STATIC, false);
	end function;

	function text(x, y, scale, c, str: integer; cond: natural := C_ALWAYS;
		sel: natural := SEL_STATIC) return cmd_t is
	begin
		return (OP_TEXT, cond, x, y, 0, 0, c, CM_FIXED, scale, false, str, sel, false);
	end function;

	function ctext(y, scale, c, str: integer; cond: natural := C_ALWAYS;
		sel: natural := SEL_STATIC) return cmd_t is
	begin
		return (OP_TEXT, cond, 0, y, 0, 0, c, CM_FIXED, scale, true, str, sel, false);
	end function;

	function mapcmd(x, y, cell: integer; cond: natural) return cmd_t is
	begin
		return (OP_MAP, cond, x, y, cell, cell, 0, CM_FIXED, 1, false, 0, SEL_STATIC, false);
	end function;

	constant PROG_TITLE: natural := 0;
	constant PROG_BRIEF: natural := 6;
	constant PROG_SCORE: natural := 14;
	constant PROG_END: natural := 22;
	constant PROG_HUD: natural := 28;
	type prog_t is array (0 to 63) of cmd_t;
	constant PROG: prog_t := (
		-- Title page
		0 => rect(0, 0, 320, 240, C_TITLE_BG),
		1 => ctext(52, 2, COLOR_YELLOW, 0), -- FIRST-PERSON
		2 => ctext(72, 2, COLOR_YELLOW, 1), -- GATE ARRAY
		3 => ctext(106, 1, COLOR_WHITE, 2),
		4 => ctext(184, 1, COLOR_WHITE, 3),
		5 => NOP,
		-- Briefing page
		6 => rect(0, 0, 320, 240, C_BRIEF_BG),
		7 => ctext(30, 2, COLOR_YELLOW, 4),
		8 => ctext(80, 1, COLOR_WHITE, 0, C_ALWAYS, SEL_BRIEF),
		9 => ctext(94, 1, COLOR_WHITE, 1, C_ALWAYS, SEL_BRIEF),
		10 => ctext(108, 1, COLOR_WHITE, 2, C_ALWAYS, SEL_BRIEF),
		11 => ctext(122, 1, COLOR_WHITE, 3, C_ALWAYS, SEL_BRIEF),
		12 => ctext(196, 1, COLOR_LIGHT_GRAY, 3),
		13 => NOP,
		-- Score page
		14 => rect(0, 0, 320, 240, C_SCORE_BG),
		15 => ctext(30, 2, COLOR_YELLOW, 5),
		16 => text(64, 80, 1, COLOR_WHITE, 6),
		17 => text(64, 96, 1, COLOR_WHITE, 7),
		18 => text(64, 112, 1, COLOR_WHITE, 8),
		19 => text(64, 128, 1, COLOR_WHITE, 9),
		20 => ctext(196, 1, COLOR_LIGHT_GRAY, 3),
		21 => NOP,
		-- Ending page
		22 => rect(0, 0, 320, 240, C_END_BG),
		23 => ctext(60, 2, COLOR_YELLOW, 10),
		24 => ctext(100, 1, COLOR_WHITE, 11),
		25 => ctext(114, 1, COLOR_WHITE, 12),
		26 => ctext(196, 1, COLOR_LIGHT_GRAY, 3),
		27 => NOP,
		-- HUD over the 3D view (playing, paused, dead)
		28 => rect(0, 0, 320, 208, COLOR_BLACK, C_AUTOMAP),
		29 => mapcmd(64, 8, 3, C_AUTOMAP),
		30 => (OP_BLIT, C_NOAUTO_ALIVE, 96, 88, 0, 0, 0, CM_FIXED, 1, false, 0, SEL_STATIC, true),
		31 => rect(160, 118, 1, 1, COLOR_WHITE, C_NOAUTO),
		32 => rect(160, 119, 1, 1, COLOR_WHITE, C_NOAUTO),
		33 => rect(160, 121, 1, 1, COLOR_WHITE, C_NOAUTO),
		34 => rect(160, 122, 1, 1, COLOR_WHITE, C_NOAUTO),
		35 => rect(158, 120, 1, 1, COLOR_WHITE, C_NOAUTO),
		36 => rect(159, 120, 1, 1, COLOR_WHITE, C_NOAUTO),
		37 => rect(161, 120, 1, 1, COLOR_WHITE, C_NOAUTO),
		38 => rect(162, 120, 1, 1, COLOR_WHITE, C_NOAUTO),
		39 => rect(256, 4, 64, 64, COLOR_BLACK, C_NOAUTO),
		40 => mapcmd(256, 4, 1, C_NOAUTO),
		41 => rect(0, 208, 320, 32, C_BAR),
		42 => text(4, 211, 1, COLOR_LIGHT_GRAY, 13),
		43 => text(76, 211, 1, COLOR_LIGHT_GRAY, 14),
		44 => text(148, 211, 1, COLOR_LIGHT_GRAY, 15),
		45 => text(204, 211, 1, COLOR_LIGHT_GRAY, 16),
		46 => text(268, 211, 1, COLOR_LIGHT_GRAY, 17),
		47 => text(4, 221, 2, COLOR_YELLOW, 18),
		48 => text(76, 221, 2, COLOR_YELLOW, 19),
		49 => text(148, 221, 2, COLOR_YELLOW, 20),
		50 => text(220, 221, 2, COLOR_YELLOW, 21),
		51 => keyrect(268, 222, CM_KEY1),
		52 => keyrect(286, 222, CM_KEY2),
		53 => text(4, 4, 1, COLOR_YELLOW, 0, C_MSG, SEL_MSG),
		54 => rect(100, 96, 120, 24, COLOR_BLACK, C_PAUSED),
		55 => ctext(100, 2, COLOR_WHITE, 22, C_PAUSED),
		56 => ctext(100, 1, COLOR_WHITE, 23, C_DEAD),
		57 => text(4, 16, 1, COLOR_LIGHT_CYAN, 24, C_DEBUG),
		58 => text(4, 26, 1, COLOR_LIGHT_CYAN, 25, C_DEBUG),
		59 => text(4, 36, 1, COLOR_LIGHT_CYAN, 26, C_DEBUG),
		60 => text(4, 46, 1, COLOR_LIGHT_CYAN, 27, C_DEBUG),
		others => NOP
	);

	------------------------------------------------------------------
	-- State
	------------------------------------------------------------------
	type state_t is (
		S_IDLE, -- Wait for start_i
		S_BCD_GO, -- Convert number field f
		S_BCD_WAIT,
		S_FETCH, -- Read command pc, check its condition, dispatch
		S_NEXT, -- Command finished
		S_RECT, -- Fill rx, ry, rw x rh, then go to ret
		S_TXT_CHAR, -- Character ROM read
		S_TXT_REG, -- ROM output register (timing: the BRAM read alone is 2.4 ns)
		S_TXT_DEC, -- Character (or digit) known
		S_TXT_FONT, -- Font ROM read of (ch, row)
		S_TXT_BITS, -- Font row known
		S_TXT_EMIT, -- Lit pixels of the row
		S_BLIT_REQ, -- Ask the SRAM for one art texel
		S_BLIT_WAIT, -- Wait for it
		S_BLIT_EMIT, -- Its 2x2 pixels
		S_BLIT_ADV, -- Next texel
		S_MAP_RD, -- Tile and seen bit read of tile n
		S_MAP_CHK, -- Draw the cell if seen
		S_MAP_ADV, -- Next tile
		S_KEY_SETUP, -- Key slot (blue, then red)
		S_KEY_RD,
		S_KEY_CHK,
		S_KEY_ADV,
		S_TRIG_A, -- Read sin(angle)
		S_TRIG_B,
		S_TRIG_C, -- Read cos(angle) = sin(angle + 256)
		S_TRIG_D,
		S_TRIG_E, -- Player cell
		S_DIR, -- Direction cell
		S_FLUSH, -- Wait for the last pixel to leave
		S_DONE
	);

	type digits_t is array (0 to 16) of std_logic_vector(31 downto 0);

	type regs_t is record
		state: state_t;
		ret: state_t; -- Where S_RECT returns to
		pc: natural range 0 to 63;
		f: natural range 0 to 16; -- Number field being converted
		digits: digits_t;
		-- Rect
		rx, ry: integer range -2048 to 2047;
		rw, rh: natural range 0 to 511;
		rc: natural range 0 to 255;
		i, j: natural range 0 to 511;
		-- Text
		caddr: natural range 0 to 2047;
		len: natural range 0 to 40;
		k: natural range 0 to 40;
		cx: integer range -2048 to 2047;
		ty: integer range -2048 to 2047;
		scale: natural range 1 to 2;
		tc: natural range 0 to 255;
		ch: std_logic_vector(6 downto 0);
		row: natural range 0 to 7;
		bits: std_logic_vector(7 downto 0);
		b: natural range 0 to 7;
		dx, dy: natural range 0 to 1;
		-- Blit
		addr: unsigned(18 downto 0);
		u, v: natural range 0 to 127;
		fw, fh: natural range 0 to 127;
		bx, by: integer range -2048 to 2047;
		d: natural range 0 to 3;
		-- Map
		n: unsigned(11 downto 0);
		cell: natural range 0 to 3;
		mx0, my0: integer range -2048 to 2047;
		key: natural range 0 to 1;
		taddr: unsigned(9 downto 0);
		sn, cs: integer range -65536 to 65536;
		done: std_logic;
	end record;

	constant REGS_INIT: regs_t := (
		state => S_IDLE, ret => S_NEXT, pc => 0, f => 0, digits => (others => (others => '0')),
		rx => 0, ry => 0, rw => 0, rh => 0, rc => 0, i => 0, j => 0,
		caddr => 0, len => 0, k => 0, cx => 0, ty => 0, scale => 1, tc => 0,
		ch => (others => '0'), row => 0, bits => (others => '0'), b => 0, dx => 0, dy => 0,
		addr => (others => '0'), u => 0, v => 0, fw => 0, fh => 0, bx => 0, by => 0, d => 0,
		n => (others => '0'), cell => 1, mx0 => 0, my0 => 0, key => 0,
		taddr => (others => '0'), sn => 0, cs => 0, done => '0'
	);

	signal r: regs_t := REGS_INIT;
	signal r_next: regs_t;

	-- HUD fields
	signal flow: natural range 0 to 7;
	signal level: natural range 0 to 3;
	signal keys: std_logic_vector(1 downto 0);
	signal wframe: natural range 0 to 255;
	signal bob: natural range 0 to 7;
	signal msg: natural range 0 to 15;
	signal automap, debug_on: std_logic;

	-- ROM outputs
	signal char_q: std_logic_vector(8 downto 0) := (others => '0');
	signal char_r: std_logic_vector(8 downto 0) := (others => '0'); -- char_q one clock later
	signal font_bits: std_logic_vector(7 downto 0);
	signal font_row: std_logic_vector(2 downto 0); -- r.row as 3 bits
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

	-- Value of number field f (placeholder letter 'a' + f)
	function field_value(f: natural; hud: std_logic_vector; dbg: std_logic_vector)
		return std_logic_vector is
		variable v: unsigned(23 downto 0) := (others => '0');
	begin
		case f is
			when 0 => v := resize(unsigned(hud(HUD_HEALTH_HI downto HUD_HEALTH_LO)), 24);
			when 1 => v := resize(unsigned(hud(HUD_ARMOR_HI downto HUD_ARMOR_LO)), 24);
			when 2 => v := resize(unsigned(hud(HUD_AMMO_HI downto HUD_AMMO_LO)), 24);
			when 3 => v := resize(unsigned(hud(HUD_WEAPON_HI downto HUD_WEAPON_LO)), 24);
			when 4 => v := resize(unsigned(hud(HUD_LEVEL_HI downto HUD_LEVEL_LO)), 24);
			when 5 => v := resize(unsigned(hud(HUD_KILLS_HI downto HUD_KILLS_LO)), 24);
			when 6 => v := resize(unsigned(hud(HUD_TKILLS_HI downto HUD_TKILLS_LO)), 24);
			when 7 => v := resize(unsigned(hud(HUD_ITEMS_HI downto HUD_ITEMS_LO)), 24);
			when 8 => v := resize(unsigned(hud(HUD_TITEMS_HI downto HUD_TITEMS_LO)), 24);
			when 9 => v := resize(unsigned(hud(HUD_SECRETS_HI downto HUD_SECRETS_LO)), 24);
			when 10 => v := resize(unsigned(hud(HUD_TSECRETS_HI downto HUD_TSECRETS_LO)), 24);
			when 11 => v := resize(unsigned(hud(HUD_TMIN_HI downto HUD_TMIN_LO)), 24);
			when 12 => v := resize(unsigned(hud(HUD_TSEC_HI downto HUD_TSEC_LO)), 24);
			when 13 => v := unsigned(dbg(23 downto 0));
			when 14 => v := unsigned(dbg(47 downto 24));
			when 15 => v := unsigned(dbg(71 downto 48));
			when others => v := unsigned(dbg(95 downto 72));
		end case;
		return std_logic_vector(v);
	end function;

	-- ASCII for a character ROM entry: a literal, or a digit (or a leading
	-- space) of a number field, like num(v, width) in the model
	function decode(e: std_logic_vector(8 downto 0); digits: digits_t) return std_logic_vector is
		variable f: natural range 0 to 31;
		variable pos: natural range 0 to 7;
		variable dg: std_logic_vector(31 downto 0);
		variable ndig: natural range 1 to 8;
		variable dval: unsigned(3 downto 0);
	begin
		if (e(8) = '0') then
			return e(6 downto 0);
		end if;
		f := to_integer(unsigned(e(4 downto 0)));
		if (f > 16) then
			f := 16;
		end if;
		pos := to_integer(unsigned(e(7 downto 5)));
		dg := digits(f);
		-- Significant digits: one past the highest nonzero digit (at least 1)
		ndig := 1;
		for q in 1 to 7 loop
			if (unsigned(dg(4 * q + 3 downto 4 * q)) /= 0) then
				ndig := q + 1;
			end if;
		end loop;
		dval := unsigned(dg(4 * pos + 3 downto 4 * pos));
		-- Seconds (field 12) are zero padded; other fields blank their leading zeros
		if ((f = 12) or (pos = 0) or (pos < ndig)) then
			return std_logic_vector(resize(dval, 7) + 16#30#); -- 16#30# = ASCII '0'
		end if;
		return "0100000"; -- Space
	end function;

	function cond_ok(c: natural; flw: natural; am: std_logic; m: natural; dbg: std_logic)
		return boolean is
	begin
		case c is
			when C_AUTOMAP => return am = '1';
			when C_NOAUTO => return am = '0';
			when C_NOAUTO_ALIVE => return (am = '0') and (flw /= 4);
			when C_MSG => return m /= 0;
			when C_PAUSED => return flw = 3;
			when C_DEAD => return flw = 4;
			when C_DEBUG => return dbg = '1';
			when others => return true;
		end case;
	end function;
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
	-- ROMs and helpers
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			char_q <= CHAR_ROM(r.caddr);
			-- Second register: packs into the block RAM's output register,
			-- so decode() starts from a fast flip-flop (full-design timing)
			char_r <= char_q;
			sin_q <= SIN_TABLE(to_integer(r.taddr));
		end if;
	end process;

	font_row <= std_logic_vector(to_unsigned(r.row, 3));

	fonts: font_rom
		port map (
			clk_i => clk_i,
			char_i => r.ch,
			row_i => font_row,
			bits_o => font_bits
		);

	bcd_value <= field_value(r.f, hud_i, debug_i);
	bcd_start <= '1' when (r.state = S_BCD_GO) else '0';

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
	process(r)
	begin
		emit_req <= '0';
		ex <= 0;
		ey <= 0;
		ecolor <= 0;
		case r.state is
			when S_RECT =>
				emit_req <= '1';
				ex <= r.rx + r.i;
				ey <= r.ry + r.j;
				ecolor <= r.rc;
			when S_TXT_EMIT =>
				-- Font rows are MSB first: bit 7 is the leftmost pixel
				if (r.bits(7 - r.b) = '1') then
					emit_req <= '1';
				end if;
				ex <= r.cx + r.b * r.scale + r.dx;
				ey <= r.ty + r.row * r.scale + r.dy;
				ecolor <= r.tc;
			when S_BLIT_EMIT =>
				emit_req <= '1';
				-- d = 0..3 walks the 2x2 block: bit 0 is the x offset, bit 1 the y offset
				ex <= r.bx + 2 * r.u + (r.d mod 2);
				ey <= r.by + 2 * r.v + (r.d / 2);
				ecolor <= to_integer(unsigned(r.bits));
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
		variable addr: unsigned(16 downto 0);
		variable yy: unsigned(16 downto 0);
	begin
		if (rst_i = '1') then
			pix_valid <= '0';
			pix_data <= (others => '0');
		elsif rising_edge(clk_i) then
			if (can_load = '1') then
				if ((emit_req = '1') and (ex >= 0) and (ex < 320) and (ey >= 0) and (ey < 240)) then
					yy := to_unsigned(ey, 17);
					addr := shift_left(yy, 8) + shift_left(yy, 6) + to_unsigned(ex, 17);
					pix_valid <= '1';
					pix_data <= buf_i & std_logic_vector(addr) &
						std_logic_vector(to_unsigned(ecolor, 8));
				else
					pix_valid <= '0';
				end if;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Next state
	------------------------------------------------------------------
	process(r, start_i, flow, level, keys, wframe, bob, msg, automap, debug_on, char_r,
		font_bits, sin_q, bcd_done, bcd_digits, emit_ack, pix_valid, m_gnt_i, m_rvalid_i,
		m_rdata_i, map_data_i, seen_data_i, keypos_i, player_x_i, player_y_i, angle_i)
		variable v: regs_t;
		variable cmd: cmd_t;
		variable s: natural range 0 to 63;
		variable len: natural range 0 to 40;
		variable wf: natural range 0 to 60;
		variable t: std_logic_vector(23 downto 0);
		variable sp: natural range 0 to 7;
		variable kx, ky: natural range 0 to 63;
		variable p: integer;
		variable ch: std_logic_vector(6 downto 0);
	begin
		v := r;
		v.done := '0';
		cmd := PROG(r.pc);
		case r.state is
			when S_IDLE =>
				if (start_i = '1') then
					v.f := 0;
					v.state := S_BCD_GO;
				end if;

			when S_BCD_GO =>
				v.state := S_BCD_WAIT;

			when S_BCD_WAIT =>
				if (bcd_done = '1') then
					v.digits(r.f) := bcd_digits;
					if (r.f = 16) then
						case flow is
							when 0 => v.pc := PROG_TITLE;
							when 1 => v.pc := PROG_BRIEF;
							when 5 => v.pc := PROG_SCORE;
							when 6 => v.pc := PROG_END;
							when others => v.pc := PROG_HUD;
						end case;
						v.state := S_FETCH;
					else
						v.f := r.f + 1;
						v.state := S_BCD_GO;
					end if;
				end if;

			when S_FETCH =>
				if (cmd.op = OP_END) then
					v.state := S_FLUSH;
				elsif (not cond_ok(cmd.cond, flow, automap, msg, debug_on)) then
					v.pc := r.pc + 1;
				else
					case cmd.op is
						when OP_RECT =>
							v.rx := cmd.x;
							v.ry := cmd.y;
							v.rw := cmd.w;
							v.rh := cmd.h;
							v.i := 0;
							v.j := 0;
							v.ret := S_NEXT;
							case cmd.cmode is
								when CM_KEY1 =>
									v.rc := COLOR_DARK_GRAY;
									if (keys(0) = '1') then
										v.rc := C_BLUE_KEY;
									end if;
								when CM_KEY2 =>
									v.rc := COLOR_DARK_GRAY;
									if (keys(1) = '1') then
										v.rc := C_RED_KEY;
									end if;
								when others =>
									v.rc := cmd.color;
							end case;
							v.state := S_RECT;
						when OP_TEXT =>
							case cmd.sel is
								when SEL_MSG =>
									s := MSG_BASE + msg - 1;
								when SEL_BRIEF =>
									s := BRIEF_BASE + 4 * (level - 1) + cmd.str;
								when others =>
									s := cmd.str;
							end case;
							if (s > STR_COUNT - 1) then
								s := 0;
							end if;
							len := LENS(s);
							v.len := len;
							v.caddr := s * STR_LEN;
							v.k := 0;
							v.scale := cmd.scale;
							v.tc := cmd.color;
							v.ty := cmd.y;
							if (cmd.center) then
								-- (320 - len * 8 * scale) // 2, the model's text_center
								p := 320 - len * 8 * cmd.scale;
								v.cx := p / 2;
							else
								v.cx := cmd.x;
							end if;
							v.state := S_TXT_CHAR;
						when OP_BLIT =>
							wf := 55; -- Guard: a frame number past the table (60) reads frame 55
							if (wframe <= 60) then
								wf := wframe;
							end if;
							v.addr := to_unsigned(ART_BASE + FRAME_TABLE(wf)(0), 19);
							v.fw := FRAME_TABLE(wf)(1);
							v.fh := FRAME_TABLE(wf)(2);
							v.u := 0;
							v.v := 0;
							v.bx := cmd.x;
							v.by := cmd.y + bob;
							v.state := S_BLIT_REQ;
						when OP_MAP =>
							v.cell := cmd.w;
							v.mx0 := cmd.x;
							v.my0 := cmd.y;
							v.n := (others => '0');
							v.state := S_MAP_RD;
						when others =>
							v.state := S_FLUSH;
					end case;
				end if;

			when S_NEXT =>
				v.pc := r.pc + 1;
				v.state := S_FETCH;

			when S_RECT =>
				if (emit_ack = '1') then
					if (r.i = r.rw - 1) then
						v.i := 0;
						if (r.j = r.rh - 1) then
							v.j := 0;
							v.state := r.ret;
						else
							v.j := r.j + 1;
						end if;
					else
						v.i := r.i + 1;
					end if;
				end if;

			-- Text: one character at a time, one font row at a time
			when S_TXT_CHAR =>
				v.state := S_TXT_REG;

			when S_TXT_REG =>
				v.state := S_TXT_DEC;

			when S_TXT_DEC =>
				ch := decode(char_r, r.digits);
				v.ch := ch;
				v.row := 0;
				if (ch = "0100000") then
					-- A space has no lit pixels: go straight to the last bit
					v.row := 7;
					v.b := 7;
					v.bits := (others => '0');
					v.state := S_TXT_EMIT;
				else
					v.state := S_TXT_FONT;
				end if;

			when S_TXT_FONT =>
				v.state := S_TXT_BITS;

			when S_TXT_BITS =>
				v.bits := font_bits;
				v.b := 0;
				v.dx := 0;
				v.dy := 0;
				v.state := S_TXT_EMIT;

			when S_TXT_EMIT =>
				if ((r.bits(7 - r.b) = '0') or (emit_ack = '1')) then
					-- Next scale step, next bit, next row, next character
					if ((r.bits(7 - r.b) = '1') and (r.dx /= r.scale - 1)) then
						v.dx := r.dx + 1;
					elsif ((r.bits(7 - r.b) = '1') and (r.dy /= r.scale - 1)) then
						v.dx := 0;
						v.dy := r.dy + 1;
					else
						v.dx := 0;
						v.dy := 0;
						if (r.b /= 7) then
							v.b := r.b + 1;
						elsif (r.row /= 7) then
							v.row := r.row + 1;
							v.state := S_TXT_FONT;
						elsif (r.k = r.len - 1) then
							v.state := S_NEXT;
						else
							v.k := r.k + 1;
							v.caddr := r.caddr + 1;
							v.cx := r.cx + 8 * r.scale;
							v.state := S_TXT_CHAR;
						end if;
					end if;
				end if;

			-- Weapon blit: texel by texel, column-major, 2x2 pixels each
			when S_BLIT_REQ =>
				if (m_gnt_i = '1') then
					v.state := S_BLIT_WAIT;
				end if;

			when S_BLIT_WAIT =>
				if (m_rvalid_i = '1') then
					v.bits := m_rdata_i;
					v.d := 0;
					if (m_rdata_i = x"FF") then
						v.state := S_BLIT_ADV;
					else
						v.state := S_BLIT_EMIT;
					end if;
				end if;

			when S_BLIT_EMIT =>
				if (emit_ack = '1') then
					if (r.d = 3) then
						v.state := S_BLIT_ADV;
					else
						v.d := r.d + 1;
					end if;
				end if;

			when S_BLIT_ADV =>
				v.addr := r.addr + 1;
				v.state := S_BLIT_REQ;
				if (r.v = r.fh - 1) then
					v.v := 0;
					if (r.u = r.fw - 1) then
						v.state := S_NEXT;
					else
						v.u := r.u + 1;
					end if;
				else
					v.v := r.v + 1;
				end if;

			-- Map: tiles 0..4095, then keys, player, direction
			when S_MAP_RD =>
				v.state := S_MAP_CHK;

			when S_MAP_CHK =>
				if (seen_data_i = '1') then
					t := map_data_i;
					sp := to_integer(unsigned(t(16 downto 14))); -- Special: 1..3 doors, 4 exit
					if (unsigned(t(3 downto 0)) = 0) then
						v.rc := MAP_OPEN;
					elsif ((sp >= 1) and (sp <= 3)) then
						v.rc := MAP_DOOR;
					elsif (sp = 4) then
						v.rc := MAP_EXIT;
					else
						v.rc := MAP_WALL;
					end if;
					v.rx := r.mx0 + to_integer(r.n(5 downto 0)) * r.cell;
					v.ry := r.my0 + to_integer(r.n(11 downto 6)) * r.cell;
					v.rw := r.cell;
					v.rh := r.cell;
					v.i := 0;
					v.j := 0;
					v.ret := S_MAP_ADV;
					v.state := S_RECT;
				elsif (r.n = 4095) then
					v.key := 0;
					v.state := S_KEY_SETUP;
				else
					-- Unseen tile: straight to the next read (2 clocks per tile)
					v.n := r.n + 1;
					v.state := S_MAP_RD;
				end if;

			when S_MAP_ADV =>
				if (r.n = 4095) then
					v.key := 0;
					v.state := S_KEY_SETUP;
				else
					v.n := r.n + 1;
					v.state := S_MAP_RD;
				end if;

			when S_KEY_SETUP =>
				-- Key slot, from its base bit: + 0 on the floor, + 6..1 x, + 12..7 y
				if (r.key = 0) then
					kx := to_integer(unsigned(keypos_i(KEYPOS_BLUE + 6 downto KEYPOS_BLUE + 1)));
					ky := to_integer(unsigned(keypos_i(KEYPOS_BLUE + 12 downto KEYPOS_BLUE + 7)));
				else
					kx := to_integer(unsigned(keypos_i(KEYPOS_RED + 6 downto KEYPOS_RED + 1)));
					ky := to_integer(unsigned(keypos_i(KEYPOS_RED + 12 downto KEYPOS_RED + 7)));
				end if;
				v.n := to_unsigned(ky * 64 + kx, 12);
				if (((r.key = 0) and (keypos_i(KEYPOS_BLUE) = '1')) or
					((r.key = 1) and (keypos_i(KEYPOS_RED) = '1'))) then
					v.state := S_KEY_RD;
				else
					v.state := S_KEY_ADV;
				end if;

			when S_KEY_RD =>
				v.state := S_KEY_CHK;

			when S_KEY_CHK =>
				if (seen_data_i = '1') then
					if (r.key = 0) then
						v.rc := C_BLUE_KEY;
					else
						v.rc := C_RED_KEY;
					end if;
					v.rx := r.mx0 + to_integer(r.n(5 downto 0)) * r.cell;
					v.ry := r.my0 + to_integer(r.n(11 downto 6)) * r.cell;
					v.rw := r.cell;
					v.rh := r.cell;
					v.i := 0;
					v.j := 0;
					v.ret := S_KEY_ADV;
					v.state := S_RECT;
				else
					v.state := S_KEY_ADV;
				end if;

			when S_KEY_ADV =>
				if (r.key = 0) then
					v.key := 1;
					v.state := S_KEY_SETUP;
				else
					v.state := S_TRIG_A;
				end if;

			when S_TRIG_A =>
				v.taddr := unsigned(angle_i);
				v.state := S_TRIG_B;

			when S_TRIG_B =>
				v.state := S_TRIG_C;

			when S_TRIG_C =>
				v.sn := sin_q;
				v.taddr := unsigned(angle_i) + 256;
				v.state := S_TRIG_D;

			when S_TRIG_D =>
				v.state := S_TRIG_E;

			when S_TRIG_E =>
				-- Player cell
				v.cs := sin_q;
				v.rc := MAP_PLAYER;
				v.rx := r.mx0 + to_integer(unsigned(player_x_i(21 downto 16))) * r.cell;
				v.ry := r.my0 + to_integer(unsigned(player_y_i(21 downto 16))) * r.cell;
				v.rw := r.cell;
				v.rh := r.cell;
				v.i := 0;
				v.j := 0;
				v.ret := S_DIR;
				v.state := S_RECT;

			when S_DIR =>
				-- Direction cell: (p + 2 * cos) >> 16, (p + 2 * sin) >> 16
				-- (floor division; can be -1 or 64 near the map border)
				p := to_integer(unsigned(player_x_i)) + 2 * r.cs;
				v.rx := r.mx0 + to_integer(shift_right(to_signed(p, 24), 16)) * r.cell;
				p := to_integer(unsigned(player_y_i)) + 2 * r.sn;
				v.ry := r.my0 + to_integer(shift_right(to_signed(p, 24), 16)) * r.cell;
				v.rc := MAP_DIR;
				v.rw := r.cell;
				v.rh := r.cell;
				v.i := 0;
				v.j := 0;
				v.ret := S_NEXT;
				v.state := S_RECT;

			when S_FLUSH =>
				if (pix_valid = '0') then
					v.state := S_DONE;
				end if;

			when S_DONE =>
				v.done := '1';
				v.state := S_IDLE;
		end case;
		r_next <= v;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			r <= REGS_INIT;
		elsif rising_edge(clk_i) then
			r <= r_next;
		end if;
	end process;

	map_addr_o <= std_logic_vector(r.n);
	seen_addr_o <= std_logic_vector(r.n);
	m_req_o <= '1' when (r.state = S_BLIT_REQ) else '0';
	m_addr_o <= std_logic_vector(r.addr);
	pix_valid_o <= pix_valid;
	pix_data_o <= pix_data;
	busy_o <= '0' when (r.state = S_IDLE) else '1';
	done_o <= r.done;
end arch;

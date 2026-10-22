--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Game Constants Package
-- Module Name:    game_pkg
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Shared interface definitions:
--                 render size, bit positions of the packed words that cross
--                 between blocks (input snapshot, key vector, tile word,
--                 actor record, state table entry) and SRAM arbiter master
--                 numbers. Packed words are std_logic_vectors so they can
--                 be stored in BRAM and sent over the UART unchanged.
--                 Every block and the Python model (tools/model) rely on
--                 these layouts: change both together, and only with the
--                 whole team.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Stage 0 interfaces
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package game_pkg is
	-- Render size and output color depth (generics default to these)
	constant RENDER_W: natural := 320;
	constant RENDER_H: natural := 240;
	constant OUT_BITS: natural := 4; -- Bits per color channel at the Pmod VGA
	constant MAP_BITS: natural := 6; -- 64 x 64 tile map
	constant MAX_SPRITES: natural := 32;
	constant SRAM_CYCLES: natural := 2; -- System clocks per SRAM access (2 or 3)

	-- Pixel write port: SRAM address = buf & addr, addr = y * 320 + x.
	-- Packed into one word for the pixel FIFO: buf, addr, data.
	constant PIX_ADDR_BITS: natural := 17;
	constant PIXW_BITS: natural := 26;
	constant PIXW_BUF: natural := 25; -- Framebuffer select
	constant PIXW_ADDR_HI: natural := 24; -- 24:8 pixel index y * 320 + x
	constant PIXW_ADDR_LO: natural := 8;
	constant PIXW_DATA_HI: natural := 7; -- 7:0 palette index
	constant PIXW_DATA_LO: natural := 0;

	-- SRAM arbiter masters, highest priority first
	constant MASTER_DISPLAY: natural := 0;
	constant MASTER_SPRITE: natural := 1;
	constant MASTER_PIXEL: natural := 2;
	constant MASTER_LOADER: natural := 3;
	constant SRAM_MASTERS: natural := 4;

	------------------------------------------------------------------
	-- Key-state vector from the PS/2 keyboard decoder (one bit per key,
	-- '1' while held). Scan code set 2 codes are in ps2_keyboard.
	------------------------------------------------------------------
	constant KEY_W: natural := 0;
	constant KEY_A: natural := 1;
	constant KEY_S: natural := 2;
	constant KEY_D: natural := 3;
	constant KEY_C: natural := 4;
	constant KEY_Q: natural := 5;
	constant KEY_E: natural := 6;
	constant KEY_ESC: natural := 7;
	constant KEY_UP: natural := 8;
	constant KEY_DOWN: natural := 9;
	constant KEY_LEFT: natural := 10;
	constant KEY_RIGHT: natural := 11;
	constant KEY_SPACE: natural := 12;
	constant KEY_LSHIFT: natural := 13;
	constant KEY_RSHIFT: natural := 14;
	constant KEY_LCTRL: natural := 15;
	constant KEY_RCTRL: natural := 16;
	constant KEY_1: natural := 17;
	constant KEY_2: natural := 18;
	constant KEY_3: natural := 19;
	constant KEY_TAB: natural := 20;
	constant KEY_F1: natural := 21;
	constant KEYS_N: natural := 22;

	-- Mouse button vector
	constant BTN_LEFT: natural := 0;
	constant BTN_RIGHT: natural := 1;
	constant BTN_MIDDLE: natural := 2;

	------------------------------------------------------------------
	-- Per-frame input snapshot, 40 bits (also the replay record)
	------------------------------------------------------------------
	constant SNAP_BITS: natural := 40;
	constant SNAP_TURN_LO: natural := 0; -- 11:0 signed turn, + = clockwise
	constant SNAP_TURN_HI: natural := 11;
	constant SNAP_MOVE_LO: natural := 12; -- 13:12 signed -1/0/+1
	constant SNAP_MOVE_HI: natural := 13;
	constant SNAP_STRAFE_LO: natural := 14; -- 15:14 signed, + = right
	constant SNAP_STRAFE_HI: natural := 15;
	constant SNAP_RUN: natural := 16;
	constant SNAP_FIRE: natural := 17;
	constant SNAP_USE: natural := 18;
	constant SNAP_DUCK: natural := 19;
	constant SNAP_PEEK_L: natural := 20;
	constant SNAP_PEEK_R: natural := 21;
	constant SNAP_WSEL_LO: natural := 22; -- 23:22 weapon key 1..3, 0 = none
	constant SNAP_WSEL_HI: natural := 23;
	constant SNAP_WCYCLE: natural := 24;
	constant SNAP_AUTOMAP: natural := 25;
	constant SNAP_MENU: natural := 26;
	constant SNAP_DEBUG: natural := 27;

	------------------------------------------------------------------
	-- Tile word (24 bits, map BRAM)
	------------------------------------------------------------------
	constant TILE_BITS: natural := 24;
	constant TILE_WALL_LO: natural := 0; -- 3:0 wall texture, 0 = open
	constant TILE_WALL_HI: natural := 3;
	constant TILE_FLOOR_LO: natural := 4;
	constant TILE_FLOOR_HI: natural := 5;
	constant TILE_CEIL_LO: natural := 6;
	constant TILE_CEIL_HI: natural := 7;
	constant TILE_LIGHT_LO: natural := 8;
	constant TILE_LIGHT_HI: natural := 11;
	constant TILE_LTYPE_LO: natural := 12;
	constant TILE_LTYPE_HI: natural := 13;
	constant TILE_SPECIAL_LO: natural := 14;
	constant TILE_SPECIAL_HI: natural := 16;
	constant TILE_FLOORH_LO: natural := 17;
	constant TILE_FLOORH_HI: natural := 19;
	constant TILE_CEILH_LO: natural := 20;
	constant TILE_CEILH_HI: natural := 22;

	-- Tile special codes
	constant SPECIAL_NONE: natural := 0;
	constant SPECIAL_DOOR: natural := 1;
	constant SPECIAL_LOCKED1: natural := 2;
	constant SPECIAL_LOCKED2: natural := 3;
	constant SPECIAL_EXIT: natural := 4;
	constant SPECIAL_PUSHWALL: natural := 5;
	constant SPECIAL_TOXIC: natural := 6;
	constant SPECIAL_RAMP: natural := 7;

	------------------------------------------------------------------
	-- Actor record (64 bits) and state table entry (22 bits)
	------------------------------------------------------------------
	constant ACTOR_BITS: natural := 64;
	constant ACTOR_X_LO: natural := 0; -- Q6.10
	constant ACTOR_X_HI: natural := 15;
	constant ACTOR_Y_LO: natural := 16; -- Q6.10
	constant ACTOR_Y_HI: natural := 31;
	constant ACTOR_STATE_LO: natural := 32;
	constant ACTOR_STATE_HI: natural := 38;
	constant ACTOR_TIMER_LO: natural := 39;
	constant ACTOR_TIMER_HI: natural := 44;
	constant ACTOR_HEALTH_LO: natural := 45; -- 12 bits (boss health), tools/model/actors.py
	constant ACTOR_HEALTH_HI: natural := 56;
	constant ACTOR_TYPE_LO: natural := 57;
	constant ACTOR_TYPE_HI: natural := 59;
	constant ACTOR_FLAGS_LO: natural := 60; -- 60 active, 61 solid, 62 awake; 63 spare
	constant ACTOR_FLAGS_HI: natural := 62;

	constant STATE_BITS: natural := 22;
	constant STATE_FRAME_LO: natural := 0;
	constant STATE_FRAME_HI: natural := 4;
	constant STATE_DUR_LO: natural := 5;
	constant STATE_DUR_HI: natural := 10;
	constant STATE_ACTION_LO: natural := 11;
	constant STATE_ACTION_HI: natural := 14;
	constant STATE_NEXT_LO: natural := 15;
	constant STATE_NEXT_HI: natural := 21;

	------------------------------------------------------------------
	-- Display test patterns (display settings, test_pattern field)
	------------------------------------------------------------------
	constant PATTERN_FRAMEBUFFER: natural := 0;
	constant PATTERN_BANDS: natural := 1; -- One band per output bit
	constant PATTERN_CHECKER: natural := 2; -- 2x2 checker and white border
	constant PATTERN_GRID: natural := 3; -- 320x240 grid, 8-pixel cells
	constant PATTERN_GRADIENT: natural := 4; -- Every palette entry

	-- Screen tint codes
	constant TINT_NONE: natural := 0;
	constant TINT_RED: natural := 1;
	constant TINT_GOLD: natural := 2;
	constant TINT_GREEN: natural := 3;
end package game_pkg;

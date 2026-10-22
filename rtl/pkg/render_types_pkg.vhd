--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Renderer Types Package
-- Module Name:    render_types_pkg
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Bit layouts shared by the renderer blocks and the game:
--                 - Column descriptor, ray engine -> column rasterizer,
--                   packed into DESC_BITS. Field meanings match the dict
--                   returned by column() in tools/model/render.py. Rows
--                   y0..y1 are the clipped wall rows; y0 > y1 means no
--                   wall pixels (a wall thinner than one pixel).
--                 - Door table entry, game -> renderer: tile x, tile y,
--                   open amount 0..64 (64 = fully open; 0 = closed, so an
--                   unused entry is simply x = y = open = 0).
--                 - Frame registers widths.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.20 - Stage 4: span descriptor, clip entry, sprite floor height,
--                 effects
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;

package render_types_pkg is
	-- Frame registers
	constant POS_BITS: natural := 22; -- Q6.16
	constant ANGLE_BITS: natural := 10;
	constant EYE_BITS: natural := 7; -- 0..64

	-- Door table: 8 entries of 19 bits, entry k at bits 19k + 18 .. 19k
	constant DOOR_BITS: natural := 19;
	constant DOOR_X_LO: natural := 0; -- 5:0 tile x
	constant DOOR_X_HI: natural := 5;
	constant DOOR_Y_LO: natural := 6; -- 11:6 tile y
	constant DOOR_Y_HI: natural := 11;
	constant DOOR_OPEN_LO: natural := 12; -- 18:12 open amount 0..64
	constant DOOR_OPEN_HI: natural := 18;
	constant DOORS_BITS: natural := 8 * DOOR_BITS;

	-- Column descriptor
	constant DESC_COL_LO: natural := 0; -- 8:0 screen column 0..319
	constant DESC_COL_HI: natural := 8;
	constant DESC_Y0_LO: natural := 9; -- 16:9 first wall row (clipped)
	constant DESC_Y0_HI: natural := 16;
	constant DESC_Y1_LO: natural := 17; -- 24:17 last wall row (clipped)
	constant DESC_Y1_HI: natural := 24;
	constant DESC_TEX_LO: natural := 25; -- 28:25 wall texture id 1..15
	constant DESC_TEX_HI: natural := 28;
	constant DESC_TCOL_LO: natural := 29; -- 34:29 texture column 0..63
	constant DESC_TCOL_HI: natural := 34;
	constant DESC_V0_LO: natural := 35; -- 57:35 texture row at y0, Q7.16
	constant DESC_V0_HI: natural := 57;
	constant DESC_STEP_LO: natural := 58; -- 81:58 texture rows per screen row, Q8.16
	constant DESC_STEP_HI: natural := 81;
	constant DESC_LIGHT_LO: natural := 82; -- 85:82 effective wall light 0..15
	constant DESC_LIGHT_HI: natural := 85;
	constant DESC_SIDE: natural := 86; -- 0 x face, 1 y face
	constant DESC_RX_LO: natural := 87; -- 104:87 ray x, Q2.16 signed
	constant DESC_RX_HI: natural := 104;
	constant DESC_RY_LO: natural := 105; -- 122:105 ray y, Q2.16 signed
	constant DESC_RY_HI: natural := 122;
	-- Stage 4: the descriptor is one span of a column (tools/model/render.py); rows
	-- y0..y1 are drawn as the kind says. A column is a run of spans ending with the
	-- LAST bit. Wall spans (walls, risers, upper walls) use the texture fields; floor
	-- and ceiling spans use E and the ray (rowDist = (E * RINV(y)) >> 8)
	constant DESC_KIND_LO: natural := 123; -- 124:123 span kind: 0 ceiling, 1 floor, 2 textured
	constant DESC_KIND_HI: natural := 124;
	constant DESC_E_LO: natural := 125; -- 131:125 floor: eye - F, ceiling: C - eye (0..127)
	constant DESC_E_HI: natural := 131;
	constant DESC_LAST: natural := 132; -- Last span of the column
	constant DESC_BITS: natural := 133;
	constant KIND_CEIL: std_logic_vector(1 downto 0) := "00";
	constant KIND_FLOOR: std_logic_vector(1 downto 0) := "01";
	constant KIND_WALL: std_logic_vector(1 downto 0) := "10";

	-- Stage 4 effects register (game core -> renderer, render.py "Stage 4 effects"): the light
	-- offset of each light type (0 steady, 1 flicker, 2 strobe, 3 glow), signed -8..2, already
	-- including the muzzle flash, added to every tile light before distance; and the animated
	-- texture frame (slime cycles through wall ROM slots 5, 8, 9, 10)
	constant FX_BITS: natural := 22;
	constant FX_LMOD_W: natural := 5; -- Light type k offset at bits 5k + 4 .. 5k (signed)
	constant FX_ANIM_LO: natural := 20; -- 21:20 animation frame 0..3
	constant FX_ANIM_HI: natural := 21;

	-- Stage 4 clip entry (ray engine -> sprite engine): the open window after a height edge,
	-- up to CLIP_MAX (render_pkg) per column, nearest first; a closed window is (z, 1, 0)
	constant CLIP_BITS: natural := 32;
	constant CLIP_Z_LO: natural := 0; -- 15:0 z of the edge, Q6.10 (as the z-buffer)
	constant CLIP_Z_HI: natural := 15;
	constant CLIP_TOP_LO: natural := 16; -- 23:16 first open row
	constant CLIP_TOP_HI: natural := 23;
	constant CLIP_BOT_LO: natural := 24; -- 31:24 last open row
	constant CLIP_BOT_HI: natural := 31;

	------------------------------------------------------------------
	-- Stage 2/3 (as in tools/model/game.py, sprites.py, overlay.py)
	------------------------------------------------------------------
	-- Sprite table entry, game core -> sprite engine (32 entries, actor order)
	constant SPR_BITS: natural := 64;
	constant SPR_IDX_LO: natural := 0; -- 4:0 actor index
	constant SPR_IDX_HI: natural := 4;
	constant SPR_X_LO: natural := 5; -- 20:5 x, Q6.10
	constant SPR_X_HI: natural := 20;
	constant SPR_Y_LO: natural := 21; -- 36:21 y, Q6.10
	constant SPR_Y_HI: natural := 36;
	constant SPR_FRAME_LO: natural := 37; -- 44:37 art frame 0..60
	constant SPR_FRAME_HI: natural := 44;
	constant SPR_LIGHT_LO: natural := 45; -- 48:45 tile light
	constant SPR_LIGHT_HI: natural := 48;
	constant SPR_BRIGHT: natural := 49; -- Fullbright (fireballs)
	constant SPR_TARGET: natural := 50; -- Hitscan target (living monster)
	constant SPR_FLOOR_LO: natural := 51; -- 57:51 stage 4: floor height under the sprite, 0..64
	constant SPR_FLOOR_HI: natural := 57;

	-- Hitscan span, sprite engine -> game core (32 entries, drawing order)
	constant SPAN_BITS: natural := 48;
	constant SPAN_IDX_LO: natural := 0; -- 4:0 actor index
	constant SPAN_IDX_HI: natural := 4;
	constant SPAN_X0_LO: natural := 5; -- 13:5 first column
	constant SPAN_X0_HI: natural := 13;
	constant SPAN_X1_LO: natural := 14; -- 22:14 last column
	constant SPAN_X1_HI: natural := 22;
	constant SPAN_Z_LO: natural := 23; -- 38:23 z, Q6.10
	constant SPAN_Z_HI: natural := 38;

	-- Sound command, game core -> mixer
	constant SND_BITS: natural := 21;
	constant SND_ID_LO: natural := 0; -- 4:0 sound id 0..17
	constant SND_ID_HI: natural := 4;
	constant SND_VOL_LO: natural := 5; -- 10:5 volume 0..63
	constant SND_VOL_HI: natural := 10;
	constant SND_PAN_LO: natural := 11; -- 16:11 pan -31..31 (signed)
	constant SND_PAN_HI: natural := 16;
	constant SND_PRI_LO: natural := 17; -- 20:17 priority
	constant SND_PRI_HI: natural := 20;

	-- HUD word, game core -> overlay (fields of game.hud(), same order)
	constant HUD_BITS: natural := 101;
	constant HUD_FLOW_LO: natural := 0; -- 2:0 0 title, 1 briefing, 2 playing,
	constant HUD_FLOW_HI: natural := 2; -- 3 paused, 4 dead, 5 score, 6 ending
	constant HUD_LEVEL_LO: natural := 3; -- 4:3 level 1..3
	constant HUD_LEVEL_HI: natural := 4;
	constant HUD_HEALTH_LO: natural := 5; -- 12:5
	constant HUD_HEALTH_HI: natural := 12;
	constant HUD_ARMOR_LO: natural := 13; -- 20:13
	constant HUD_ARMOR_HI: natural := 20;
	constant HUD_AMMO_LO: natural := 21; -- 28:21
	constant HUD_AMMO_HI: natural := 28;
	constant HUD_WEAPON_LO: natural := 29; -- 30:29 1 pistol, 2 shotgun
	constant HUD_WEAPON_HI: natural := 30;
	constant HUD_KEYS_LO: natural := 31; -- 32:31 bit 0 blue, bit 1 red
	constant HUD_KEYS_HI: natural := 32;
	constant HUD_WFRAME_LO: natural := 33; -- 40:33 weapon art frame
	constant HUD_WFRAME_HI: natural := 40;
	constant HUD_BOB_LO: natural := 41; -- 43:41 weapon bob 0..4
	constant HUD_BOB_HI: natural := 43;
	constant HUD_MSG_LO: natural := 44; -- 47:44 message id (0 none)
	constant HUD_MSG_HI: natural := 47;
	constant HUD_KILLS_LO: natural := 48; -- 53:48
	constant HUD_KILLS_HI: natural := 53;
	constant HUD_TKILLS_LO: natural := 54; -- 59:54
	constant HUD_TKILLS_HI: natural := 59;
	constant HUD_ITEMS_LO: natural := 60; -- 65:60
	constant HUD_ITEMS_HI: natural := 65;
	constant HUD_TITEMS_LO: natural := 66; -- 71:66
	constant HUD_TITEMS_HI: natural := 71;
	constant HUD_SECRETS_LO: natural := 72; -- 75:72
	constant HUD_SECRETS_HI: natural := 75;
	constant HUD_TSECRETS_LO: natural := 76; -- 79:76
	constant HUD_TSECRETS_HI: natural := 79;
	constant HUD_TMIN_LO: natural := 80; -- 86:80 level time minutes
	constant HUD_TMIN_HI: natural := 86;
	constant HUD_TSEC_LO: natural := 87; -- 92:87 seconds
	constant HUD_TSEC_HI: natural := 92;
	constant HUD_AUTOMAP: natural := 93;
	constant HUD_DEBUG: natural := 94;
	-- 100:95 spare

	-- Keys still on the floor, for the maps: per key valid, tile x, tile y
	constant KEYPOS_BITS: natural := 26;
	constant KEYPOS_BLUE: natural := 0; -- 0 valid, 6:1 x, 12:7 y
	constant KEYPOS_RED: natural := 13; -- 13 valid, 19:14 x, 25:20 y

	-- Game-core state read-out (testbench and UART): word k of game.state_words()
	constant STATE_WORDS: natural := 91; -- 19 scalars, 8 doors x 5, 32 actors
end package render_types_pkg;

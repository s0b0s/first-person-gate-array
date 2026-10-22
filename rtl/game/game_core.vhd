--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Game Core
-- Module Name:    game_core
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Stage-2/3 game core: one Game.step of tools/model/game.py
--                 (with actors.py) per frame, bit for bit, including every
--                 random() call in order, the sound commands, the HUD word
--                 and the sprite table. Replaces game_seq in the game top.
--
--                 Flow per frame (snapshot_valid_i after frame_start_i):
--                   S_STEP   sounds cleared, fire edge, debug toggle, flow
--                            switch (TITLE, BRIEFING, PAUSED, DEAD, SCORE,
--                            ENDING are a few registers; BRIEFING go and a
--                            DEAD restart load a level here)
--                   PLAYING, in the model's order:
--                     1 S_PLAY   level clock, turn, duck and peek easing;
--                                sin/cos of the new angle (S_P_SIN, S_P_COS)
--                     2 S_MOVE   x then y: box test (4 map reads), solid
--                                actors (32 actor reads), flush clamp
--                     3 S_PEEK   camera box test, offset shrinks by 2
--                     4 S_PICK   item pickups in actor order; S_SPEC secret
--                                and toxic floor
--                     5 S_USE    door, locked door or exit switch ahead
--                     6 S_WPN    weapon select, cooldown, fire; S_HS_*
--                                hitscan against the last frame's spans;
--                                after a shot S_AL_* (stage 5, Game.alert):
--                                flood fill from the player's cell over
--                                open cells (walls and closed doors stop
--                                it; a 4096 x 12 queue BRAM and a 4096 x 1
--                                visited RAM, cleared again through the
--                                queue), then every sleeping, living
--                                monster in a reached cell that is in a
--                                LOOK state and not an ambusher wakes as
--                                in LOOK (sight sound, chase state)
--                     7 S_ACT_*  actors 0..31 (LOOK, CHASE, FLY, timers)
--                     8 S_DOORS  door table, then S_WORLD (boss timer,
--                                flashes, message timer, death check)
--                   S_END    sprite table (one map read per active actor
--                            for its light) into the back half of the
--                            sprite RAM; key positions
--                   S_CRC_*  CRC-32 of the 91 state words, 8 bytes each
--                   S_OUT    all outputs registered, render_start_o pulse,
--                            sprite RAM halves swap, sound commands go out
--
--                 Subroutines: the model calls helpers from several places
--                 (LOS from LOOK, CHASE and the SHOOT action; SOUND from
--                 everywhere). None of them is ever active twice at once,
--                 so each has its own return-state register (*_ret); a
--                 call stores the state to come back to and jumps in, and
--                 a call as the last thing a subroutine does passes its own
--                 return state on (a tail call, e.g. DAMAGE -> SOUND).
--                   S_WAIT        1-clock read of map, span or z port
--                   S_BOX         box (2 x 2 cells) against solid cells
--                   S_LOS         Bresenham line of sight, map per cell
--                   S_DB          door blocked by the player or an actor
--                   S_SND         sound command: volume, pan on the DSP
--                   S_DP          damage to the player (armor, sound)
--                   S_ENTER       actor enters a state, runs its action
--                   S_SPAWN       new actor in the first free slot
--
--                 Memories: actor table 32 x 64 LUT RAM (one write port
--                 shared with the loader while it loads, a read port for
--                 the core, one for the state read-out); sprite table 2 x
--                 32 x 64 LUT RAM (double buffered, 1-clock read on
--                 spr_*); sine ROM (registered read). The map, span and
--                 z-buffer ports are 1-clock reads.
--                 Number formats: player Q6.16 (24-bit signed working
--                 copies), actors Q6.10, sin/cos Q2.16.
--                 Multiplies: the pan (rx * -sin + ry * cos) and the peek
--                 offset (off * -sin, off * cos) use one shared 24 x 18
--                 multiplier (1 clock; Vivado keeps a second copy fused
--                 with the pan sum, so 2 DSP48); every other product is a
--                 shift-add by a small constant.
--                 Timing helpers: the actor RAM read port 1 and its write
--                 port are registered (each read takes S_WAIT), and the
--                 distance, deltas and sound volume of the working actor
--                 are computed in registers behind r (see their process).
--                 The actor record layout is the model's (actors.py:
--                 x 15:0, y 31:16, state 38:32, timer 44:39, health 56:45,
--                 type 59:57, flags 62:60 active, solid, awake; 63 ambush,
--                 stage 5: deaf to sound alerts).
--                 Clock domain: clk_i (system). Measured on the golden
--                 session (tb_game_core): about 1,300 clocks per frame
--                 (PLAYING average 1,324, worst 1,456 without a load); a
--                 level load adds the loader's time plus about 4,200 clocks
--                 (actor totals, 4096-tile secret count).
--                 Coding: two-segment style with all registers in one
--                 record r; the combinational process computes r_next.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, game_pkg,
--                 game_tables_pkg, render_pkg (SIN_TABLE), render_types_pkg,
--                 core_crc
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Stage 2/3 (actors, weapons, flow, sounds)
-- Revision 2.10 - Stage 4: floor heights, ramps, falling, sprite floors;
--                 effects register fx_o (light type offsets, animation
--                 frame), sprite lights offset by their tile's light type
-- Revision 3.00 - Stage 5: sound alerts (S_AL_* flood fill), ambush flag (bit
--                 63)
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.game_pkg.all;
use work.game_tables_pkg.all;
use work.render_pkg.all;
use work.render_types_pkg.all;

entity game_core is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		-- Level loader
		load_req_o: out std_logic; -- Pulse: load level load_level_o, then wait
		load_level_o: out std_logic_vector(1 downto 0); -- 1..3
		load_done_i: in std_logic; -- Pulse: map, actor records and start pose written
		start_x_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Q6.16
		start_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
		start_angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
		act_we_i: in std_logic; -- Loader writes actor record act_addr_i (all 32)
		act_addr_i: in std_logic_vector(4 downto 0);
		act_data_i: in std_logic_vector(63 downto 0);
		-- Frame
		frame_start_i: in std_logic; -- Pulse from the buffer manager
		snapshot_i: in std_logic_vector(SNAP_BITS - 1 downto 0); -- Input snapshot
		snapshot_valid_i: in std_logic; -- Pulse, 2 clocks after frame_start_i
		-- Tile map port B (1-clock read), used only while busy_o
		map_addr_o: out std_logic_vector(11 downto 0); -- y & x
		map_we_o: out std_logic;
		map_wdata_o: out std_logic_vector(23 downto 0);
		map_data_i: in std_logic_vector(23 downto 0);
		-- Last frame's hitscan spans and wall z (1-clock reads)
		span_addr_o: out std_logic_vector(4 downto 0);
		span_data_i: in std_logic_vector(SPAN_BITS - 1 downto 0);
		span_count_i: in std_logic_vector(5 downto 0);
		zwall_addr_o: out std_logic_vector(8 downto 0);
		zwall_data_i: in std_logic_vector(15 downto 0);
		-- Renderer registers (change only at render_start_o)
		cam_x_o: out std_logic_vector(POS_BITS - 1 downto 0);
		cam_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
		angle_o: out std_logic_vector(ANGLE_BITS - 1 downto 0);
		eye_o: out std_logic_vector(EYE_BITS - 1 downto 0);
		doors_o: out std_logic_vector(DOORS_BITS - 1 downto 0); -- Idle entries zero
		player_x_o: out std_logic_vector(POS_BITS - 1 downto 0);
		player_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
		hud_o: out std_logic_vector(HUD_BITS - 1 downto 0);
		keypos_o: out std_logic_vector(KEYPOS_BITS - 1 downto 0);
		music_o: out std_logic_vector(1 downto 0); -- Level while PLAYING/PAUSED/DEAD, else 0
		tint_o: out std_logic_vector(1 downto 0); -- game.tint(): 1 damage, 2 pickup, 3 toxic, 0 none
		fx_o: out std_logic_vector(FX_BITS - 1 downto 0); -- Effects: game.lmod(), game.anim() (render_types_pkg FX_*)
		-- Sprite table (1-clock read)
		spr_addr_i: in std_logic_vector(4 downto 0);
		spr_data_o: out std_logic_vector(SPR_BITS - 1 downto 0);
		spr_count_o: out std_logic_vector(5 downto 0);
		render_start_o: out std_logic; -- Pulse: the outputs above hold this frame
		busy_o: out std_logic; -- Step running (map port B in use)
		-- Sound commands, up to 4 per frame in model order, after render_start_o
		snd_valid_o: out std_logic;
		snd_ready_i: in std_logic;
		snd_data_o: out std_logic_vector(SND_BITS - 1 downto 0);
		level_loaded_o: out std_logic; -- Pulse after each level load
		-- State read-out: word k of game.state_words(), 1-clock read, valid
		-- while busy_o is low
		state_addr_i: in std_logic_vector(6 downto 0);
		state_data_o: out std_logic_vector(63 downto 0);
		crc_o: out std_logic_vector(31 downto 0) -- game.state_crc(), at render_start_o
	);
end game_core;

architecture arch of game_core is
	component core_crc is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			init_i: in std_logic;
			valid_i: in std_logic;
			data_i: in std_logic_vector(7 downto 0);
			crc_o: out std_logic_vector(31 downto 0)
		);
	end component;

	-- Sizes and rules (tools/model/game.py, actors.py)
	constant HALF: integer := 16384; -- Player box half size R, 0.25 tile in Q.16; also the actor box (256 in Q6.10)
	constant CAM_HALF: integer := 8192; -- Peek camera box half size
	constant PICK_RANGE: integer := 24576; -- R + ITEM_HALF
	constant BLOCK_RANGE: integer := 32768; -- R + (ACTOR_HALF << 6)
	constant WAKE_RANGE: integer := 12288; -- 12 tiles, Q6.10 Manhattan
	constant MELEE_RANGE: integer := 1280; -- 1.25 tiles, Q6.10 Manhattan
	constant STOP_RANGE: integer := 768; -- 0.75 tile: a chaser stops this close
	constant FIRE_HIT: integer := 384; -- ACTOR_HALF + 128
	constant DOOR_STEP: integer := 2;
	constant DOOR_OPEN: integer := 64;
	constant DOOR_STAY: natural := 180; -- Frames a door stays open (3 s)
	constant DOOR_RETRY: natural := 30; -- Extra frames when something is in the doorway
	constant MSG_TIME: natural := 120; -- Frames a message shows (2 s)
	constant BOSS_TIME: natural := 180; -- Frames from the boss's death to the level end
	constant LEVELS: natural := 3;
	-- Stage 4 heights (units, 64 per tile): step-up limit, headroom of the player
	-- and of the monsters (both 40), gravity
	constant STEP_MAX: natural := 24;
	constant BODY_H: natural := 40; -- PLAYER_H = ACTOR_H = 40
	constant FALL_ACC: natural := 2;
	constant FALL_MAX: natural := 16;
	constant SPECIAL_RAMP: natural := 7;

	constant FL_TITLE: unsigned(2 downto 0) := "000";
	constant FL_BRIEFING: unsigned(2 downto 0) := "001";
	constant FL_PLAYING: unsigned(2 downto 0) := "010";
	constant FL_PAUSED: unsigned(2 downto 0) := "011";
	constant FL_DEAD: unsigned(2 downto 0) := "100";
	constant FL_SCORE: unsigned(2 downto 0) := "101";
	constant FL_ENDING: unsigned(2 downto 0) := "110";

	constant DS_IDLE: unsigned(1 downto 0) := "00";
	constant DS_OPENING: unsigned(1 downto 0) := "01";
	constant DS_OPEN: unsigned(1 downto 0) := "10";
	constant DS_CLOSING: unsigned(1 downto 0) := "11";

	-- Actor actions (state table bits 14:11), types, fixed states
	constant A_LOOK: natural := 1;
	constant A_CHASE: natural := 2;
	constant A_MELEE: natural := 4;
	constant A_SHOOT: natural := 5;
	constant A_FIRE: natural := 6;
	constant A_PAIN: natural := 7;
	constant A_DIE: natural := 8;
	constant A_REMOVE: natural := 9;
	constant A_FLY: natural := 10;
	constant A_EXPLODE: natural := 11;
	constant T_GRUNT: natural := 0;
	constant T_BOSS: natural := 3;
	constant T_FIREBALL: natural := 4;
	constant T_ITEM: natural := 5;
	constant ST_FLY_A: natural := 45; -- Fireball states
	constant ST_EXPL_A: natural := 47;
	constant ST_ITEM_IDLE: natural := 50;
	constant FOREVER: natural := 63; -- Timer value that never counts down
	constant I_BULLETS: natural := 3; -- Item kind a dead grunt drops
	constant I_SHOTGUN: natural := 5;
	constant I_KEY1: natural := 6;
	constant I_KEY2: natural := 7;
	constant ITEM_BASE: natural := 38; -- art.py: first item / effect frame
	constant WEAPON_BASE: natural := 55; -- art.py: first weapon frame

	-- Sound ids (actors.py)
	constant S_PISTOL: natural := 0;
	constant S_SHOTGUN: natural := 1;
	constant S_DOOR_OPEN: natural := 2;
	constant S_DOOR_CLOSE: natural := 3;
	constant S_ITEM: natural := 4;
	constant S_WEAPON: natural := 5;
	constant S_PLAYER_PAIN: natural := 6;
	constant S_PLAYER_DEATH: natural := 7;
	constant S_SIGHT: natural := 8;
	constant S_SHOOT: natural := 9;
	constant S_FIRE: natural := 10;
	constant S_EXPLODE: natural := 11;
	constant S_CLAW: natural := 12;
	constant S_PAIN: natural := 13;
	constant S_DEATH: natural := 14;
	constant S_SWITCH: natural := 15;
	constant S_NOWAY: natural := 16;
	constant S_BOSS_SIGHT: natural := 17;

	-- TYPE_TABLE columns (game_tables_pkg)
	constant TP_SPEED: natural := 1;
	constant TP_RANGED: natural := 2;
	constant TP_MELEE: natural := 3;
	constant TP_RANGE: natural := 4; -- Tiles
	constant TP_MASK: natural := 5;
	constant TP_PAIN: natural := 6;
	constant TP_MULT: natural := 7;
	constant TP_CHASE: natural := 8;
	constant TP_PAIN_ST: natural := 9;
	constant TP_AIM_ST: natural := 10;
	constant TP_MELEE_ST: natural := 11;
	constant TP_DIE_ST: natural := 12;

	subtype pos_t is signed(23 downto 0); -- Q6.16 with headroom
	subtype trig_t is signed(17 downto 0); -- Q2.16

	type actor_t is record
		x: unsigned(15 downto 0); -- Q6.10
		y: unsigned(15 downto 0);
		state: unsigned(6 downto 0);
		timer: unsigned(5 downto 0);
		health: unsigned(11 downto 0); -- Fireball: direction; item: kind
		typ: unsigned(2 downto 0);
		active: std_logic;
		solid: std_logic;
		awake: std_logic;
		ambush: std_logic; -- Stage 5: ignores sound alerts
	end record;
	constant ACTOR_CLEAR: actor_t := ((others => '0'), (others => '0'), (others => '0'),
		(others => '0'), (others => '0'), (others => '0'), '0', '0', '0', '0');

	type door_t is record
		x: unsigned(5 downto 0);
		y: unsigned(5 downto 0);
		open_amt: signed(7 downto 0); -- 0..64
		state: unsigned(1 downto 0);
		timer: unsigned(7 downto 0);
	end record;
	type doors_t is array (0 to 7) of door_t;
	constant DOOR_CLEAR: door_t := ((others => '0'), (others => '0'), (others => '0'),
		DS_IDLE, (others => '0'));

	type player_t is record
		health: unsigned(7 downto 0);
		armor: unsigned(7 downto 0);
		bullets: unsigned(7 downto 0);
		shells: unsigned(5 downto 0);
		weapons: unsigned(1 downto 0); -- Bit 0 pistol, bit 1 shotgun
		weapon: unsigned(1 downto 0); -- 1 pistol, 2 shotgun
	end record;
	constant PLAYER_INIT: player_t := (to_unsigned(100, 8), to_unsigned(0, 8), to_unsigned(50, 8),
		to_unsigned(0, 6), "01", "01");

	type snd_t is record
		id: unsigned(4 downto 0);
		vol: unsigned(5 downto 0);
		pan: signed(5 downto 0);
	end record;
	type sndq_t is array (0 to 3) of snd_t;
	constant SND_CLEAR: snd_t := ((others => '0'), (others => '0'), (others => '0'));

	type st_t is (S_INIT, S_LOAD, S_LOAD_W, S_TOTA, S_TOT0, S_TOT, S_TOT_LAST,
		S_IDLE, S_STEP, S_PLAY, S_P_SIN, S_P_COS, S_P_VEL,
		S_MOVE, S_MOVE_BOX, S_AB, S_MOVE_NEXT,
		S_PEEK, S_PEEK_M1, S_PEEK_M2, S_PEEK_M3, S_PEEK2,
		S_PICK, S_PICK_T, S_PICK_N, S_SPEC, S_SPEC2,
		S_USE, S_USE2, S_UDOOR, S_UDOOR2,
		S_WPN, S_HS_COL, S_HS_ZW, S_HS_SP, S_HS_END, S_DA, S_HS_WB, S_HS_NEXT,
		S_ACTORS, S_ACT_LD, S_ACT_GO, S_LOOK, S_LOOK2, S_LOOK3, S_CHASE, S_CHASE2, S_CHASE3,
		S_CHASE3B, S_CHASE4, S_CHASE5, S_CHASE6, S_FLY, S_FLY2, S_FLY3, S_TICK, S_ACT_WB, S_ACT_NX,
		S_DOORS, S_DOOR_OPEN2, S_DOOR_CL2, S_DOOR_NX, S_WORLD,
		S_END, S_SPR_T, S_SPR_L, S_SPR_N, S_CRC0, S_CRC_W, S_CRC_B, S_OUT,
		S_WAIT, S_BOX, S_BOX_D, S_LOS, S_LOS_IT, S_LOS_D, S_DB, S_DB_S,
		S_SND, S_SND_W, S_SND_V, S_SND_M1, S_SND_M2, S_SND_M3, S_SND_M4, S_DP, S_DP2, S_ENTER,
		S_A_SHOOT2, S_A_SHOOT3, S_A_SHOOT4, S_A_FIRE2, S_A_MELEE2, S_A_DIE2,
		S_SPAWN, S_SPAWN_S,
		S_FAT, S_FAT_D, S_FAT_N, S_FAT_W, S_FAT_M, S_BFL, S_BFL_N, S_ZF, S_ZF2, S_LOAD_Z,
		S_CHASE3C, S_CHASE5B, S_SPR_F,
		S_AL0, S_AL_POP, S_AL_POPW, S_AL_CUR, S_AL_NB, S_AL_NBD, S_AL_LD, S_AL_LD2, S_AL_CHK,
		S_AL_ENT, S_AL_WB, S_AL_NX, S_AL_CLR, S_AL_CLRW, S_AL_CLR2);

	type regs_t is record
		st: st_t;
		wret: st_t; -- Return states of the subroutines
		box_ret: st_t;
		los_ret: st_t;
		db_ret: st_t;
		snd_ret: st_t;
		dp_ret: st_t;
		en_ret: st_t;
		sp_ret: st_t;
		fat_ret: st_t;
		bfl_ret: st_t;
		armed: std_logic; -- frame_start seen, waiting for the snapshot
		pending: std_logic; -- A snapshot is waiting in snap_in
		snap_in: std_logic_vector(SNAP_BITS - 1 downto 0);
		snap: std_logic_vector(SNAP_BITS - 1 downto 0); -- This step's snapshot
		in_step: std_logic; -- Level load inside a step (else after reset)
		-- Game state (Game attributes)
		flow: unsigned(2 downto 0);
		level: unsigned(1 downto 0);
		prev_fire: std_logic;
		debug: std_logic;
		pl: player_t;
		saved: player_t; -- Player at the level start (DEAD restart)
		px: pos_t;
		py: pos_t;
		angle: unsigned(9 downto 0);
		eye: unsigned(6 downto 0);
		z: unsigned(7 downto 0); -- Stage 4: floor contact height (units)
		vz: unsigned(4 downto 0); -- Fall speed 0..16
		off: signed(5 downto 0); -- Peek offset -16..16
		cam_x: pos_t;
		cam_y: pos_t;
		keys: unsigned(1 downto 0);
		cooldown: unsigned(5 downto 0);
		flash: unsigned(2 downto 0);
		dflash: unsigned(3 downto 0); -- damage_flash
		pflash: unsigned(2 downto 0); -- pickup_flash
		msg: unsigned(3 downto 0);
		msg_timer: unsigned(6 downto 0);
		phase: unsigned(4 downto 0);
		kills: unsigned(5 downto 0);
		items: unsigned(5 downto 0);
		secrets: unsigned(3 downto 0);
		tkills: unsigned(5 downto 0);
		titems: unsigned(5 downto 0);
		tsecrets: unsigned(3 downto 0);
		t_frames: unsigned(5 downto 0);
		t_sec: unsigned(5 downto 0);
		t_min: unsigned(6 downto 0);
		lfsr: unsigned(15 downto 0);
		boss_timer: unsigned(7 downto 0);
		level_done: std_logic;
		dead_timer: unsigned(5 downto 0); -- Saturates at 63 (only "> 30" matters)
		automap: std_logic;
		on_toxic: std_logic; -- Last specials() found toxic floor (kept across levels, as the model)
		doors: doors_t;
		-- Movement
		cs: trig_t;
		sn: trig_t;
		mdx: pos_t; -- This frame's move
		mdy: pos_t;
		my: std_logic; -- Moving along y (else x)
		-- Map read and box test
		maddr: unsigned(11 downto 0); -- y & x
		bx: pos_t; -- Box center, Q6.16
		by: pos_t;
		bsmall: std_logic; -- Camera box (CAM_HALF), else HALF
		bk: unsigned(1 downto 0); -- Box corner: bit 0 picks x, bit 1 picks y
		hit: std_logic;
		bz: unsigned(7 downto 0); -- Height of the body the box test is for
		-- floor_at() and box_floor()
		fpx: pos_t; -- Point, Q6.16
		fpy: pos_t;
		ff: unsigned(7 downto 0); -- Floor of the point's tile
		fs: unsigned(16 downto 0); -- Ramp: distance from the low end, 0..65536
		fat: unsigned(7 downto 0); -- Result of floor_at()
		bfk: unsigned(1 downto 0); -- box_floor() corner
		bfl: unsigned(7 downto 0); -- Result of box_floor()
		-- Line of sight
		lx: unsigned(5 downto 0);
		ly: unsigned(5 downto 0);
		lx1: unsigned(5 downto 0);
		ly1: unsigned(5 downto 0);
		ldx: signed(7 downto 0);
		ldy: signed(7 downto 0);
		lsx: signed(1 downto 0);
		lsy: signed(1 downto 0);
		lerr: signed(8 downto 0);
		lcnt: unsigned(6 downto 0);
		los: std_logic;
		-- Doors
		di: unsigned(2 downto 0);
		blocked: std_logic;
		-- Sounds
		snd_id: unsigned(4 downto 0);
		snd_act: std_logic; -- Sound comes from actor a (else full volume, centre)
		svol: unsigned(5 downto 0);
		mul_a: signed(23 downto 0); -- Shared multiplier operands
		mul_b: trig_t;
		acc: signed(41 downto 0);
		lat: signed(15 downto 0); -- Pan before the clamp
		sq: sndq_t; -- This step's commands
		sq_n: unsigned(2 downto 0);
		oq: sndq_t; -- Last step's commands, going out
		oq_n: unsigned(2 downto 0);
		oq_p: unsigned(2 downto 0);
		dmg: unsigned(5 downto 0); -- DAMAGE argument
		-- Actors
		a: actor_t; -- Working copy of actor ai
		ai: unsigned(4 downto 0);
		aaddr: unsigned(4 downto 0); -- Actor RAM read address (port 1)
		en_s: unsigned(6 downto 0); -- ENTER argument
		sp_type: unsigned(2 downto 0); -- SPAWN arguments
		sp_state: unsigned(6 downto 0);
		sp_health: unsigned(11 downto 0);
		d: unsigned(18 downto 0); -- dist(a) in CHASE
		csx: signed(7 downto 0); -- CHASE step
		csy: signed(7 downto 0);
		-- Hitscan
		hk: unsigned(2 downto 0); -- Column 136 + 8 hk
		hshot: std_logic; -- Shotgun: all 7 columns
		hdmg: unsigned(5 downto 0);
		zw: unsigned(15 downto 0);
		span_addr: unsigned(4 downto 0);
		zw_addr: unsigned(8 downto 0);
		best_v: std_logic;
		best_i: unsigned(4 downto 0);
		best_z: unsigned(15 downto 0);
		-- Totals after a load
		tp1: std_logic; -- map_data_i holds the tile of the address before
		-- Sprite table and checksum
		spr_n: unsigned(5 downto 0);
		spr_e: std_logic_vector(63 downto 0);
		spr_ty: std_logic_vector(1 downto 0); -- Light type of the sprite's tile
		fxn: unsigned(7 downto 0); -- Effects frame (t_sec * 60 + t_frames) mod 256
		lm: std_logic_vector(4 * FX_LMOD_W - 1 downto 0); -- Light offsets of this frame
		kp: std_logic_vector(KEYPOS_BITS - 1 downto 0);
		bank: std_logic; -- Sprite RAM half the renderer reads
		cw: unsigned(6 downto 0); -- CRC word 0..90
		cb: unsigned(2 downto 0); -- CRC byte 0..7
		cword: std_logic_vector(63 downto 0);
		-- Pulses and output registers
		load_req: std_logic;
		loaded: std_logic;
		start: std_logic;
		cam_x_o: std_logic_vector(POS_BITS - 1 downto 0);
		cam_y_o: std_logic_vector(POS_BITS - 1 downto 0);
		angle_o: std_logic_vector(ANGLE_BITS - 1 downto 0);
		eye_o: std_logic_vector(EYE_BITS - 1 downto 0);
		doors_o: std_logic_vector(DOORS_BITS - 1 downto 0);
		player_x_o: std_logic_vector(POS_BITS - 1 downto 0);
		player_y_o: std_logic_vector(POS_BITS - 1 downto 0);
		hud_o: std_logic_vector(HUD_BITS - 1 downto 0);
		keypos_o: std_logic_vector(KEYPOS_BITS - 1 downto 0);
		music_o: std_logic_vector(1 downto 0);
		tint_o: std_logic_vector(1 downto 0);
		fx_o: std_logic_vector(FX_BITS - 1 downto 0);
		spr_count_o: std_logic_vector(5 downto 0);
		crc_o: std_logic_vector(31 downto 0);
		-- Stage 5 sound alert (Game.alert): queue head and tail (also the clear
		-- index afterwards), queue read address, current cell (y & x), neighbor
		-- 0..3 (+x, -x, +y, -y), neighbor cell, visited-RAM read address
		qhead: unsigned(12 downto 0);
		qtail: unsigned(12 downto 0);
		qra: unsigned(11 downto 0);
		cur: unsigned(11 downto 0);
		nk: unsigned(1 downto 0);
		ncell: unsigned(11 downto 0);
		vaddr: unsigned(11 downto 0);
	end record;

	constant REGS_INIT: regs_t := (
		st => S_INIT,
		wret => S_INIT,
		box_ret => S_INIT,
		los_ret => S_INIT,
		db_ret => S_INIT,
		snd_ret => S_INIT,
		dp_ret => S_INIT,
		en_ret => S_INIT,
		sp_ret => S_INIT,
		fat_ret => S_INIT,
		bfl_ret => S_INIT,
		armed => '0',
		pending => '0',
		snap_in => (others => '0'),
		snap => (others => '0'),
		in_step => '0',
		flow => FL_TITLE,
		level => "01",
		prev_fire => '0',
		debug => '0',
		pl => PLAYER_INIT,
		saved => PLAYER_INIT,
		px => (others => '0'),
		py => (others => '0'),
		angle => (others => '0'),
		eye => to_unsigned(32, 7),
		z => (others => '0'),
		vz => (others => '0'),
		off => (others => '0'),
		cam_x => (others => '0'),
		cam_y => (others => '0'),
		keys => (others => '0'),
		cooldown => (others => '0'),
		flash => (others => '0'),
		dflash => (others => '0'),
		pflash => (others => '0'),
		msg => (others => '0'),
		msg_timer => (others => '0'),
		phase => (others => '0'),
		kills => (others => '0'),
		items => (others => '0'),
		secrets => (others => '0'),
		tkills => (others => '0'),
		titems => (others => '0'),
		tsecrets => (others => '0'),
		t_frames => (others => '0'),
		t_sec => (others => '0'),
		t_min => (others => '0'),
		lfsr => (others => '0'),
		boss_timer => (others => '0'),
		level_done => '0',
		dead_timer => (others => '0'),
		automap => '0',
		on_toxic => '0',
		doors => (others => DOOR_CLEAR),
		cs => (others => '0'),
		sn => (others => '0'),
		mdx => (others => '0'),
		mdy => (others => '0'),
		my => '0',
		maddr => (others => '0'),
		bx => (others => '0'),
		by => (others => '0'),
		bsmall => '0',
		bk => (others => '0'),
		hit => '0',
		bz => (others => '0'),
		fpx => (others => '0'),
		fpy => (others => '0'),
		ff => (others => '0'),
		fs => (others => '0'),
		fat => (others => '0'),
		bfk => (others => '0'),
		bfl => (others => '0'),
		lx => (others => '0'),
		ly => (others => '0'),
		lx1 => (others => '0'),
		ly1 => (others => '0'),
		ldx => (others => '0'),
		ldy => (others => '0'),
		lsx => (others => '0'),
		lsy => (others => '0'),
		lerr => (others => '0'),
		lcnt => (others => '0'),
		los => '0',
		di => (others => '0'),
		blocked => '0',
		snd_id => (others => '0'),
		snd_act => '0',
		svol => (others => '0'),
		mul_a => (others => '0'),
		mul_b => (others => '0'),
		acc => (others => '0'),
		lat => (others => '0'),
		sq => (others => SND_CLEAR),
		sq_n => (others => '0'),
		oq => (others => SND_CLEAR),
		oq_n => (others => '0'),
		oq_p => (others => '0'),
		dmg => (others => '0'),
		a => ACTOR_CLEAR,
		ai => (others => '0'),
		aaddr => (others => '0'),
		en_s => (others => '0'),
		sp_type => (others => '0'),
		sp_state => (others => '0'),
		sp_health => (others => '0'),
		d => (others => '0'),
		csx => (others => '0'),
		csy => (others => '0'),
		hk => (others => '0'),
		hshot => '0',
		hdmg => (others => '0'),
		zw => (others => '0'),
		span_addr => (others => '0'),
		zw_addr => (others => '0'),
		best_v => '0',
		best_i => (others => '0'),
		best_z => (others => '0'),
		tp1 => '0',
		spr_n => (others => '0'),
		spr_e => (others => '0'),
		spr_ty => (others => '0'),
		fxn => (others => '0'),
		lm => (others => '0'),
		kp => (others => '0'),
		bank => '0',
		cw => (others => '0'),
		cb => (others => '0'),
		cword => (others => '0'),
		load_req => '0',
		loaded => '0',
		start => '0',
		cam_x_o => (others => '0'),
		cam_y_o => (others => '0'),
		angle_o => (others => '0'),
		eye_o => (others => '0'),
		doors_o => (others => '0'),
		player_x_o => (others => '0'),
		player_y_o => (others => '0'),
		hud_o => (others => '0'),
		keypos_o => (others => '0'),
		music_o => (others => '0'),
		tint_o => (others => '0'),
		fx_o => (others => '0'),
		spr_count_o => (others => '0'),
		crc_o => (others => '0'),
		qhead => (others => '0'),
		qtail => (others => '0'),
		qra => (others => '0'),
		cur => (others => '0'),
		nk => (others => '0'),
		ncell => (others => '0'),
		vaddr => (others => '0')
	);

	type actor_ram_t is array (0 to 31) of std_logic_vector(63 downto 0);
	-- Stage 5 alert flood fill: cells in visit order (block RAM) and visited bits
	-- (distributed RAM; BRAM is the scarcest resource of the full design)
	type cell_ram_t is array (0 to 4095) of std_logic_vector(11 downto 0);
	type vis_ram_t is array (0 to 4095) of std_logic;
	type spr_ram_t is array (0 to 63) of std_logic_vector(63 downto 0);

	signal r: regs_t := REGS_INIT;
	signal r_next: regs_t;
	signal rom_addr: unsigned(9 downto 0);
	signal rom_data: trig_t := (others => '0');
	signal prod: signed(41 downto 0) := (others => '0');
	signal aram: actor_ram_t := (others => (others => '0'));
	signal aram_q2: std_logic_vector(63 downto 0);
	signal aq: std_logic_vector(63 downto 0) := (others => '0'); -- Registered port 1 read
	signal hit_block, hit_pick, hit_door: std_logic := '0'; -- Scan tests of aq
	signal adist: unsigned(18 downto 0) := (others => '0'); -- Registered helpers of actor a
	signal atx, aty: signed(18 downto 0) := (others => '0');
	signal avol: unsigned(5 downto 0) := (others => '0');
	signal sdx, sdy: unsigned(13 downto 0) := (others => '0');
	signal sdist: unsigned(15 downto 0) := (others => '0');
	signal aram_we: std_logic := '0';
	signal aram_waddr: unsigned(4 downto 0) := (others => '0');
	signal aram_wdata: std_logic_vector(63 downto 0) := (others => '0');
	signal core_we: std_logic;
	signal alq: cell_ram_t;
	signal alq_q: std_logic_vector(11 downto 0) := (others => '0');
	signal al_qwe: std_logic;
	signal al_qwaddr: unsigned(11 downto 0);
	signal al_qwdata: std_logic_vector(11 downto 0);
	signal vis: vis_ram_t := (others => '0');
	signal vis_q: std_logic := '0';
	signal al_vwe: std_logic;
	signal al_vwaddr: unsigned(11 downto 0);
	signal al_vwdata: std_logic;
	attribute ram_style: string;
	attribute ram_style of vis: signal is "distributed";
	signal core_waddr: unsigned(4 downto 0);
	signal core_wdata: std_logic_vector(63 downto 0);
	signal sram: spr_ram_t := (others => (others => '0'));
	signal spr_we: std_logic;
	signal spr_waddr: unsigned(5 downto 0);
	signal spr_wdata: std_logic_vector(63 downto 0);
	signal spr_q: std_logic_vector(63 downto 0) := (others => '0');
	signal waddr: unsigned(6 downto 0); -- State word mux address
	signal word: std_logic_vector(63 downto 0);
	signal sdata: std_logic_vector(63 downto 0) := (others => '0');
	signal map_we: std_logic;
	signal crc_init, crc_valid: std_logic;
	signal crc_byte: std_logic_vector(7 downto 0);
	signal crc: std_logic_vector(31 downto 0);
	-- Door table entry of cell r.maddr (8: none) and whether that door is
	-- fully open, registered: every reader comes at least one clock after
	-- the address is set (S_WAIT), and the compare stays off the state decode
	signal didx: natural range 0 to 8 := 8;
	signal dopen: std_logic := '0';

	------------------------------------------------------------------
	-- Actor records and tables
	------------------------------------------------------------------
	function unpack(w: std_logic_vector(63 downto 0)) return actor_t is
		variable a: actor_t;
	begin
		a.x := unsigned(w(15 downto 0));
		a.y := unsigned(w(31 downto 16));
		a.state := unsigned(w(38 downto 32));
		a.timer := unsigned(w(44 downto 39));
		a.health := unsigned(w(56 downto 45));
		a.typ := unsigned(w(59 downto 57));
		a.active := w(60);
		a.solid := w(61);
		a.awake := w(62);
		a.ambush := w(63);
		return a;
	end function;

	function pack(a: actor_t) return std_logic_vector is
	begin
		return a.ambush & a.awake & a.solid & a.active & std_logic_vector(a.typ) &
			std_logic_vector(a.health) & std_logic_vector(a.timer) & std_logic_vector(a.state) &
			std_logic_vector(a.y) & std_logic_vector(a.x);
	end function;

	function st_frame(s: unsigned(6 downto 0)) return unsigned is
	begin
		return unsigned(STATE_TABLE(to_integer(s))(STATE_FRAME_HI downto STATE_FRAME_LO));
	end function;

	function st_dur(s: unsigned(6 downto 0)) return unsigned is
	begin
		return unsigned(STATE_TABLE(to_integer(s))(STATE_DUR_HI downto STATE_DUR_LO));
	end function;

	function st_act(s: unsigned(6 downto 0)) return natural is
	begin
		return to_integer(unsigned(STATE_TABLE(to_integer(s))(STATE_ACTION_HI downto STATE_ACTION_LO)));
	end function;

	function st_next(s: unsigned(6 downto 0)) return unsigned is
	begin
		return unsigned(STATE_TABLE(to_integer(s))(STATE_NEXT_HI downto STATE_NEXT_LO));
	end function;

	-- Monster type parameter (types 0..3; only monsters ever ask)
	function tp(typ: unsigned(2 downto 0); col: natural) return integer is
	begin
		return TYPE_TABLE(to_integer(typ(1 downto 0)))(col);
	end function;

	function tp_state(typ: unsigned(2 downto 0); col: natural) return unsigned is
	begin
		return to_unsigned(tp(typ, col), 7);
	end function;

	-- Random numbers: x^16 + x^15 + x^13 + x^4 + 1 (taps 15, 14, 12, 3 of
	-- the old state), shift left; random() returns the low byte of the new state
	function lfsr_next(s: unsigned(15 downto 0)) return unsigned is
	begin
		return s(14 downto 0) & (s(15) xor s(14) xor s(12) xor s(3));
	end function;

	------------------------------------------------------------------
	-- Map and doors
	------------------------------------------------------------------
	-- Door table entry for cell (y & x): index 0..7, or 8 when none is active
	function door_index(doors: doors_t; cell: unsigned(11 downto 0)) return natural is
	begin
		for i in 0 to 7 loop
			if ((doors(i).state /= DS_IDLE) and (doors(i).y & doors(i).x = cell)) then
				return i;
			end if;
		end loop;
		return 8;
	end function;

	-- First idle door table entry, or 8
	function first_idle(doors: doors_t) return natural is
	begin
		for i in 0 to 7 loop
			if (doors(i).state = DS_IDLE) then
				return i;
			end if;
		end loop;
		return 8;
	end function;

	-- Game.solid() of tile word t read from cell r.maddr: a wall unless it is
	-- a door (specials 1..3) whose table entry is fully open (dopen, the
	-- registered door match of r.maddr)
	function solid(t: std_logic_vector(23 downto 0); dopen: std_logic) return boolean is
		variable sp: natural range 0 to 7;
	begin
		if (unsigned(t(TILE_WALL_HI downto TILE_WALL_LO)) = 0) then
			return false;
		end if;
		sp := to_integer(unsigned(t(TILE_SPECIAL_HI downto TILE_SPECIAL_LO)));
		return not ((sp >= 1) and (sp <= 3) and (dopen = '1'));
	end function;

	-- Stage 4 tile heights: floor_h * 8 and 64 - ceil_h * 8 (units)
	function floor_h(t: std_logic_vector(23 downto 0)) return unsigned is
	begin
		return unsigned(t(TILE_FLOORH_HI downto TILE_FLOORH_LO)) & "000";
	end function;

	function ceil_h(t: std_logic_vector(23 downto 0)) return unsigned is
	begin
		return to_unsigned(64, 7) - (unsigned(t(TILE_CEILH_HI downto TILE_CEILH_LO)) & "000");
	end function;

	function is_ramp(t: std_logic_vector(23 downto 0)) return boolean is
	begin
		return unsigned(t(TILE_SPECIAL_HI downto TILE_SPECIAL_LO)) = SPECIAL_RAMP;
	end function;

	-- Game.blocks() without the solid test: a step up of more than
	-- STEP_MAX (ramps never) or less headroom than BODY_H for a body at z
	function height_blocks(t: std_logic_vector(23 downto 0); z: unsigned(7 downto 0)) return boolean is
		variable f, top: unsigned(8 downto 0);
	begin
		f := resize(floor_h(t), 9);
		if ((not is_ramp(t)) and (f > resize(z, 9) + STEP_MAX)) then
			return true;
		end if;
		if (f > resize(z, 9)) then
			top := f + BODY_H;
		else
			top := resize(z, 9) + BODY_H;
		end if;
		return resize(ceil_h(t), 9) < top;
	end function;

	-- Cell (y & x) of a Q6.16 point, masked to the map like Game.tile()
	function point_cell(x: pos_t; y: pos_t) return unsigned is
	begin
		return unsigned(std_logic_vector(y(21 downto 16))) & unsigned(std_logic_vector(x(21 downto 16)));
	end function;

	-- Cell (y & x) of box corner k around (bx, by): bits 21:16 of b -/+ half
	-- are (b +/- half) >> 16 masked to 0..63 (Game.tile() masks the same way)
	function box_cell(bx: pos_t; by: pos_t; small: std_logic; k: unsigned(1 downto 0)) return unsigned is
		variable h: integer;
		variable cx, cy: pos_t;
	begin
		if (small = '1') then
			h := CAM_HALF;
		else
			h := HALF;
		end if;
		if (k(0) = '0') then
			cx := bx - h;
		else
			cx := bx + h;
		end if;
		if (k(1) = '0') then
			cy := by - h;
		else
			cy := by + h;
		end if;
		return unsigned(std_logic_vector(cy(21 downto 16))) & unsigned(std_logic_vector(cx(21 downto 16)));
	end function;

	-- Game.in_cell() with half size HALF: one of the 2 x 2 cells of the box
	-- at (x, y) is (cx, cy). Unmasked, as the model: bits 23:16 of x -/+ HALF
	-- (a box past the map edge gives -1 or 64, which matches no door)
	function in_cell(x: pos_t; y: pos_t; cx: unsigned(5 downto 0); cy: unsigned(5 downto 0)) return boolean is
		variable x0, x1, y0, y1: pos_t;
	begin
		x0 := x - HALF;
		x1 := x + HALF;
		y0 := y - HALF;
		y1 := y + HALF;
		return ((unsigned(x0(23 downto 16)) = "00" & cx) or (unsigned(x1(23 downto 16)) = "00" & cx)) and
			((unsigned(y0(23 downto 16)) = "00" & cy) or (unsigned(y1(23 downto 16)) = "00" & cy));
	end function;

	------------------------------------------------------------------
	-- Arithmetic helpers
	------------------------------------------------------------------
	-- Actor coordinate (Q6.10) in Q6.16
	function q16(v: unsigned(15 downto 0)) return pos_t is
	begin
		return signed(unsigned'("00" & v & "000000")); -- v << 6, two zero headroom bits on top
	end function;

	-- |v| as unsigned (v never reaches the most negative value here)
	function absu(v: signed) return unsigned is
	begin
		return unsigned(abs(v));
	end function;

	-- Game.dist(): |(px >> 6) - a.x| + |(py >> 6) - a.y|, Q6.10
	function dist(px: pos_t; py: pos_t; ax: unsigned(15 downto 0); ay: unsigned(15 downto 0)) return unsigned is
		variable dx, dy: signed(18 downto 0);
	begin
		dx := resize(px(23 downto 6), 19) - signed(resize(ax, 19));
		dy := resize(py(23 downto 6), 19) - signed(resize(ay, 19));
		return absu(dx) + absu(dy);
	end function;

	-- move * c for move in -2..1 (2-bit signed snapshot field)
	function times(m: std_logic_vector(1 downto 0); c: trig_t) return signed is
	begin
		case m is
			when "01" =>
				return resize(c, 20);
			when "11" =>
				return -resize(c, 20);
			when "10" =>
				return -shift_left(resize(c, 20), 1);
			when others =>
				return to_signed(0, 20);
		end case;
	end function;

	-- k * c for the small constants of the damage rolls (c = 0 .. 5)
	function times_const(k: unsigned(3 downto 0); c: natural) return unsigned is
		variable x: unsigned(5 downto 0);
	begin
		x := resize(k, 6);
		case c is
			when 1 =>
				return x;
			when 3 =>
				return shift_left(x, 1) + x;
			when 4 =>
				return shift_left(x, 2);
			when 5 =>
				return shift_left(x, 2) + x;
			when others =>
				return to_unsigned(0, 6);
		end case;
	end function;

	-- actors.direction16(): direction 0..15 toward (dx, dy), compares of
	-- small multiples only (5 ay < ax, 3 ay < 2 ax, 2 ay < 3 ax, ay < 5 ax)
	function direction16(dx: signed(18 downto 0); dy: signed(18 downto 0)) return unsigned is
		variable ax, ay: unsigned(21 downto 0);
		variable sub: unsigned(3 downto 0);
	begin
		ax := resize(absu(dx), 22);
		ay := resize(absu(dy), 22);
		if (shift_left(ay, 2) + ay < ax) then
			sub := to_unsigned(0, 4);
		elsif (shift_left(ay, 1) + ay < shift_left(ax, 1)) then
			sub := to_unsigned(1, 4);
		elsif (shift_left(ay, 1) < shift_left(ax, 1) + ax) then
			sub := to_unsigned(2, 4);
		elsif (ay < shift_left(ax, 2) + ax) then
			sub := to_unsigned(3, 4);
		else
			sub := to_unsigned(4, 4);
		end if;
		if ((dx >= 0) and (dy >= 0)) then
			return sub;
		elsif ((dx < 0) and (dy >= 0)) then
			return 8 - sub;
		elsif ((dx < 0) and (dy < 0)) then
			return 8 + sub;
		else
			return 0 - sub; -- (16 - sub) & 15
		end if;
	end function;

	-- Sound distance of actor (ax, ay) from the player: d = dx + dy -
	-- min / 2 in 1/64 tiles (dx, dy = |difference| >> 10 in Q.16)
	function snd_axis(p: pos_t; a: unsigned(15 downto 0)) return unsigned is
	begin
		return resize(shift_right(absu(q16(a) - p), 10), 14);
	end function;

	function snd_dist(dx: unsigned(13 downto 0); dy: unsigned(13 downto 0)) return unsigned is
		variable mn: unsigned(13 downto 0);
	begin
		if (dx < dy) then
			mn := dx;
		else
			mn := dy;
		end if;
		return resize(dx, 16) + dy - shift_right(mn, 1);
	end function;

	-- Sound volume at distance d: 63 up to 200, 0 from 1200,
	-- ((1200 - d) * 65) >> 10 in between (65 = 64 + 1)
	function volume(d: unsigned(15 downto 0)) return unsigned is
		variable t: unsigned(10 downto 0);
		variable p: unsigned(17 downto 0);
	begin
		if (d <= 200) then
			return to_unsigned(63, 6);
		elsif (d >= 1200) then
			return to_unsigned(0, 6);
		end if;
		t := resize(1200 - d, 11);
		p := shift_left(resize(t, 18), 6) + t;
		if (p(17 downto 10) > 63) then -- min(63, ...) as the model
			return to_unsigned(63, 6);
		end if;
		return p(15 downto 10);
	end function;

	function bit_of(b: boolean) return std_logic is
	begin
		if (b) then
			return '1';
		end if;
		return '0';
	end function;

	-- Flicker of effects frame n (render.light_mods): ((n * 40503) >> 7) & 7 < 3, as a
	-- 256 x 1 constant table so the multiply never reaches the logic
	type flick_t is array (0 to 255) of std_logic;
	function make_flick return flick_t is
		variable t: flick_t;
	begin
		for n in 0 to 255 loop
			if (((n * 40503) / 128) mod 8 < 3) then
				t(n) := '1';
			else
				t(n) := '0';
			end if;
		end loop;
		return t;
	end function;
	constant FLICK: flick_t := make_flick;

	-- Light offsets of the four light types for effects frame n (render.light_mods):
	-- steady 0, flicker -5 when FLICK(n), strobe -8 when n(4), glow -(triangle(n mod 32) / 2);
	-- the muzzle flash adds 2 to all four. Packed as 5-bit signed, type k at 5k + 4 .. 5k
	function light_mods(n: unsigned(7 downto 0); flash: boolean) return std_logic_vector is
		variable f, m: integer;
		variable g, tri: natural;
		variable o: std_logic_vector(4 * FX_LMOD_W - 1 downto 0);
	begin
		if (flash) then
			f := 2;
		else
			f := 0;
		end if;
		g := to_integer(n(4 downto 0));
		if (g < 16) then
			tri := g;
		else
			tri := 31 - g;
		end if;
		for k in 0 to 3 loop
			m := f;
			if ((k = 1) and (FLICK(to_integer(n)) = '1')) then
				m := f - 5;
			elsif ((k = 2) and (n(4) = '1')) then
				m := f - 8;
			elsif (k = 3) then
				m := f - tri / 2;
			end if;
			o(FX_LMOD_W * k + FX_LMOD_W - 1 downto FX_LMOD_W * k) := std_logic_vector(to_signed(m, FX_LMOD_W));
		end loop;
		return o;
	end function;

	-- Sprite light: clamp(tile light + offset of the tile's light type, 0, 15)
	function mod_light(l: std_logic_vector(3 downto 0); lm: std_logic_vector; ty: std_logic_vector(1 downto 0))
		return std_logic_vector is
		variable k: natural;
		variable v: integer;
	begin
		k := to_integer(unsigned(ty));
		v := to_integer(unsigned(l)) + to_integer(signed(lm(lm'low + FX_LMOD_W * k + FX_LMOD_W - 1 downto lm'low + FX_LMOD_W * k)));
		if (v < 0) then
			v := 0;
		elsif (v > 15) then
			v := 15;
		end if;
		return std_logic_vector(to_unsigned(v, 4));
	end function;
begin
	------------------------------------------------------------------
	-- Sine ROM (cos(a) = sin(a + 256)), registered read
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			rom_data <= to_signed(SIN_TABLE(to_integer(rom_addr)), 18);
		end if;
	end process;

	------------------------------------------------------------------
	-- Shared multiplier (one DSP48): product of last clock's operands
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			prod <= r.mul_a * r.mul_b;
		end if;
	end process;

	------------------------------------------------------------------
	-- Actor table, 32 x 64 LUT RAM. One write port (the loader owns it
	-- while the core waits for a load), registered one clock (timing:
	-- the write enable is decided late in the clock). Every core read
	-- takes the S_WAIT clock after its address is set, so a read never
	-- comes before a write that was decided earlier. Reads: port 1 at
	-- r.aaddr for the core, port 2 for the state words
	------------------------------------------------------------------
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			aram_we <= '0';
		elsif rising_edge(clk_i) then
			if (r.st = S_LOAD_W) then
				aram_we <= act_we_i;
				aram_waddr <= unsigned(act_addr_i);
				aram_wdata <= act_data_i;
			else
				aram_we <= core_we;
				aram_waddr <= core_waddr;
				aram_wdata <= core_wdata;
			end if;
		end if;
	end process;

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (aram_we = '1') then
				aram(to_integer(aram_waddr)) <= aram_wdata;
			end if;
		end if;
	end process;

	-- Port 1 is registered: data of r.aaddr one clock later (after S_WAIT)
	-- The three scan tests are registered with it (r.px, r.py, r.bx, r.by
	-- and r.di do not change during a scan): actor blocks the move box,
	-- item under the player, actor in door di's cell
	process(clk_i)
		variable w: actor_t;
		variable dd: door_t;
	begin
		if rising_edge(clk_i) then
			w := unpack(aram(to_integer(r.aaddr)));
			dd := r.doors(to_integer(r.di));
			aq <= aram(to_integer(r.aaddr));
			hit_block <= w.active and w.solid and bit_of((absu(q16(w.x) - r.bx) < BLOCK_RANGE) and
				(absu(q16(w.y) - r.by) < BLOCK_RANGE));
			hit_pick <= w.active and bit_of((w.typ = T_ITEM) and (absu(q16(w.x) - r.px) < PICK_RANGE) and
				(absu(q16(w.y) - r.py) < PICK_RANGE));
			hit_door <= w.active and w.solid and bit_of(in_cell(q16(w.x), q16(w.y), dd.x, dd.y));
		end if;
	end process;
	aram_q2 <= aram(to_integer(waddr(4 downto 0) - 27)); -- Word 59 + j is actor j (59 = 27 mod 32)

	-- Alert queue and visited bits: write in the clock of the state that
	-- asks, read one clock after the address register (like the map)
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (al_qwe = '1') then
				alq(to_integer(al_qwaddr)) <= al_qwdata;
			end if;
			alq_q <= alq(to_integer(r.qra));
		end if;
	end process;

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (al_vwe = '1') then
				vis(to_integer(al_vwaddr)) <= al_vwdata;
			end if;
			vis_q <= vis(to_integer(r.vaddr));
		end if;
	end process;

	process(clk_i)
		variable i: natural range 0 to 8;
	begin
		if rising_edge(clk_i) then
			i := door_index(r.doors, r.maddr);
			didx <= i;
			dopen <= bit_of((i < 8) and (r.doors(i mod 8).open_amt = DOOR_OPEN));
		end if;
	end process;

	------------------------------------------------------------------
	-- Helpers of the working actor a, one clock behind r (timing: they
	-- keep the distance arithmetic off the state decode). Every user is
	-- at least one clock after the last change of a.x, a.y, px or py:
	-- dist(a), (px >> 6) - a.x, (py >> 6) - a.y; the sound volume takes
	-- three clocks (axis distances, distance, volume), S_SND waits two
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			adist <= dist(r.px, r.py, r.a.x, r.a.y);
			atx <= resize(r.px(23 downto 6), 19) - signed(resize(r.a.x, 19));
			aty <= resize(r.py(23 downto 6), 19) - signed(resize(r.a.y, 19));
			sdx <= snd_axis(r.px, r.a.x);
			sdy <= snd_axis(r.py, r.a.y);
			sdist <= snd_dist(sdx, sdy);
			avol <= volume(sdist);
		end if;
	end process;

	------------------------------------------------------------------
	-- Sprite table, 2 x 32 entries: the core fills half (not r.bank)
	-- during the step, the renderer reads half r.bank; they swap at
	-- render_start_o
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (spr_we = '1') then
				sram(to_integer(spr_waddr)) <= spr_wdata;
			end if;
			spr_q <= sram(to_integer(unsigned(r.bank & spr_addr_i))); -- Address bit 5 picks the half
		end if;
	end process;

	------------------------------------------------------------------
	-- State words (game.state_words()): the CRC walk reads them in
	-- S_CRC_W, the read-out port at other times
	------------------------------------------------------------------
	waddr <= r.cw when (r.st = S_CRC_W) else unsigned(state_addr_i);

	process(r, waddr, aram_q2)
		variable k: natural range 0 to 127;
		variable w: unsigned(63 downto 0);
		variable dw: natural range 0 to 39;
		variable d: door_t;
	begin
		k := to_integer(waddr);
		w := (others => '0');
		case k is
			when 0 =>
				w(2 downto 0) := r.flow;
			when 1 =>
				w(1 downto 0) := r.level;
			when 2 =>
				w(21 downto 0) := unsigned(r.px(21 downto 0));
			when 3 =>
				w(21 downto 0) := unsigned(r.py(21 downto 0));
			when 4 =>
				w(9 downto 0) := r.angle;
			when 5 =>
				-- eye | z << 8 | vz << 16 (z and vz are 0 on flat levels)
				w(6 downto 0) := r.eye;
				w(15 downto 8) := r.z;
				w(20 downto 16) := r.vz;
			when 6 =>
				w(7 downto 0) := unsigned(resize(r.off, 8)); -- off & 0xFF
			when 7 =>
				w(7 downto 0) := r.pl.health;
			when 8 =>
				w(7 downto 0) := r.pl.armor;
			when 9 =>
				w(7 downto 0) := r.pl.bullets;
			when 10 =>
				w(5 downto 0) := r.pl.shells;
			when 11 =>
				w(1 downto 0) := r.pl.weapons;
			when 12 =>
				w(1 downto 0) := r.pl.weapon;
			when 13 =>
				w(1 downto 0) := r.keys;
			when 14 =>
				w(5 downto 0) := r.cooldown;
			when 15 =>
				w(5 downto 0) := r.kills;
			when 16 =>
				w(5 downto 0) := r.items;
			when 17 =>
				w(3 downto 0) := r.secrets;
			when 18 =>
				w(15 downto 0) := r.lfsr;
			when 19 to 58 =>
				-- Doors: 5 words each (x, y, open, state, timer)
				dw := k - 19;
				d := r.doors(dw / 5);
				case dw mod 5 is
					when 0 =>
						w(5 downto 0) := d.x;
					when 1 =>
						w(5 downto 0) := d.y;
					when 2 =>
						w(7 downto 0) := unsigned(d.open_amt);
					when 3 =>
						w(1 downto 0) := d.state;
					when others =>
						w(7 downto 0) := d.timer;
				end case;
			when 59 to 90 =>
				w := unsigned(aram_q2);
			when others =>
				null;
		end case;
		word <= std_logic_vector(w);
	end process;

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			sdata <= word;
		end if;
	end process;

	crc_unit: core_crc
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			init_i => crc_init,
			valid_i => crc_valid,
			data_i => crc_byte,
			crc_o => crc
		);

	------------------------------------------------------------------
	-- Next state
	------------------------------------------------------------------
	process(r, frame_start_i, snapshot_i, snapshot_valid_i, load_done_i, start_x_i, start_y_i,
		start_angle_i, map_data_i, span_data_i, span_count_i, zwall_data_i, snd_ready_i,
		rom_data, prod, aq, hit_block, hit_pick, hit_door, adist, atx, aty, avol, word, crc,
		didx, dopen, alq_q, vis_q)
		variable v: regs_t;
		variable q: actor_t;
		variable s: std_logic_vector(SNAP_BITS - 1 downto 0);
		variable go, fire: std_logic;
		variable rnd: unsigned(15 downto 0);
		variable turn: signed(11 downto 0);
		variable vx, vy: signed(19 downto 0);
		variable mv: pos_t;
		variable edge: pos_t;
		variable t3: signed(19 downto 0);
		variable ux, uy: pos_t;
		variable i, j: natural range 0 to 8;
		variable dd: door_t;
		variable sp: natural range 0 to 7;
		variable kind: natural range 0 to 7;
		variable took: boolean;
		variable dist_v: unsigned(18 downto 0);
		variable dmg: unsigned(5 downto 0);
		variable saved: unsigned(9 downto 0);
		variable hp: signed(12 downto 0);
		variable e2: signed(8 downto 0);
		variable nx, ny: signed(7 downto 0);
		variable nerr: signed(8 downto 0);
		variable tx, ty: signed(18 downto 0);
		variable spd: integer;
		variable ax, ay: unsigned(15 downto 0);
		variable sum: signed(42 downto 0);
		variable lat: signed(15 downto 0);
		variable x0, x1, z: unsigned(15 downto 0);
		variable col: unsigned(8 downto 0);
		variable frame: unsigned(7 downto 0);
		variable dv: unsigned(5 downto 0);
		variable alx, aly: unsigned(5 downto 0);
		variable alc: unsigned(11 downto 0);
		variable base: natural;
		variable eye_t: unsigned(6 downto 0);
		variable peek: signed(5 downto 0);
		variable bob: natural range 0 to 4;
		variable was_awake: std_logic;
		variable dvz: unsigned(4 downto 0);
		variable ft: std_logic_vector(23 downto 0);
		variable dir: natural range 0 to 3;
		variable frac: unsigned(15 downto 0);
		variable rise: signed(8 downto 0);
		variable fsum: signed(9 downto 0);
	begin
		v := r;
		v.load_req := '0';
		v.loaded := '0';
		v.start := '0';
		s := r.snap;
		rom_addr <= r.angle;
		core_we <= '0';
		core_waddr <= r.ai;
		core_wdata <= pack(r.a);
		al_qwe <= '0';
		al_qwaddr <= r.qtail(11 downto 0);
		al_qwdata <= std_logic_vector(r.ncell);
		al_vwe <= '0';
		al_vwaddr <= r.ncell;
		al_vwdata <= '1';
		spr_we <= '0';
		spr_waddr <= (not r.bank) & r.spr_n(4 downto 0); -- The half the renderer is not reading
		spr_wdata <= r.spr_e;
		map_we <= '0';
		crc_init <= '0';
		crc_valid <= '0';
		crc_byte <= r.cword(7 downto 0);
		q := unpack(aq);

		-- Snapshot capture (any state): the step after a frame start
		if (frame_start_i = '1') then
			v.armed := '1';
		end if;
		if ((snapshot_valid_i = '1') and ((r.armed = '1') or (frame_start_i = '1'))) then
			v.snap_in := snapshot_i;
			v.pending := '1';
			v.armed := '0';
		end if;

		-- Sound commands of the last step go out one per handshake
		if ((r.oq_p /= r.oq_n) and (snd_ready_i = '1')) then
			v.oq_p := r.oq_p + 1;
		end if;

		case r.st is
			--------------------------------------------------------------
			-- Level load: request, wait (the loader writes the actor
			-- RAM meanwhile), reset_level_state(), totals
			--------------------------------------------------------------
			when S_INIT =>
				-- Game.__init__ loads level 1 (and stays on TITLE)
				v.in_step := '0';
				v.st := S_LOAD;

			when S_LOAD =>
				v.load_req := '1';
				v.st := S_LOAD_W;

			when S_LOAD_W =>
				if (load_done_i = '1') then
					v.px := signed(resize(unsigned(start_x_i), 24));
					v.py := signed(resize(unsigned(start_y_i), 24));
					v.angle := unsigned(start_angle_i);
					v.eye := to_unsigned(32, 7);
					v.off := (others => '0');
					v.cam_x := v.px;
					v.cam_y := v.py;
					v.keys := (others => '0');
					v.cooldown := (others => '0');
					v.flash := (others => '0');
					v.dflash := (others => '0');
					v.pflash := (others => '0');
					v.msg := (others => '0');
					v.msg_timer := (others => '0');
					v.phase := (others => '0');
					v.kills := (others => '0');
					v.items := (others => '0');
					v.secrets := (others => '0');
					v.tkills := (others => '0');
					v.titems := (others => '0');
					v.tsecrets := (others => '0');
					v.t_frames := (others => '0');
					v.t_sec := (others => '0');
					v.t_min := (others => '0');
					v.lfsr := x"ACE1" xor ("000000" & r.level & x"00"); -- Seed 0xACE1 ^ (level << 8)
					v.boss_timer := (others => '0');
					v.level_done := '0';
					v.dead_timer := (others => '0');
					v.automap := '0';
					v.doors := (others => DOOR_CLEAR);
					v.aaddr := (others => '0');
					v.wret := S_TOTA;
					v.st := S_WAIT;
				end if;

			when S_TOTA =>
				-- Monsters (types 0..3) and items among the active actors
				if (q.active = '1') then
					if (q.typ < 4) then
						v.tkills := r.tkills + 1;
					elsif (q.typ = T_ITEM) then
						v.titems := r.titems + 1;
					end if;
				end if;
				if (r.aaddr = 31) then
					v.st := S_TOT0;
				else
					v.aaddr := r.aaddr + 1;
					v.wret := S_TOTA;
					v.st := S_WAIT;
				end if;

			when S_TOT0 =>
				v.maddr := (others => '0');
				v.tp1 := '0';
				v.st := S_TOT;

			when S_TOT =>
				-- Secret tiles: one address per clock; map_data_i is the
				-- tile of the address one clock earlier (tp1 marks it valid)
				if ((r.tp1 = '1') and (unsigned(map_data_i(TILE_SPECIAL_HI downto TILE_SPECIAL_LO)) = SPECIAL_PUSHWALL)) then
					v.tsecrets := r.tsecrets + 1;
				end if;
				v.tp1 := '1';
				v.maddr := r.maddr + 1;
				if (r.maddr = 4095) then
					v.maddr := r.maddr;
					v.st := S_TOT_LAST;
				end if;

			when S_TOT_LAST =>
				if (unsigned(map_data_i(TILE_SPECIAL_HI downto TILE_SPECIAL_LO)) = SPECIAL_PUSHWALL) then
					v.tsecrets := r.tsecrets + 1;
				end if;
				v.tp1 := '0';
				-- z = box_floor(start), vz = 0 (Game.reset_level_state)
				v.bx := r.px;
				v.by := r.py;
				v.bfl_ret := S_LOAD_Z;
				v.st := S_BFL;

			when S_LOAD_Z =>
				v.z := r.bfl;
				v.vz := (others => '0');
				v.loaded := '1';
				if (r.in_step = '1') then
					v.st := S_END;
				else
					v.st := S_IDLE;
				end if;

			--------------------------------------------------------------
			-- Frame start and game flow (Game.step)
			--------------------------------------------------------------
			when S_IDLE =>
				if (r.pending = '1') then
					v.snap := r.snap_in;
					v.pending := '0';
					v.st := S_STEP;
				end if;

			when S_STEP =>
				v.sq_n := (others => '0');
				fire := s(SNAP_FIRE);
				go := s(SNAP_USE) or (fire and not r.prev_fire); -- Use, or fire newly pressed (not held)
				v.prev_fire := fire;
				if (s(SNAP_DEBUG) = '1') then
					v.debug := not r.debug;
				end if;
				v.in_step := '1';
				v.st := S_END;
				case r.flow is
					when FL_TITLE =>
						if (go = '1') then
							v.pl := PLAYER_INIT;
							v.level := "01";
							v.flow := FL_BRIEFING;
						end if;
					when FL_BRIEFING =>
						if (go = '1') then
							v.saved := r.pl;
							v.flow := FL_PLAYING;
							v.st := S_LOAD;
						end if;
					when FL_PAUSED =>
						if (s(SNAP_MENU) = '1') then
							v.flow := FL_PLAYING;
						end if;
					when FL_DEAD =>
						if (r.dead_timer /= 63) then
							v.dead_timer := r.dead_timer + 1;
						end if;
						if (r.eye > 8) then
							v.eye := r.eye - 2;
						end if;
						if ((v.dead_timer > 30) and (go = '1')) then
							v.pl := r.saved;
							v.flow := FL_PLAYING;
							v.st := S_LOAD;
						end if;
					when FL_SCORE =>
						if (go = '1') then
							if (r.level < LEVELS) then
								v.level := r.level + 1;
								v.flow := FL_BRIEFING;
							else
								v.flow := FL_ENDING;
							end if;
						end if;
					when FL_ENDING =>
						if (go = '1') then
							v.flow := FL_TITLE;
						end if;
					when others =>
						-- PLAYING
						if (s(SNAP_MENU) = '1') then
							v.flow := FL_PAUSED;
						else
							v.st := S_PLAY;
						end if;
				end case;

			--------------------------------------------------------------
			-- 1. Level clock, turn, duck and peek easing, automap
			--------------------------------------------------------------
			when S_PLAY =>
				if (r.t_frames = 59) then
					v.t_frames := (others => '0');
					if (r.t_sec = 59) then
						v.t_sec := (others => '0');
						if (r.t_min /= 99) then -- The level clock stops at 99 minutes
							v.t_min := r.t_min + 1;
						end if;
					else
						v.t_sec := r.t_sec + 1;
					end if;
				else
					v.t_frames := r.t_frames + 1;
				end if;
				-- Adding the low 10 bits of the signed turn is mod 1024
				turn := signed(s(SNAP_TURN_HI downto SNAP_TURN_LO));
				v.angle := r.angle + unsigned(std_logic_vector(turn(9 downto 0)));
				if (s(SNAP_DUCK) = '1') then
					eye_t := to_unsigned(16, 7);
				else
					eye_t := to_unsigned(32, 7);
				end if;
				if (r.eye < eye_t) then
					v.eye := r.eye + 2;
				elsif (r.eye > eye_t) then
					v.eye := r.eye - 2;
				end if;
				peek := (others => '0');
				if ((s(SNAP_PEEK_R) = '1') and (s(SNAP_PEEK_L) = '0')) then
					peek := to_signed(16, 6);
				elsif ((s(SNAP_PEEK_R) = '0') and (s(SNAP_PEEK_L) = '1')) then
					peek := to_signed(-16, 6);
				end if;
				if (r.off < peek) then
					v.off := r.off + 2;
				elsif (r.off > peek) then
					v.off := r.off - 2;
				end if;
				if (s(SNAP_AUTOMAP) = '1') then
					v.automap := not r.automap;
				end if;
				v.st := S_P_SIN;

			when S_P_SIN =>
				-- rom_addr = angle (default), sin arrives in S_P_COS
				v.st := S_P_COS;

			when S_P_COS =>
				rom_addr <= r.angle + 256; -- cos arrives in S_P_VEL
				v.sn := rom_data;
				v.st := S_P_VEL;

			when S_P_VEL =>
				-- vx = move cs - strafe sn, vy = move sn + strafe cs, then
				-- >> 3 running or >> 4 walking, one more when ducking
				v.cs := rom_data;
				vx := times(s(SNAP_MOVE_HI downto SNAP_MOVE_LO), rom_data) -
					times(s(SNAP_STRAFE_HI downto SNAP_STRAFE_LO), r.sn);
				vy := times(s(SNAP_MOVE_HI downto SNAP_MOVE_LO), r.sn) +
					times(s(SNAP_STRAFE_HI downto SNAP_STRAFE_LO), rom_data);
				if ((s(SNAP_RUN) = '1') and (s(SNAP_DUCK) = '0')) then
					v.mdx := resize(shift_right(vx, 3), 24);
					v.mdy := resize(shift_right(vy, 3), 24);
				elsif ((s(SNAP_RUN) = '1') or (s(SNAP_DUCK) = '0')) then
					v.mdx := resize(shift_right(vx, 4), 24);
					v.mdy := resize(shift_right(vy, 4), 24);
				else
					v.mdx := resize(shift_right(vx, 5), 24);
					v.mdy := resize(shift_right(vy, 5), 24);
				end if;
				v.my := '0';
				v.st := S_MOVE;

			--------------------------------------------------------------
			-- 2. Move x, then y (Game.move_x, move_y)
			--------------------------------------------------------------
			when S_MOVE =>
				if (r.my = '0') then
					mv := r.mdx;
					v.bx := r.px + r.mdx;
					v.by := r.py;
				else
					mv := r.mdy;
					v.bx := r.px;
					v.by := r.py + r.mdy;
				end if;
				if (mv = 0) then
					v.st := S_MOVE_NEXT;
				else
					v.bsmall := '0';
					v.bz := r.z;
					v.box_ret := S_MOVE_BOX;
					v.st := S_BOX;
				end if;

			when S_MOVE_BOX =>
				if (r.hit = '1') then
					-- Flush against the cell the box ran into
					if (r.my = '0') then
						if (r.mdx > 0) then
							edge := ((r.bx + HALF) and x"FF0000") - HALF - 1; -- Right side 1 short of the cell
							if (edge > r.px) then
								v.px := edge;
							end if;
						else
							edge := ((r.bx - HALF) and x"FF0000") + 65536 + HALF; -- Left side on its right edge
							if (edge < r.px) then
								v.px := edge;
							end if;
						end if;
					else
						if (r.mdy > 0) then
							edge := ((r.by + HALF) and x"FF0000") - HALF - 1;
							if (edge > r.py) then
								v.py := edge;
							end if;
						else
							edge := ((r.by - HALF) and x"FF0000") + 65536 + HALF;
							if (edge < r.py) then
								v.py := edge;
							end if;
						end if;
					end if;
					v.st := S_MOVE_NEXT;
				else
					v.aaddr := (others => '0');
					v.wret := S_AB;
					v.st := S_WAIT;
				end if;

			when S_AB =>
				-- Game.actor_blocks(): one actor per clock
				if (hit_block = '1') then
					v.st := S_MOVE_NEXT;
				elsif (r.aaddr = 31) then
					if (r.my = '0') then
						v.px := r.bx;
					else
						v.py := r.by;
					end if;
					v.st := S_MOVE_NEXT;
				else
					v.aaddr := r.aaddr + 1;
					v.wret := S_AB;
					v.st := S_WAIT;
				end if;

			when S_MOVE_NEXT =>
				if (r.my = '0') then
					v.my := '1';
					v.st := S_MOVE;
				else
					if ((s(SNAP_MOVE_HI downto SNAP_MOVE_LO) /= "00") or
						(s(SNAP_STRAFE_HI downto SNAP_STRAFE_LO) /= "00")) then
						v.phase := r.phase + 1;
					end if;
					v.st := S_ZF;
				end if;

			--------------------------------------------------------------
			-- Floor contact (stage 4): step up at once, fall with gravity
			--------------------------------------------------------------
			when S_ZF =>
				v.bx := r.px;
				v.by := r.py;
				v.bfl_ret := S_ZF2;
				v.st := S_BFL;

			when S_ZF2 =>
				if (r.z > r.bfl) then
					if (r.vz + FALL_ACC > FALL_MAX) then
						dvz := to_unsigned(FALL_MAX, 5);
					else
						dvz := r.vz + FALL_ACC;
					end if;
					if (r.z - r.bfl <= dvz) then
						v.z := r.bfl;
						v.vz := (others => '0');
					else
						v.z := r.z - dvz;
						v.vz := dvz;
					end if;
				else
					v.z := r.bfl;
					v.vz := (others => '0');
				end if;
				v.st := S_PEEK;

			--------------------------------------------------------------
			-- 3. Peek camera: (px + (-sn off >> 6), py + (cs off >> 6));
			-- the offset shrinks by 2 until the camera box is free
			--------------------------------------------------------------
			when S_PEEK =>
				if (r.off = 0) then
					v.cam_x := r.px;
					v.cam_y := r.py;
					v.st := S_PICK;
				else
					v.mul_a := resize(r.off, 24);
					v.mul_b := -r.sn;
					v.st := S_PEEK_M1;
				end if;

			when S_PEEK_M1 =>
				v.mul_b := r.cs;
				v.st := S_PEEK_M2;

			when S_PEEK_M2 =>
				v.acc := prod; -- -sn * off
				v.st := S_PEEK_M3;

			when S_PEEK_M3 =>
				v.bx := r.px + resize(shift_right(r.acc, 6), 24);
				v.by := r.py + resize(shift_right(prod, 6), 24); -- cs * off
				v.bsmall := '1';
				v.box_ret := S_PEEK2;
				v.st := S_BOX;

			when S_PEEK2 =>
				if (r.hit = '0') then
					v.cam_x := r.bx;
					v.cam_y := r.by;
					v.st := S_PICK;
				else
					if (r.off > 0) then
						v.off := r.off - 2;
					else
						v.off := r.off + 2;
					end if;
					v.st := S_PEEK;
				end if;

			--------------------------------------------------------------
			-- 4. Pickups in actor order, then the floor under the player
			--------------------------------------------------------------
			when S_PICK =>
				v.aaddr := (others => '0');
				v.wret := S_PICK_T;
				v.st := S_WAIT;

			when S_PICK_T =>
				v.st := S_PICK_N;
				if (hit_pick = '1') then
					kind := to_integer(q.health(2 downto 0));
					took := true;
					case kind is
						when 0 =>
							took := r.pl.health < 100;
							if (r.pl.health < 90) then
								v.pl.health := r.pl.health + 10;
							else
								v.pl.health := to_unsigned(100, 8);
							end if;
						when 1 =>
							took := r.pl.health < 100;
							if (r.pl.health < 75) then
								v.pl.health := r.pl.health + 25;
							else
								v.pl.health := to_unsigned(100, 8);
							end if;
						when 2 =>
							took := r.pl.armor < 100;
							if (r.pl.armor < 100) then
								v.pl.armor := to_unsigned(100, 8);
							end if;
						when 3 =>
							took := r.pl.bullets < 200;
							if (r.pl.bullets < 190) then
								v.pl.bullets := r.pl.bullets + 10;
							else
								v.pl.bullets := to_unsigned(200, 8);
							end if;
						when 4 =>
							took := r.pl.shells < 50;
							if (r.pl.shells < 46) then
								v.pl.shells := r.pl.shells + 4;
							else
								v.pl.shells := to_unsigned(50, 6);
							end if;
						when 5 =>
							v.pl.weapons := r.pl.weapons or "10";
							v.pl.weapon := "10";
							if (r.pl.shells < 42) then
								v.pl.shells := r.pl.shells + 8;
							else
								v.pl.shells := to_unsigned(50, 6);
							end if;
						when 6 =>
							v.keys := r.keys or "01";
						when others =>
							v.keys := r.keys or "10";
					end case;
					if (took) then
						q.active := '0';
						core_we <= '1';
						core_waddr <= r.aaddr;
						core_wdata <= pack(q);
						v.items := r.items + 1;
						v.pflash := to_unsigned(6, 3);
						v.msg := to_unsigned(kind + 1, 4); -- ITEM_MSG[kind]
						v.msg_timer := to_unsigned(MSG_TIME, 7);
						if (kind = I_SHOTGUN) then
							v.snd_id := to_unsigned(S_WEAPON, 5);
						else
							v.snd_id := to_unsigned(S_ITEM, 5);
						end if;
						v.snd_act := '0';
						v.snd_ret := S_PICK_N;
						v.st := S_SND;
					end if;
				end if;

			when S_PICK_N =>
				if (r.aaddr = 31) then
					v.st := S_SPEC;
				else
					v.aaddr := r.aaddr + 1;
					v.wret := S_PICK_T;
					v.st := S_WAIT;
				end if;

			when S_SPEC =>
				v.maddr := unsigned(std_logic_vector(r.py(21 downto 16))) & unsigned(std_logic_vector(r.px(21 downto 16)));
				v.wret := S_SPEC2;
				v.st := S_WAIT;

			when S_SPEC2 =>
				-- Secret: count it once (clear the special in the map);
				-- toxic floor: 5 damage every 32 frames
				sp := to_integer(unsigned(map_data_i(TILE_SPECIAL_HI downto TILE_SPECIAL_LO)));
				v.on_toxic := bit_of(sp = SPECIAL_TOXIC);
				v.st := S_USE;
				if (sp = SPECIAL_PUSHWALL) then
					v.secrets := r.secrets + 1;
					map_we <= '1';
					v.msg := to_unsigned(11, 4); -- M_SECRET
					v.msg_timer := to_unsigned(MSG_TIME, 7);
				elsif ((sp = SPECIAL_TOXIC) and (r.t_frames(4 downto 0) = 0)) then
					v.dmg := to_unsigned(5, 6);
					v.dp_ret := S_USE;
					v.st := S_DP;
				end if;

			--------------------------------------------------------------
			-- 5. Use: the cell 0.75 tile ahead (c * 3 >> 2)
			--------------------------------------------------------------
			when S_USE =>
				t3 := resize(r.cs, 20) + shift_left(resize(r.cs, 20), 1);
				ux := r.px + resize(shift_right(t3, 2), 24);
				t3 := resize(r.sn, 20) + shift_left(resize(r.sn, 20), 1);
				uy := r.py + resize(shift_right(t3, 2), 24);
				v.maddr := unsigned(std_logic_vector(uy(21 downto 16))) & unsigned(std_logic_vector(ux(21 downto 16)));
				if (s(SNAP_USE) = '1') then
					v.wret := S_USE2;
					v.st := S_WAIT;
				else
					v.st := S_WPN;
				end if;

			when S_USE2 =>
				sp := to_integer(unsigned(map_data_i(TILE_SPECIAL_HI downto TILE_SPECIAL_LO)));
				v.st := S_WPN;
				v.snd_act := '0';
				v.snd_ret := S_WPN;
				case sp is
					when SPECIAL_DOOR =>
						v.st := S_UDOOR;
					when SPECIAL_LOCKED1 | SPECIAL_LOCKED2 =>
						if (((sp = SPECIAL_LOCKED1) and (r.keys(0) = '1')) or
							((sp = SPECIAL_LOCKED2) and (r.keys(1) = '1'))) then
							v.st := S_UDOOR;
						else
							if (sp = SPECIAL_LOCKED1) then
								v.msg := to_unsigned(9, 4); -- M_NEED1
							else
								v.msg := to_unsigned(10, 4); -- M_NEED2
							end if;
							v.msg_timer := to_unsigned(MSG_TIME, 7);
							v.snd_id := to_unsigned(S_NOWAY, 5);
							v.st := S_SND;
						end if;
					when SPECIAL_EXIT =>
						v.level_done := '1';
						v.snd_id := to_unsigned(S_SWITCH, 5);
						v.st := S_SND;
					when others =>
						null;
				end case;

			when S_UDOOR =>
				-- Game.use_door(): new entry, close an open door, reopen a
				-- closing one
				i := didx;
				v.st := S_WPN;
				v.snd_act := '0';
				v.snd_ret := S_WPN;
				if (i = 8) then
					j := first_idle(r.doors);
					if (j < 8) then
						v.doors(j mod 8).x := r.maddr(5 downto 0);
						v.doors(j mod 8).y := r.maddr(11 downto 6);
						v.doors(j mod 8).open_amt := (others => '0');
						v.doors(j mod 8).timer := (others => '0');
						v.doors(j mod 8).state := DS_OPENING;
						v.snd_id := to_unsigned(S_DOOR_OPEN, 5);
						v.st := S_SND;
					end if;
				elsif (r.doors(i mod 8).state = DS_OPEN) then
					v.di := to_unsigned(i mod 8, 3);
					v.db_ret := S_UDOOR2;
					v.st := S_DB;
				elsif (r.doors(i mod 8).state = DS_CLOSING) then
					v.doors(i mod 8).state := DS_OPENING;
				end if;

			when S_UDOOR2 =>
				v.st := S_WPN;
				if (r.blocked = '0') then
					v.doors(to_integer(r.di)).state := DS_CLOSING;
					v.snd_id := to_unsigned(S_DOOR_CLOSE, 5);
					v.snd_act := '0';
					v.snd_ret := S_WPN;
					v.st := S_SND;
				end if;

			--------------------------------------------------------------
			-- 6. Weapon: select, cooldown, fire
			--------------------------------------------------------------
			when S_WPN =>
				dv := resize(unsigned(s(SNAP_WSEL_HI downto SNAP_WSEL_LO)), 6);
				if (((dv = 1) and (r.pl.weapons(0) = '1')) or ((dv = 2) and (r.pl.weapons(1) = '1'))) then
					v.pl.weapon := dv(1 downto 0);
				elsif (s(SNAP_WCYCLE) = '1') then
					if ((r.pl.weapon = 1) and (r.pl.weapons(1) = '1')) then
						v.pl.weapon := "10";
					else
						v.pl.weapon := "01";
					end if;
				end if;
				if (r.cooldown > 0) then
					v.cooldown := r.cooldown - 1;
				end if;
				if (r.flash > 0) then
					v.flash := r.flash - 1;
				end if;
				v.st := S_ACTORS;
				v.snd_act := '0';
				v.snd_ret := S_HS_COL;
				if ((s(SNAP_FIRE) = '1') and (v.cooldown = 0)) then
					if ((v.pl.weapon = 1) and (r.pl.bullets > 0)) then
						v.pl.bullets := r.pl.bullets - 1;
						v.cooldown := to_unsigned(14, 6);
						v.flash := to_unsigned(4, 3);
						v.snd_id := to_unsigned(S_PISTOL, 5);
						v.hk := to_unsigned(3, 3); -- Column 160 only
						v.hshot := '0';
						v.st := S_SND;
					elsif ((v.pl.weapon = 2) and (r.pl.shells > 0)) then
						v.pl.shells := r.pl.shells - 1;
						v.cooldown := to_unsigned(40, 6);
						v.flash := to_unsigned(4, 3);
						v.snd_id := to_unsigned(S_SHOTGUN, 5);
						v.hk := to_unsigned(0, 3); -- Columns 136, 144 .. 184
						v.hshot := '1';
						v.st := S_SND;
					end if;
				end if;

			--------------------------------------------------------------
			-- Hitscan (Game.hitscan): the nearest span over the column in
			-- front of the wall; damage 5 * (1 + (random & 3)) drawn first
			--------------------------------------------------------------
			when S_HS_COL =>
				rnd := lfsr_next(r.lfsr);
				v.lfsr := rnd;
				v.hdmg := times_const(rnd(1 downto 0) + "0001", 5);
				v.zw_addr := to_unsigned(136, 9) + shift_left(resize(r.hk, 9), 3);
				v.wret := S_HS_ZW;
				v.st := S_WAIT;

			when S_HS_ZW =>
				v.zw := unsigned(zwall_data_i);
				v.best_v := '0';
				v.span_addr := (others => '0');
				if (unsigned(span_count_i) = 0) then
					v.st := S_HS_END;
				else
					v.wret := S_HS_SP;
					v.st := S_WAIT;
				end if;

			when S_HS_SP =>
				x0 := resize(unsigned(span_data_i(SPAN_X0_HI downto SPAN_X0_LO)), 16);
				x1 := resize(unsigned(span_data_i(SPAN_X1_HI downto SPAN_X1_LO)), 16);
				z := unsigned(span_data_i(SPAN_Z_HI downto SPAN_Z_LO));
				col := r.zw_addr;
				if ((x0 <= col) and (col <= x1) and (z < r.zw) and ((r.best_v = '0') or (z < r.best_z))) then
					v.best_v := '1';
					v.best_i := unsigned(span_data_i(SPAN_IDX_HI downto SPAN_IDX_LO));
					v.best_z := z;
				end if;
				if (resize(r.span_addr, 6) + 1 = unsigned(span_count_i)) then -- That was the last span
					v.st := S_HS_END;
				else
					v.span_addr := r.span_addr + 1;
					v.wret := S_HS_SP;
					v.st := S_WAIT;
				end if;

			when S_HS_END =>
				if (r.best_v = '1') then
					v.aaddr := r.best_i;
					v.ai := r.best_i;
					v.wret := S_DA;
					v.st := S_WAIT;
				else
					v.st := S_HS_NEXT;
				end if;

			when S_DA =>
				-- Game.damage_actor(): only living (solid) actors
				v.st := S_HS_NEXT;
				if ((q.active = '1') and (q.solid = '1')) then
					v.en_ret := S_HS_WB;
					hp := signed(resize(q.health, 13)) - signed(resize(r.hdmg, 13)); -- Signed: overkill goes below 0
					if (hp <= 0) then
						q.health := (others => '0');
						v.en_s := tp_state(q.typ, TP_DIE_ST);
						v.st := S_ENTER;
					else
						q.health := unsigned(hp(11 downto 0));
						was_awake := q.awake;
						q.awake := '1';
						rnd := lfsr_next(r.lfsr);
						v.lfsr := rnd;
						v.st := S_HS_WB;
						if (to_integer(rnd(7 downto 0)) < tp(q.typ, TP_PAIN)) then -- Pain chance out of 256
							v.en_s := tp_state(q.typ, TP_PAIN_ST);
							v.st := S_ENTER;
						elsif (was_awake = '0') then
							v.en_s := tp_state(q.typ, TP_CHASE);
							v.st := S_ENTER;
						end if;
					end if;
					v.a := q;
				end if;

			when S_HS_WB =>
				core_we <= '1';
				v.st := S_HS_NEXT;

			when S_HS_NEXT =>
				if ((r.hshot = '1') and (r.hk /= 6)) then
					v.hk := r.hk + 1;
					v.st := S_HS_COL;
				else
					v.st := S_AL0;
				end if;

			--------------------------------------------------------------
			-- Stage 5 sound alert (Game.alert), after the shot's hitscans:
			-- breadth-first flood fill from the player's cell over the 4
			-- neighbors that are not solid (walls, closed doors), then the
			-- actor pass, then the visited bits are cleared through the queue
			--------------------------------------------------------------
			when S_AL0 =>
				alc := unsigned(r.py(21 downto 16)) & unsigned(r.px(21 downto 16));
				al_qwe <= '1';
				al_qwaddr <= (others => '0');
				al_qwdata <= std_logic_vector(alc);
				al_vwe <= '1';
				al_vwaddr <= alc;
				v.qhead := (others => '0');
				v.qtail := to_unsigned(1, 13); -- 13 bits: 4096 queued cells must not look empty
				v.st := S_AL_POP;

			when S_AL_POP =>
				if (r.qhead = r.qtail) then
					-- Fill done: the actors in slot order
					v.ai := (others => '0');
					v.aaddr := (others => '0');
					v.wret := S_AL_LD;
					v.st := S_WAIT;
				else
					v.qra := r.qhead(11 downto 0);
					v.st := S_AL_POPW;
				end if;

			when S_AL_POPW =>
				-- The queue address is at the memory now; data next clock
				v.st := S_AL_CUR;

			when S_AL_CUR =>
				v.cur := unsigned(alq_q);
				v.qhead := r.qhead + 1;
				v.nk := "00";
				v.st := S_AL_NB;

			when S_AL_NB =>
				-- Neighbor nk of the current cell (6-bit wrap, as & 63)
				alx := r.cur(5 downto 0);
				aly := r.cur(11 downto 6);
				case r.nk is
					when "00" =>
						alx := alx + 1;
					when "01" =>
						alx := alx - 1;
					when "10" =>
						aly := aly + 1;
					when others =>
						aly := aly - 1;
				end case;
				v.ncell := aly & alx;
				v.maddr := aly & alx;
				v.vaddr := aly & alx;
				v.wret := S_AL_NBD;
				v.st := S_WAIT;

			when S_AL_NBD =>
				-- Tile word, door-open flag and visited bit of ncell are here:
				-- an open, unvisited cell is marked and queued
				if ((vis_q = '0') and not solid(map_data_i, dopen)) then
					al_qwe <= '1';
					al_vwe <= '1';
					v.qtail := r.qtail + 1;
				end if;
				if (r.nk = 3) then
					v.st := S_AL_POP;
				else
					v.nk := r.nk + 1;
					v.st := S_AL_NB;
				end if;

			when S_AL_LD =>
				v.a := q;
				v.vaddr := q.y(15 downto 10) & q.x(15 downto 10); -- Integer parts of Q6.10: the actor's cell
				v.st := S_AL_LD2;

			when S_AL_LD2 =>
				-- The actor cell's visited bit arrives next clock
				v.st := S_AL_CHK;

			when S_AL_CHK =>
				-- A sleeping, living monster in a LOOK state, not an ambusher,
				-- in a reached cell wakes as in LOOK (S_LOOK2, S_LOOK3)
				v.st := S_AL_NX;
				if ((r.a.active = '1') and (r.a.solid = '1') and (r.a.typ < 4) and (r.a.awake = '0') and
					(r.a.ambush = '0') and (st_act(r.a.state) = A_LOOK) and (vis_q = '1')) then
					v.a.awake := '1';
					if (r.a.typ = T_BOSS) then
						v.snd_id := to_unsigned(S_BOSS_SIGHT, 5);
					else
						v.snd_id := to_unsigned(S_SIGHT, 5);
					end if;
					v.snd_act := '1';
					v.snd_ret := S_AL_ENT;
					v.st := S_SND;
				end if;

			when S_AL_ENT =>
				v.en_s := tp_state(r.a.typ, TP_CHASE);
				v.en_ret := S_AL_WB;
				v.st := S_ENTER;

			when S_AL_WB =>
				core_we <= '1';
				v.st := S_AL_NX;

			when S_AL_NX =>
				if (r.ai = 31) then
					v.qhead := (others => '0');
					v.st := S_AL_CLR;
				else
					v.ai := r.ai + 1;
					v.aaddr := r.ai + 1;
					v.wret := S_AL_LD;
					v.st := S_WAIT;
				end if;

			when S_AL_CLR =>
				-- Clear the visited bit of every queued cell (qhead counts)
				if (r.qhead = r.qtail) then
					v.st := S_ACTORS;
				else
					v.qra := r.qhead(11 downto 0);
					v.st := S_AL_CLRW;
				end if;

			when S_AL_CLRW =>
				v.st := S_AL_CLR2;

			when S_AL_CLR2 =>
				al_vwe <= '1';
				al_vwaddr <= unsigned(alq_q);
				al_vwdata <= '0';
				v.qhead := r.qhead + 1;
				v.st := S_AL_CLR;

			--------------------------------------------------------------
			-- 7. Actors 0..31 (Game.actor_step): load the record into the
			-- working copy a, run the per-frame action, count the timer
			-- down, write it back
			--------------------------------------------------------------
			when S_ACTORS =>
				v.ai := (others => '0');
				v.aaddr := (others => '0');
				v.wret := S_ACT_LD;
				v.st := S_WAIT;

			when S_ACT_LD =>
				v.a := q;
				if (q.active = '0') then
					v.st := S_ACT_NX;
				else
					v.st := S_ACT_GO;
				end if;

			when S_ACT_GO =>
				-- One clock for the helpers (adist, atx, aty) of the new a
				case st_act(r.a.state) is
					when A_LOOK =>
						v.st := S_LOOK;
					when A_CHASE =>
						v.st := S_CHASE;
					when A_FLY =>
						v.st := S_FLY;
					when others =>
						v.st := S_TICK;
				end case;

			when S_LOOK =>
				v.st := S_TICK;
				if (adist < WAKE_RANGE) then
					v.los_ret := S_LOOK2;
					v.st := S_LOS;
				end if;

			when S_LOOK2 =>
				v.st := S_TICK;
				if (r.los = '1') then
					v.a.awake := '1';
					if (r.a.typ = T_BOSS) then
						v.snd_id := to_unsigned(S_BOSS_SIGHT, 5);
					else
						v.snd_id := to_unsigned(S_SIGHT, 5);
					end if;
					v.snd_act := '1';
					v.snd_ret := S_LOOK3;
					v.st := S_SND;
				end if;

			when S_LOOK3 =>
				v.en_s := tp_state(r.a.typ, TP_CHASE);
				v.en_ret := S_ACT_WB;
				v.st := S_ENTER;

			when S_CHASE =>
				-- Ranged attack check needs the line of sight
				v.d := adist;
				v.st := S_CHASE3;
				-- (TP_RANGE is in tiles; * 1024 makes it Q6.10 like adist)
				if ((tp(r.a.typ, TP_RANGED) /= 0) and (adist < tp(r.a.typ, TP_RANGE) * 1024)) then
					v.los_ret := S_CHASE2;
					v.st := S_LOS;
				end if;

			when S_CHASE2 =>
				v.st := S_CHASE3;
				if (r.los = '1') then
					rnd := lfsr_next(r.lfsr);
					v.lfsr := rnd;
					if ((rnd(7 downto 0) and to_unsigned(tp(r.a.typ, TP_MASK), 8)) = 0) then -- 1 chance in mask + 1
						v.en_s := tp_state(r.a.typ, TP_AIM_ST);
						v.en_ret := S_ACT_WB;
						v.st := S_ENTER;
					end if;
				end if;

			when S_CHASE3 =>
				-- Melee, else walk toward the player (each axis clamped to
				-- the speed, x first; a step into a solid cell is skipped)
				if ((tp(r.a.typ, TP_MELEE) /= 0) and (r.d < MELEE_RANGE)) then
					v.en_s := tp_state(r.a.typ, TP_MELEE_ST);
					v.en_ret := S_ACT_WB;
					v.st := S_ENTER;
				elsif (r.d >= STOP_RANGE) then
					spd := tp(r.a.typ, TP_SPEED);
					tx := atx;
					ty := aty;
					if (tx > spd) then
						v.csx := to_signed(spd, 8);
					elsif (tx < -spd) then
						v.csx := to_signed(-spd, 8);
					else
						v.csx := tx(7 downto 0);
					end if;
					if (ty > spd) then
						v.csy := to_signed(spd, 8);
					elsif (ty < -spd) then
						v.csy := to_signed(-spd, 8);
					else
						v.csy := ty(7 downto 0);
					end if;
					v.st := S_CHASE3B;
				else
					v.st := S_TICK;
				end if;

			when S_CHASE3B =>
				-- actor_move_ok(x + sx, y, actor_floor(a)): floor first
				v.st := S_CHASE5;
				if (r.csx /= 0) then
					v.fpx := q16(r.a.x);
					v.fpy := q16(r.a.y);
					v.fat_ret := S_CHASE3C;
					v.st := S_FAT;
				end if;

			when S_CHASE3C =>
				v.bz := r.fat;
				v.bx := q16(r.a.x + unsigned(resize(r.csx, 16)));
				v.by := q16(r.a.y);
				v.bsmall := '0';
				v.box_ret := S_CHASE4;
				v.st := S_BOX;

			when S_CHASE4 =>
				if (r.hit = '0') then
					v.a.x := r.a.x + unsigned(resize(r.csx, 16));
				end if;
				v.st := S_CHASE5;

			when S_CHASE5 =>
				-- The floor again: a.x may have moved
				v.st := S_TICK;
				if (r.csy /= 0) then
					v.fpx := q16(r.a.x);
					v.fpy := q16(r.a.y);
					v.fat_ret := S_CHASE5B;
					v.st := S_FAT;
				end if;

			when S_CHASE5B =>
				v.bz := r.fat;
				v.bx := q16(r.a.x);
				v.by := q16(r.a.y + unsigned(resize(r.csy, 16)));
				v.bsmall := '0';
				v.box_ret := S_CHASE6;
				v.st := S_BOX;

			when S_CHASE6 =>
				if (r.hit = '0') then
					v.a.y := r.a.y + unsigned(resize(r.csy, 16));
				end if;
				v.st := S_TICK;

			when S_FLY =>
				-- Fireball: one velocity step (mod 2^16), then its cell; health
				-- holds its direction 0..15, the FIRE_VEL row
				ax := r.a.x + unsigned(to_signed(FIRE_VEL(to_integer(r.a.health(3 downto 0)))(0), 16));
				ay := r.a.y + unsigned(to_signed(FIRE_VEL(to_integer(r.a.health(3 downto 0)))(1), 16));
				v.a.x := ax;
				v.a.y := ay;
				v.maddr := ay(15 downto 10) & ax(15 downto 10);
				v.wret := S_FLY2;
				v.st := S_WAIT;

			when S_FLY2 =>
				v.en_s := to_unsigned(ST_EXPL_A, 7);
				v.en_ret := S_ACT_WB;
				if (solid(map_data_i, dopen)) then
					v.st := S_ENTER;
				elsif ((absu(atx) < FIRE_HIT) and (absu(aty) < FIRE_HIT)) then
					rnd := lfsr_next(r.lfsr);
					v.lfsr := rnd;
					v.dmg := times_const(resize(rnd(2 downto 0), 4) + 1, 3); -- 3 * (1 + (random & 7))
					v.dp_ret := S_FLY3;
					v.st := S_DP;
				else
					v.st := S_TICK;
				end if;

			when S_FLY3 =>
				v.st := S_ENTER;

			when S_TICK =>
				v.st := S_ACT_WB;
				if (r.a.timer /= FOREVER) then
					v.a.timer := r.a.timer - 1;
					if (r.a.timer = 1) then -- Runs out this frame: on to the next state
						v.en_s := st_next(r.a.state);
						v.en_ret := S_ACT_WB;
						v.st := S_ENTER;
					end if;
				end if;

			when S_ACT_WB =>
				core_we <= '1';
				v.st := S_ACT_NX;

			when S_ACT_NX =>
				if (r.ai = 31) then
					v.di := (others => '0');
					v.st := S_DOORS;
				else
					v.ai := r.ai + 1;
					v.aaddr := r.ai + 1;
					v.wret := S_ACT_LD;
					v.st := S_WAIT;
				end if;

			--------------------------------------------------------------
			-- 8. Doors (Game.update_doors), then the world timers
			--------------------------------------------------------------
			when S_DOORS =>
				dd := r.doors(to_integer(r.di));
				v.st := S_DOOR_NX;
				v.db_ret := S_DOOR_NX;
				case dd.state is
					when DS_OPENING =>
						if (dd.open_amt + DOOR_STEP >= DOOR_OPEN) then
							dd.open_amt := to_signed(DOOR_OPEN, 8);
							dd.state := DS_OPEN;
							dd.timer := to_unsigned(DOOR_STAY, 8);
						else
							dd.open_amt := dd.open_amt + DOOR_STEP;
						end if;
					when DS_OPEN =>
						dd.timer := dd.timer - 1;
						if (dd.timer = 0) then
							v.db_ret := S_DOOR_OPEN2;
							v.st := S_DB;
						end if;
					when DS_CLOSING =>
						v.db_ret := S_DOOR_CL2;
						v.st := S_DB;
					when others =>
						null;
				end case;
				v.doors(to_integer(r.di)) := dd;

			when S_DOOR_OPEN2 =>
				if (r.blocked = '1') then
					v.doors(to_integer(r.di)).timer := to_unsigned(DOOR_RETRY, 8);
				else
					v.doors(to_integer(r.di)).state := DS_CLOSING;
				end if;
				v.st := S_DOOR_NX;

			when S_DOOR_CL2 =>
				dd := r.doors(to_integer(r.di));
				if (r.blocked = '1') then
					dd.state := DS_OPENING;
				elsif (dd.open_amt - DOOR_STEP <= 0) then
					dd.open_amt := (others => '0');
					dd.state := DS_IDLE;
				else
					dd.open_amt := dd.open_amt - DOOR_STEP;
				end if;
				v.doors(to_integer(r.di)) := dd;
				v.st := S_DOOR_NX;

			when S_DOOR_NX =>
				if (r.di = 7) then
					v.st := S_WORLD;
				else
					v.di := r.di + 1;
					v.st := S_DOORS;
				end if;

			when S_WORLD =>
				if (r.boss_timer > 0) then
					v.boss_timer := r.boss_timer - 1;
					if (r.boss_timer = 1) then
						v.level_done := '1';
					end if;
				end if;
				if (r.dflash > 0) then
					v.dflash := r.dflash - 1;
				end if;
				if (r.pflash > 0) then
					v.pflash := r.pflash - 1;
				end if;
				if (r.msg_timer > 0) then
					v.msg_timer := r.msg_timer - 1;
					if (r.msg_timer = 1) then
						v.msg := (others => '0');
					end if;
				end if;
				if (r.pl.health = 0) then
					v.flow := FL_DEAD;
					v.dead_timer := (others => '0');
				elsif (v.level_done = '1') then
					v.flow := FL_SCORE;
				end if;
				v.st := S_END;

			--------------------------------------------------------------
			-- End of every step: sprite table, key positions, checksum,
			-- outputs
			--------------------------------------------------------------
			when S_END =>
				-- Effects frame of this step: (t_sec * 60 + t_frames) mod 256, t_sec * 60 as
				-- (t_sec << 6) - (t_sec << 2)
				v.fxn := resize(shift_left(resize(r.t_sec, 12), 6) - shift_left(resize(r.t_sec, 12), 2) +
					resize(r.t_frames, 12), 8);
				v.aaddr := (others => '0');
				v.spr_n := (others => '0');
				v.kp := (others => '0');
				v.wret := S_SPR_T;
				v.st := S_WAIT;

			when S_SPR_T =>
				-- Light offsets of this step's effects frame (registered: the table and
				-- adders stay off the sprite light path)
				v.lm := light_mods(r.fxn, r.flash /= 0);
				-- Art frame: items 38 + kind, fireballs 38 + state frame,
				-- monsters 0 / 9 / 18 / 27 + state frame (art.py)
				v.st := S_SPR_N;
				if (q.active = '1') then
					if (q.typ = T_ITEM) then
						frame := to_unsigned(ITEM_BASE, 8) + resize(q.health(2 downto 0), 8);
					else
						if (q.typ = T_FIREBALL) then
							base := ITEM_BASE;
						else
							base := 9 * to_integer(q.typ(1 downto 0));
						end if;
						frame := to_unsigned(base, 8) + resize(st_frame(q.state), 8);
					end if;
					v.spr_e := (others => '0');
					v.spr_e(SPR_IDX_HI downto SPR_IDX_LO) := std_logic_vector(r.aaddr);
					v.spr_e(SPR_X_HI downto SPR_X_LO) := std_logic_vector(q.x);
					v.spr_e(SPR_Y_HI downto SPR_Y_LO) := std_logic_vector(q.y);
					v.spr_e(SPR_FRAME_HI downto SPR_FRAME_LO) := std_logic_vector(frame);
					v.spr_e(SPR_BRIGHT) := bit_of(q.typ = T_FIREBALL);
					v.spr_e(SPR_TARGET) := q.solid and bit_of(q.typ < 4);
					-- Keys still on the floor (first of each kind): 13-bit entry, the
					-- cell (y & x) above a valid bit
					if ((q.typ = T_ITEM) and (q.health = I_KEY1) and (r.kp(KEYPOS_BLUE) = '0')) then
						v.kp(KEYPOS_BLUE + 12 downto KEYPOS_BLUE) := std_logic_vector(unsigned'(q.y(15 downto 10) & q.x(15 downto 10))) & '1';
					end if;
					if ((q.typ = T_ITEM) and (q.health = I_KEY2) and (r.kp(KEYPOS_RED) = '0')) then
						v.kp(KEYPOS_RED + 12 downto KEYPOS_RED) := std_logic_vector(unsigned'(q.y(15 downto 10) & q.x(15 downto 10))) & '1';
					end if;
					v.maddr := q.y(15 downto 10) & q.x(15 downto 10);
					v.wret := S_SPR_L;
					v.st := S_WAIT;
				end if;

			when S_SPR_L =>
				-- Light of the center tile, then the floor under the center
				v.spr_e(SPR_LIGHT_HI downto SPR_LIGHT_LO) := map_data_i(TILE_LIGHT_HI downto TILE_LIGHT_LO);
				v.spr_ty := map_data_i(TILE_LTYPE_HI downto TILE_LTYPE_LO);
				v.fpx := q16(unsigned(r.spr_e(SPR_X_HI downto SPR_X_LO)));
				v.fpy := q16(unsigned(r.spr_e(SPR_Y_HI downto SPR_Y_LO)));
				v.fat_ret := S_SPR_F;
				v.st := S_FAT;

			when S_SPR_F =>
				spr_we <= '1';
				spr_wdata(SPR_FLOOR_HI downto SPR_FLOOR_LO) <= std_logic_vector(r.fat(6 downto 0)); -- 0..64 fits 7 bits
				spr_wdata(SPR_LIGHT_HI downto SPR_LIGHT_LO) <=
					mod_light(r.spr_e(SPR_LIGHT_HI downto SPR_LIGHT_LO), r.lm, r.spr_ty);
				v.spr_n := r.spr_n + 1;
				v.st := S_SPR_N;

			when S_SPR_N =>
				if (r.aaddr = 31) then
					v.st := S_CRC0;
				else
					v.aaddr := r.aaddr + 1;
					v.wret := S_SPR_T;
					v.st := S_WAIT;
				end if;

			when S_CRC0 =>
				crc_init <= '1';
				v.cw := (others => '0');
				v.st := S_CRC_W;

			when S_CRC_W =>
				v.cword := word; -- waddr = r.cw in this state
				v.cb := (others => '0');
				v.st := S_CRC_B;

			when S_CRC_B =>
				-- 8 bytes little endian per word
				crc_valid <= '1';
				for b in 0 to 7 loop
					if (r.cb = b) then
						crc_byte <= r.cword(8 * b + 7 downto 8 * b);
					end if;
				end loop;
				v.cb := r.cb + 1;
				if (r.cb = 7) then
					if (r.cw = STATE_WORDS - 1) then
						v.st := S_OUT;
					else
						v.cw := r.cw + 1;
						v.st := S_CRC_W;
					end if;
				end if;

			when S_OUT =>
				v.fx_o := std_logic_vector(r.fxn(4 downto 3)) & r.lm; -- anim = (n >> 3) & 3
				v.cam_x_o := std_logic_vector(r.cam_x(POS_BITS - 1 downto 0));
				v.cam_y_o := std_logic_vector(r.cam_y(POS_BITS - 1 downto 0));
				v.angle_o := std_logic_vector(r.angle);
				-- view_eye() = min(127, z + eye)
				if (resize(r.z, 9) + r.eye > 127) then
					v.eye_o := (others => '1');
				else
					v.eye_o := std_logic_vector(resize(r.z, 7) + r.eye);
				end if;
				v.player_x_o := std_logic_vector(r.px(POS_BITS - 1 downto 0));
				v.player_y_o := std_logic_vector(r.py(POS_BITS - 1 downto 0));
				for k in 0 to 7 loop
					if (r.doors(k).state = DS_IDLE) then
						v.doors_o(DOOR_BITS * k + DOOR_BITS - 1 downto DOOR_BITS * k) := (others => '0');
					else
						v.doors_o(DOOR_BITS * k + DOOR_X_HI downto DOOR_BITS * k + DOOR_X_LO) :=
							std_logic_vector(r.doors(k).x);
						v.doors_o(DOOR_BITS * k + DOOR_Y_HI downto DOOR_BITS * k + DOOR_Y_LO) :=
							std_logic_vector(r.doors(k).y);
						v.doors_o(DOOR_BITS * k + DOOR_OPEN_HI downto DOOR_BITS * k + DOOR_OPEN_LO) :=
							std_logic_vector(r.doors(k).open_amt(6 downto 0));
					end if;
				end loop;
				-- HUD word (game.hud())
				v.hud_o := (others => '0');
				v.hud_o(HUD_FLOW_HI downto HUD_FLOW_LO) := std_logic_vector(r.flow);
				v.hud_o(HUD_LEVEL_HI downto HUD_LEVEL_LO) := std_logic_vector(r.level);
				v.hud_o(HUD_HEALTH_HI downto HUD_HEALTH_LO) := std_logic_vector(r.pl.health);
				v.hud_o(HUD_ARMOR_HI downto HUD_ARMOR_LO) := std_logic_vector(r.pl.armor);
				if (r.pl.weapon = 1) then
					v.hud_o(HUD_AMMO_HI downto HUD_AMMO_LO) := std_logic_vector(r.pl.bullets);
					frame := to_unsigned(WEAPON_BASE, 8);
					if (r.flash > 0) then
						frame := to_unsigned(WEAPON_BASE + 1, 8);
					end if;
				else
					v.hud_o(HUD_AMMO_HI downto HUD_AMMO_LO) := std_logic_vector(resize(r.pl.shells, 8));
					-- Shotgun pump frames over its 40-frame cooldown
					if (r.cooldown > 36) then
						frame := to_unsigned(WEAPON_BASE + 3, 8);
					elsif (r.cooldown > 16) then
						frame := to_unsigned(WEAPON_BASE + 4, 8);
					else
						frame := to_unsigned(WEAPON_BASE + 2, 8);
					end if;
				end if;
				v.hud_o(HUD_WEAPON_HI downto HUD_WEAPON_LO) := std_logic_vector(r.pl.weapon);
				v.hud_o(HUD_KEYS_HI downto HUD_KEYS_LO) := std_logic_vector(r.keys);
				v.hud_o(HUD_WFRAME_HI downto HUD_WFRAME_LO) := std_logic_vector(frame);
				-- BOB = 0 1 2 3 4 3 2 1 by phase bits 4:2, only while PLAYING
				bob := 0;
				if (r.flow = FL_PLAYING) then
					case to_integer(r.phase(4 downto 2)) is
						when 0 =>
							bob := 0;
						when 1 | 7 =>
							bob := 1;
						when 2 | 6 =>
							bob := 2;
						when 3 | 5 =>
							bob := 3;
						when others =>
							bob := 4;
					end case;
				end if;
				v.hud_o(HUD_BOB_HI downto HUD_BOB_LO) := std_logic_vector(to_unsigned(bob, 3));
				v.hud_o(HUD_MSG_HI downto HUD_MSG_LO) := std_logic_vector(r.msg);
				v.hud_o(HUD_KILLS_HI downto HUD_KILLS_LO) := std_logic_vector(r.kills);
				v.hud_o(HUD_TKILLS_HI downto HUD_TKILLS_LO) := std_logic_vector(r.tkills);
				v.hud_o(HUD_ITEMS_HI downto HUD_ITEMS_LO) := std_logic_vector(r.items);
				v.hud_o(HUD_TITEMS_HI downto HUD_TITEMS_LO) := std_logic_vector(r.titems);
				v.hud_o(HUD_SECRETS_HI downto HUD_SECRETS_LO) := std_logic_vector(r.secrets);
				v.hud_o(HUD_TSECRETS_HI downto HUD_TSECRETS_LO) := std_logic_vector(r.tsecrets);
				v.hud_o(HUD_TMIN_HI downto HUD_TMIN_LO) := std_logic_vector(r.t_min);
				v.hud_o(HUD_TSEC_HI downto HUD_TSEC_LO) := std_logic_vector(r.t_sec);
				v.hud_o(HUD_AUTOMAP) := r.automap;
				v.hud_o(HUD_DEBUG) := r.debug;
				v.keypos_o := r.kp;
				if ((r.flow = FL_PLAYING) or (r.flow = FL_PAUSED) or (r.flow = FL_DEAD)) then
					v.music_o := std_logic_vector(r.level);
				else
					v.music_o := "00";
				end if;
				-- Screen tint (game.tint()): damage flash, pickup flash, toxic floor
				if (r.dflash > 0) then
					v.tint_o := "01";
				elsif (r.pflash > 0) then
					v.tint_o := "10";
				elsif ((r.flow = FL_PLAYING) and (r.on_toxic = '1')) then
					v.tint_o := "11";
				else
					v.tint_o := "00";
				end if;
				v.spr_count_o := std_logic_vector(r.spr_n);
				v.crc_o := crc;
				v.bank := not r.bank;
				v.oq := r.sq;
				v.oq_n := r.sq_n;
				v.oq_p := (others => '0');
				v.start := '1';
				v.st := S_IDLE;

			--------------------------------------------------------------
			-- Subroutines
			--------------------------------------------------------------
			when S_WAIT =>
				-- The address register is at the memory now; data next clock
				v.st := r.wret;

			when S_BOX =>
				-- Game.box_hits(): 2 x 2 cells, stop at the first solid one
				v.bk := "00";
				v.hit := '0';
				v.maddr := box_cell(r.bx, r.by, r.bsmall, "00");
				v.wret := S_BOX_D;
				v.st := S_WAIT;

			when S_BOX_D =>
				-- Game.blocks(): solid, or (stage 4, not for the peek camera
				-- box, which only tests solid cells) too high a step or too
				-- little headroom for a body at bz
				if (solid(map_data_i, dopen) or ((r.bsmall = '0') and height_blocks(map_data_i, r.bz))) then
					v.hit := '1';
					v.st := r.box_ret;
				elsif (r.bk = 3) then
					v.st := r.box_ret;
				else
					v.bk := r.bk + 1;
					v.maddr := box_cell(r.bx, r.by, r.bsmall, r.bk + 1);
					v.wret := S_BOX_D;
					v.st := S_WAIT;
				end if;

			when S_FAT =>
				-- Game.floor_at(fpx, fpy): the tile's floor; a ramp adds
				-- (rise * s) >> 16, rise from the next tile in its direction
				v.maddr := point_cell(r.fpx, r.fpy);
				v.wret := S_FAT_D;
				v.st := S_WAIT;

			when S_FAT_D =>
				ft := map_data_i;
				v.ff := resize(floor_h(ft), 8);
				if (not is_ramp(ft)) then
					v.fat := resize(floor_h(ft), 8);
					v.st := r.fat_ret;
				else
					-- Ramp direction in ceil_tex: 0 +x, 1 -x, 2 +y, 3 -y
					dir := to_integer(unsigned(ft(TILE_CEIL_HI downto TILE_CEIL_LO)));
					if (dir >= 2) then
						frac := unsigned(std_logic_vector(r.fpy(15 downto 0)));
					else
						frac := unsigned(std_logic_vector(r.fpx(15 downto 0)));
					end if;
					if ((dir = 0) or (dir = 2)) then
						v.fs := resize(frac, 17);
					else
						v.fs := to_unsigned(65536, 17) - frac;
					end if;
					case dir is
						when 0 =>
							v.maddr := r.maddr(11 downto 6) & (r.maddr(5 downto 0) + 1);
						when 1 =>
							v.maddr := r.maddr(11 downto 6) & (r.maddr(5 downto 0) - 1);
						when 2 =>
							v.maddr := (r.maddr(11 downto 6) + 1) & r.maddr(5 downto 0);
						when others =>
							v.maddr := (r.maddr(11 downto 6) - 1) & r.maddr(5 downto 0);
					end case;
					v.wret := S_FAT_N;
					v.st := S_WAIT;
				end if;

			when S_FAT_N =>
				-- rise (multiple of 8, -56..56) times s on the shared multiplier
				rise := signed(resize(floor_h(map_data_i), 9)) - signed(resize(r.ff, 9));
				v.mul_a := resize(rise, 24);
				v.mul_b := signed(resize(r.fs, 18));
				v.st := S_FAT_W;

			when S_FAT_W =>
				v.st := S_FAT_M;

			when S_FAT_M =>
				fsum := signed(resize(r.ff, 10)) + resize(shift_right(prod, 16), 10); -- floor + (rise * s) >> 16
				v.fat := unsigned(fsum(7 downto 0));
				v.st := r.fat_ret;

			when S_BFL =>
				-- Game.box_floor(bx, by, HALF): the highest floor_at() of the
				-- four box corners (bfk bit 0 picks x -/+, bit 1 picks y -/+)
				v.bfk := "00";
				v.bfl := (others => '0');
				v.fpx := r.bx - HALF;
				v.fpy := r.by - HALF;
				v.fat_ret := S_BFL_N;
				v.st := S_FAT;

			when S_BFL_N =>
				if (r.fat > r.bfl) then
					v.bfl := r.fat;
				end if;
				if (r.bfk = 3) then
					v.st := r.bfl_ret;
				else
					v.bfk := r.bfk + 1;
					-- Corner bfk + 1: x - when its bit 0 is 0, y + from corner 2 on
					if (r.bfk(0) = '1') then
						v.fpx := r.bx - HALF;
					else
						v.fpx := r.bx + HALF;
					end if;
					if (r.bfk = 0) then
						v.fpy := r.by - HALF;
					else
						v.fpy := r.by + HALF;
					end if;
					v.fat_ret := S_BFL_N;
					v.st := S_FAT;
				end if;

			when S_LOS =>
				-- Game.los(): Bresenham from the actor's cell to the player's
				v.lx := r.a.x(15 downto 10);
				v.ly := r.a.y(15 downto 10);
				v.lx1 := unsigned(std_logic_vector(r.px(21 downto 16)));
				v.ly1 := unsigned(std_logic_vector(r.py(21 downto 16)));
				v.ldx := abs(signed(resize(v.lx1, 8)) - signed(resize(v.lx, 8)));
				v.ldy := abs(signed(resize(v.ly1, 8)) - signed(resize(v.ly, 8)));
				if (v.lx1 > v.lx) then
					v.lsx := "01";
				elsif (v.lx1 < v.lx) then
					v.lsx := "11";
				else
					v.lsx := "00";
				end if;
				if (v.ly1 > v.ly) then
					v.lsy := "01";
				elsif (v.ly1 < v.ly) then
					v.lsy := "11";
				else
					v.lsy := "00";
				end if;
				v.lerr := resize(v.ldx, 9) - resize(v.ldy, 9);
				v.lcnt := (others => '0');
				v.st := S_LOS_IT;

			when S_LOS_IT =>
				-- One loop iteration: at the target -> visible; else step
				-- (e2 = 2 err; e2 > -dy steps x, e2 < dx steps y) and test
				-- the new cell unless it is the target
				if ((r.lx = r.lx1) and (r.ly = r.ly1)) then
					v.los := '1';
					v.st := r.los_ret;
				elsif (r.lcnt = 64) then -- Step limit (the model's loop bound)
					v.los := '0';
					v.st := r.los_ret;
				else
					e2 := shift_left(r.lerr, 1);
					nerr := r.lerr;
					nx := signed(resize(r.lx, 8));
					ny := signed(resize(r.ly, 8));
					if (e2 > -resize(r.ldy, 9)) then
						nerr := nerr - resize(r.ldy, 9);
						nx := nx + r.lsx;
					end if;
					if (e2 < resize(r.ldx, 9)) then
						nerr := nerr + resize(r.ldx, 9);
						ny := ny + r.lsy;
					end if;
					v.lerr := nerr;
					v.lx := unsigned(nx(5 downto 0));
					v.ly := unsigned(ny(5 downto 0));
					v.lcnt := r.lcnt + 1;
					if ((v.lx /= r.lx1) or (v.ly /= r.ly1)) then
						v.maddr := v.ly & v.lx;
						v.wret := S_LOS_D;
						v.st := S_WAIT;
					end if;
				end if;

			when S_LOS_D =>
				if (solid(map_data_i, dopen)) then
					v.los := '0';
					v.st := r.los_ret;
				else
					v.st := S_LOS_IT;
				end if;

			when S_DB =>
				-- Game.door_blocked(door di): the player, then every
				-- active solid actor (one per clock)
				dd := r.doors(to_integer(r.di));
				if (in_cell(r.px, r.py, dd.x, dd.y)) then
					v.blocked := '1';
					v.st := r.db_ret;
				else
					v.aaddr := (others => '0');
					v.wret := S_DB_S;
					v.st := S_WAIT;
				end if;

			when S_DB_S =>
				if (hit_door = '1') then
					v.blocked := '1';
					v.st := r.db_ret;
				elsif (r.aaddr = 31) then
					v.blocked := '0';
					v.st := r.db_ret;
				else
					v.aaddr := r.aaddr + 1;
					v.wret := S_DB_S;
					v.st := S_WAIT;
				end if;

			when S_SND =>
				-- Game.sound(): at most 4 per step; an actor's sound gets a
				-- volume from its distance (0 drops it) and a pan from its
				-- sideways offset (two products on the shared multiplier)
				v.st := r.snd_ret;
				if (r.sq_n /= 4) then
					if (r.snd_act = '0') then
						-- The player's own sound: full volume, centred
						v.sq(to_integer(r.sq_n(1 downto 0))) := (r.snd_id, to_unsigned(63, 6), to_signed(0, 6));
						v.sq_n := r.sq_n + 1;
					else
						v.st := S_SND_W;
					end if;
				end if;

			when S_SND_W =>
				v.st := S_SND_V;

			when S_SND_V =>
				-- avol is three clocks behind a; a may have changed in the
				-- clock before S_SND (S_DA -> S_ENTER -> S_SND)
				v.svol := avol;
				v.st := r.snd_ret;
				if (avol /= 0) then
					v.mul_a := q16(r.a.x) - r.px; -- rx
					v.mul_b := -r.sn;
					v.st := S_SND_M1;
				end if;

			when S_SND_M1 =>
				v.mul_a := q16(r.a.y) - r.py; -- ry
				v.mul_b := r.cs;
				v.st := S_SND_M2;

			when S_SND_M2 =>
				v.acc := prod; -- rx * -sin
				v.st := S_SND_M3;

			when S_SND_M3 =>
				-- pan = clamp((lateral >> 16) >> 11, -31, 31) = sum >> 27
				sum := resize(r.acc, 43) + resize(prod, 43);
				v.lat := sum(42 downto 27);
				v.st := S_SND_M4;

			when S_SND_M4 =>
				lat := r.lat;
				if (lat > 31) then
					lat := to_signed(31, 16);
				elsif (lat < -31) then
					lat := to_signed(-31, 16);
				end if;
				v.sq(to_integer(r.sq_n(1 downto 0))) := (r.snd_id, r.svol, lat(5 downto 0));
				v.sq_n := r.sq_n + 1;
				v.st := r.snd_ret;

			when S_DP =>
				-- Game.damage_player(dmg): armor takes (dmg * 21) >> 6
				-- (21 = 16 + 4 + 1), at most what is left of it
				v.st := r.dp_ret;
				if (r.pl.health /= 0) then
					dmg := r.dmg;
					if (r.pl.armor > 0) then
						saved := shift_right(shift_left(resize(dmg, 10), 4) + shift_left(resize(dmg, 10), 2) +
							resize(dmg, 10), 6);
						if (saved > r.pl.armor) then
							saved := resize(r.pl.armor, 10);
						end if;
						v.pl.armor := r.pl.armor - saved(7 downto 0);
						v.dmg := dmg - saved(5 downto 0);
					end if;
					v.st := S_DP2;
				end if;

			when S_DP2 =>
				-- Health minus what the armor did not take, floor 0
				dmg := r.dmg;
				if (r.pl.health > dmg) then
					v.pl.health := r.pl.health - dmg;
					v.snd_id := to_unsigned(S_PLAYER_PAIN, 5);
				else
					v.pl.health := (others => '0');
					v.snd_id := to_unsigned(S_PLAYER_DEATH, 5);
				end if;
				v.dflash := to_unsigned(8, 4);
				v.snd_act := '0';
				v.snd_ret := r.dp_ret;
				v.st := S_SND;

			when S_ENTER =>
				-- Game.enter(): new state and timer; entry actions run now
				-- (LOOK, CHASE and FLY run every frame in S_ACT_GO instead)
				v.a.state := r.en_s;
				v.a.timer := st_dur(r.en_s);
				v.st := r.en_ret;
				v.snd_act := '1';
				v.snd_ret := r.en_ret;
				case st_act(r.en_s) is
					when A_SHOOT =>
						v.snd_id := to_unsigned(S_SHOOT, 5);
						v.snd_ret := S_A_SHOOT2;
						v.st := S_SND;
					when A_FIRE =>
						v.snd_id := to_unsigned(S_FIRE, 5);
						v.snd_ret := S_A_FIRE2;
						v.st := S_SND;
					when A_MELEE =>
						v.snd_id := to_unsigned(S_CLAW, 5);
						v.snd_ret := S_A_MELEE2;
						v.st := S_SND;
					when A_PAIN =>
						v.snd_id := to_unsigned(S_PAIN, 5);
						v.st := S_SND;
					when A_DIE =>
						v.a.solid := '0';
						v.kills := r.kills + 1;
						if (r.a.typ = T_BOSS) then
							v.boss_timer := to_unsigned(BOSS_TIME, 8);
						end if;
						v.snd_id := to_unsigned(S_DEATH, 5);
						v.snd_ret := S_A_DIE2;
						v.st := S_SND;
					when A_EXPLODE =>
						v.snd_id := to_unsigned(S_EXPLODE, 5);
						v.st := S_SND;
					when A_REMOVE =>
						v.a.active := '0';
					when others =>
						null;
				end case;

			when S_A_SHOOT2 =>
				v.los_ret := S_A_SHOOT3;
				v.st := S_LOS;

			when S_A_SHOOT3 =>
				-- Hit chance max(40, 200 - (dist >> 7)), then 3 * (1 + (random & 3))
				v.st := r.en_ret;
				if (r.los = '1') then
					dist_v := adist;
					rnd := lfsr_next(r.lfsr);
					v.lfsr := rnd;
					-- From dist >> 7 = 160 on the floor of 40 applies;
					-- closer, random + (dist >> 7) < 200 is random < 200 - (dist >> 7)
					if ((dist_v(18 downto 7) >= 160) and (rnd(7 downto 0) < 40)) or
						((dist_v(18 downto 7) < 160) and (resize(rnd(7 downto 0), 12) + dist_v(18 downto 7) < 200)) then
						v.st := S_A_SHOOT4;
					end if;
				end if;

			when S_A_SHOOT4 =>
				rnd := lfsr_next(r.lfsr);
				v.lfsr := rnd;
				v.dmg := times_const(resize(rnd(1 downto 0), 4) + 1, 3);
				v.dp_ret := r.en_ret;
				v.st := S_DP;

			when S_A_FIRE2 =>
				-- Fireball toward the player from the actor's position
				tx := atx;
				ty := aty;
				v.sp_type := to_unsigned(T_FIREBALL, 3);
				v.sp_state := to_unsigned(ST_FLY_A, 7);
				v.sp_health := resize(direction16(tx, ty), 12);
				v.sp_ret := r.en_ret;
				v.st := S_SPAWN;

			when S_A_MELEE2 =>
				v.st := r.en_ret;
				if (adist < MELEE_RANGE) then
					rnd := lfsr_next(r.lfsr);
					v.lfsr := rnd;
					v.dmg := times_const(resize(rnd(2 downto 0), 4) + 1, tp(r.a.typ, TP_MULT)); -- mult * (1 + (random & 7))
					v.dp_ret := r.en_ret;
					v.st := S_DP;
				end if;

			when S_A_DIE2 =>
				-- A grunt drops a box of bullets
				v.st := r.en_ret;
				if (r.a.typ = T_GRUNT) then
					v.sp_type := to_unsigned(T_ITEM, 3);
					v.sp_state := to_unsigned(ST_ITEM_IDLE, 7);
					v.sp_health := to_unsigned(I_BULLETS, 12);
					v.sp_ret := r.en_ret;
					v.st := S_SPAWN;
				end if;

			when S_SPAWN =>
				v.aaddr := (others => '0');
				v.wret := S_SPAWN_S;
				v.st := S_WAIT;

			when S_SPAWN_S =>
				-- Game.spawn(): first inactive slot (none free: nothing)
				if (q.active = '0') then
					q := ACTOR_CLEAR;
					q.x := r.a.x;
					q.y := r.a.y;
					q.typ := r.sp_type;
					q.health := r.sp_health;
					q.active := '1';
					q.state := r.sp_state;
					q.timer := st_dur(r.sp_state);
					core_we <= '1';
					core_waddr <= r.aaddr;
					core_wdata <= pack(q);
					v.st := r.sp_ret;
				elsif (r.aaddr = 31) then
					v.st := r.sp_ret;
				else
					v.aaddr := r.aaddr + 1;
					v.wret := S_SPAWN_S;
					v.st := S_WAIT;
				end if;
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

	load_req_o <= r.load_req;
	load_level_o <= std_logic_vector(r.level);
	map_addr_o <= std_logic_vector(r.maddr);
	map_we_o <= map_we;
	-- Secret found: the same tile with its special (16:14) cleared
	map_wdata_o <= map_data_i(23 downto 17) & "000" & map_data_i(13 downto 0);
	span_addr_o <= std_logic_vector(r.span_addr);
	zwall_addr_o <= std_logic_vector(r.zw_addr);
	cam_x_o <= r.cam_x_o;
	cam_y_o <= r.cam_y_o;
	angle_o <= r.angle_o;
	eye_o <= r.eye_o;
	doors_o <= r.doors_o;
	player_x_o <= r.player_x_o;
	player_y_o <= r.player_y_o;
	hud_o <= r.hud_o;
	keypos_o <= r.keypos_o;
	music_o <= r.music_o;
	tint_o <= r.tint_o;
	fx_o <= r.fx_o;
	spr_data_o <= spr_q;
	spr_count_o <= r.spr_count_o;
	render_start_o <= r.start;
	busy_o <= '0' when (r.st = S_IDLE) else '1';
	snd_valid_o <= '1' when (r.oq_p /= r.oq_n) else '0';
	-- Command at the queue read pointer: priority (from the id) & pan & volume & id
	snd_data_o <= std_logic_vector(to_unsigned(SOUND_PRIORITY(to_integer(r.oq(to_integer(r.oq_p(1 downto 0))).id)), 4)) &
		std_logic_vector(r.oq(to_integer(r.oq_p(1 downto 0))).pan) &
		std_logic_vector(r.oq(to_integer(r.oq_p(1 downto 0))).vol) &
		std_logic_vector(r.oq(to_integer(r.oq_p(1 downto 0))).id);
	level_loaded_o <= r.loaded;
	state_data_o <= sdata;
	crc_o <= r.crc_o;
end arch;

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
-- Description:    One Game.step of tools/model/game.py (with actors.py) per
--                 frame, bit for bit, including every random() call in
--                 order, sound commands, HUD word and sprite table.
--
--                 Flow per frame (snapshot_valid_i after frame_start_i):
--                   CORE_STEP  sounds cleared, fire edge, debug toggle,
--                              flow switch (BRIEFING go and DEAD restart
--                              load a level here)
--                   PLAYING, in the model's order:
--                     1 CORE_PLAY  level clock, turn, duck and peek easing;
--                                  sin/cos of the new angle
--                     2 CORE_MOVE  x then y: box test (4 map reads), solid
--                                  actors (32 actor reads), flush clamp
--                     3 CORE_PEEK  camera box test, offset shrinks by 2
--                     4 CORE_PICK  item pickups in actor order; CORE_SPEC
--                                  secret and toxic floor
--                     5 CORE_USE   door, locked door or exit switch ahead
--                     6 CORE_WPN   weapon select, cooldown, fire; CORE_HS_*
--                                  hitscan against last frame's spans;
--                                  after a shot CORE_AL_* (Game.alert):
--                                  flood fill from the player's cell over
--                                  open cells (4096 x 12 queue BRAM, 4096
--                                  x 1 visited RAM cleared via the queue),
--                                  then each sleeping, living, non-ambush
--                                  monster in LOOK in a reached cell wakes
--                     7 CORE_ACT_* actors 0..31 (LOOK, CHASE, FLY, timers)
--                     8 CORE_DOORS door table, then CORE_WORLD (boss timer,
--                                  flashes, message timer, death check)
--                   CORE_END   sprite table (one map read per active actor
--                              for its light) into the back half of the
--                              sprite RAM; key positions
--                   CORE_CRC_* CRC-32 of the 91 state words, 8 bytes each
--                   CORE_OUT   outputs registered, render_start_o pulse,
--                              sprite RAM halves swap, sounds go out
--
--                 Subroutines: none is ever active twice at once, so each
--                 has its own return-state register (*_ret); a tail call
--                 passes its own return state on (DAMAGE -> SOUND).
--                   CORE_WAIT     1-clock read of map, span or z port
--                   CORE_BOX      box (2 x 2 cells) against solid cells
--                   CORE_LOS      Bresenham line of sight, map per cell
--                   CORE_DB       door blocked by the player or an actor
--                   CORE_SND      sound command: volume, pan on the DSP
--                   CORE_DP       damage to the player (armor, sound)
--                   CORE_ENTER    actor enters a state, runs its action
--                   CORE_SPAWN    new actor in the first free slot
--
--                 Memories: actor table 32 x 64 LUT RAM (write port shared
--                 with the loader, read ports for the core and the state
--                 read-out); sprite table 2 x 32 x 64 LUT RAM (double
--                 buffered, 1-clock read); sine ROM (registered). Map,
--                 span and z-buffer ports are 1-clock reads.
--                 Formats: player Q6.16 (24-bit signed working copies),
--                 actors Q6.10, sin/cos Q2.16. Actor word as game_pkg
--                 ACTOR_*; bit 63 ambush (deaf to sound alerts).
--                 Multiplies: pan (rx * -sin + ry * cos) and peek offset
--                 share one 24 x 18 multiplier (1 clock, 2 DSP48 as Vivado
--                 duplicates it into the pan sum); other products are
--                 shift-adds by small constants.
--                 Timing: actor RAM read port 1 and the write port are
--                 registered (each read takes CORE_WAIT); the working
--                 actor's distance, deltas and volume (a_*) are registered
--                 one clock behind it.
--                 Strobes that act in their state's clock (alert queue,
--                 visited bits, map write, CRC feed, sine ROM address) are
--                 concurrent decodes of core_state.
--                 Clock domain: clk_i (system). Golden session
--                 (tb_game_core): PLAYING average 1,324 clocks per frame,
--                 worst 1,456; a level load adds the loader's time plus
--                 about 4,200 clocks (actor totals, secret count).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, game_pkg,
--                 game_tables_pkg, render_pkg (SIN_TABLE), render_types_pkg,
--                 core_crc
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Actors, weapons, game flow, sounds
-- Revision 2.10 - Floor heights, ramps, falling, sprite floors;
--                 effects register fx_o (light type offsets, animation
--                 frame), sprite lights offset by their tile's light type
-- Revision 3.00 - Sound alerts (S_AL_* flood fill), ambush flag (bit
--                 63)
-- Revision 3.10 - Plain signals instead of records; one-process state machine
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
	-- Heights (units, 64 per tile): step-up limit, player and monster headroom (both 40), gravity
	constant STEP_MAX: natural := 24;
	constant BODY_H: natural := 40; -- PLAYER_H = ACTOR_H = 40
	constant FALL_ACC: natural := 2;
	constant FALL_MAX: natural := 16;

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

	-- Actor word flag bits (game_pkg ACTOR_FLAGS_*, plus ambush bit 63)
	constant ACTOR_ACTIVE: natural := ACTOR_FLAGS_LO;
	constant ACTOR_SOLID: natural := ACTOR_FLAGS_LO + 1;
	constant ACTOR_AWAKE: natural := ACTOR_FLAGS_LO + 2;
	constant ACTOR_AMBUSH: natural := 63;

	-- Sound ids (actors.py)
	constant SND_PISTOL: natural := 0;
	constant SND_SHOTGUN: natural := 1;
	constant SND_DOOR_OPEN: natural := 2;
	constant SND_DOOR_CLOSE: natural := 3;
	constant SND_ITEM: natural := 4;
	constant SND_WEAPON: natural := 5;
	constant SND_PLAYER_PAIN: natural := 6;
	constant SND_PLAYER_DEATH: natural := 7;
	constant SND_SIGHT: natural := 8;
	constant SND_SHOOT: natural := 9;
	constant SND_FIRE: natural := 10;
	constant SND_EXPLODE: natural := 11;
	constant SND_CLAW: natural := 12;
	constant SND_PAIN: natural := 13;
	constant SND_DEATH: natural := 14;
	constant SND_SWITCH: natural := 15;
	constant SND_NOWAY: natural := 16;
	constant SND_BOSS_SIGHT: natural := 17;

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

	type core_state_type is (CORE_INIT, CORE_LOAD, CORE_LOAD_W, CORE_TOTA, CORE_TOT0, CORE_TOT, CORE_TOT_LAST,
		CORE_IDLE, CORE_STEP, CORE_PLAY, CORE_P_SIN, CORE_P_COS, CORE_P_VEL,
		CORE_MOVE, CORE_MOVE_BOX, CORE_AB, CORE_MOVE_NEXT,
		CORE_PEEK, CORE_PEEK_M1, CORE_PEEK_M2, CORE_PEEK_M3, CORE_PEEK2,
		CORE_PICK, CORE_PICK_T, CORE_PICK_N, CORE_SPEC, CORE_SPEC2,
		CORE_USE, CORE_USE2, CORE_UDOOR, CORE_UDOOR2,
		CORE_WPN, CORE_HS_COL, CORE_HS_ZW, CORE_HS_SP, CORE_HS_END, CORE_DA, CORE_HS_WB, CORE_HS_NEXT,
		CORE_ACTORS, CORE_ACT_LD, CORE_ACT_GO, CORE_LOOK, CORE_LOOK2, CORE_LOOK3,
		CORE_CHASE, CORE_CHASE2, CORE_CHASE3, CORE_CHASE3B, CORE_CHASE3C, CORE_CHASE4,
		CORE_CHASE5, CORE_CHASE5B, CORE_CHASE6, CORE_FLY, CORE_FLY2, CORE_FLY3,
		CORE_TICK, CORE_ACT_WB, CORE_ACT_NX,
		CORE_DOORS, CORE_DOOR_OPEN2, CORE_DOOR_CL2, CORE_DOOR_NX, CORE_WORLD,
		CORE_END, CORE_SPR_T, CORE_SPR_L, CORE_SPR_F, CORE_SPR_N, CORE_CRC0, CORE_CRC_W, CORE_CRC_B, CORE_OUT,
		CORE_WAIT, CORE_BOX, CORE_BOX_D, CORE_LOS, CORE_LOS_IT, CORE_LOS_D, CORE_DB, CORE_DB_S,
		CORE_SND, CORE_SND_W, CORE_SND_V, CORE_SND_M1, CORE_SND_M2, CORE_SND_M3, CORE_SND_M4,
		CORE_DP, CORE_DP2, CORE_ENTER,
		CORE_A_SHOOT2, CORE_A_SHOOT3, CORE_A_SHOOT4, CORE_A_FIRE2, CORE_A_MELEE2, CORE_A_DIE2,
		CORE_SPAWN, CORE_SPAWN_S,
		CORE_FAT, CORE_FAT_D, CORE_FAT_N, CORE_FAT_W, CORE_FAT_M, CORE_BFL, CORE_BFL_N,
		CORE_ZF, CORE_ZF2, CORE_LOAD_Z,
		CORE_AL0, CORE_AL_POP, CORE_AL_POPW, CORE_AL_CUR, CORE_AL_NB, CORE_AL_NBD, CORE_AL_LD, CORE_AL_LD2,
		CORE_AL_CHK, CORE_AL_ENT, CORE_AL_WB, CORE_AL_NX, CORE_AL_CLR, CORE_AL_CLRW, CORE_AL_CLR2);

	-- Door table: one array per field, entries 0..7
	type door_cell_t is array (0 to 7) of unsigned(5 downto 0);
	type door_amt_t is array (0 to 7) of signed(7 downto 0);
	type door_state_t is array (0 to 7) of unsigned(1 downto 0);
	type door_timer_t is array (0 to 7) of unsigned(7 downto 0);
	-- Sound command: pan & volume & id, the low bits of snd_data_o (SND_PAN, SND_VOL, SND_ID)
	type snd_queue_t is array (0 to 3) of std_logic_vector(SND_PRI_LO - 1 downto 0);
	type actor_ram_t is array (0 to 31) of std_logic_vector(63 downto 0);
	-- Sound alert flood fill: visit-order queue (BRAM) and visited bits (LUT RAM;
	-- BRAM is the scarcest resource)
	type cell_ram_t is array (0 to 4095) of std_logic_vector(11 downto 0);
	type vis_ram_t is array (0 to 4095) of std_logic;
	type spr_ram_t is array (0 to 63) of std_logic_vector(63 downto 0);
	type flick_t is array (0 to 255) of std_logic;

	-- Actor coordinate (Q6.10) in Q6.16
	function q16(v: unsigned(15 downto 0)) return pos_t is
	begin
		return signed(unsigned'("00" & v & "000000")); -- v << 6, two zero headroom bits on top
	end function;

	-- Game.in_cell() with half size HALF: (cx, cy) is one of the box's 2 x 2 cells.
	-- Unmasked as the model: past the map edge gives -1 or 64, matching no door
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

	-- Flicker of effects frame n (render.light_mods): ((n * 40503) >> 7) & 7 < 3,
	-- as a 256 x 1 constant table (no multiplier)
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

	------------------------------------------------------------------
	-- Registers of the state machine (all reset in its process)
	------------------------------------------------------------------
	signal core_state: core_state_type := CORE_INIT;
	-- Return states of the subroutines
	signal wret, box_ret, los_ret, db_ret, snd_ret: core_state_type := CORE_INIT;
	signal dp_ret, en_ret, sp_ret, fat_ret, bfl_ret: core_state_type := CORE_INIT;
	signal armed: std_logic := '0'; -- frame_start seen, waiting for the snapshot
	signal pending: std_logic := '0'; -- A snapshot is waiting in snap_in
	signal snap_in: std_logic_vector(SNAP_BITS - 1 downto 0) := (others => '0');
	signal snap: std_logic_vector(SNAP_BITS - 1 downto 0) := (others => '0'); -- This step's snapshot
	signal in_step: std_logic := '0'; -- Level load inside a step (else after reset)
	-- Game state (Game attributes)
	signal flow: unsigned(2 downto 0) := FL_TITLE;
	signal level: unsigned(1 downto 0) := "01";
	signal prev_fire: std_logic := '0';
	signal debug: std_logic := '0';
	-- Player, and its copy at the level start (saved_*, DEAD restart)
	signal pl_health: unsigned(7 downto 0) := to_unsigned(100, 8);
	signal pl_armor: unsigned(7 downto 0) := (others => '0');
	signal pl_bullets: unsigned(7 downto 0) := to_unsigned(50, 8);
	signal pl_shells: unsigned(5 downto 0) := (others => '0');
	signal pl_weapons: unsigned(1 downto 0) := "01"; -- Bit 0 pistol, bit 1 shotgun
	signal pl_weapon: unsigned(1 downto 0) := "01"; -- 1 pistol, 2 shotgun
	signal saved_health: unsigned(7 downto 0) := to_unsigned(100, 8);
	signal saved_armor: unsigned(7 downto 0) := (others => '0');
	signal saved_bullets: unsigned(7 downto 0) := to_unsigned(50, 8);
	signal saved_shells: unsigned(5 downto 0) := (others => '0');
	signal saved_weapons: unsigned(1 downto 0) := "01";
	signal saved_weapon: unsigned(1 downto 0) := "01";
	signal px, py: pos_t := (others => '0');
	signal angle: unsigned(9 downto 0) := (others => '0');
	signal eye: unsigned(6 downto 0) := to_unsigned(32, 7);
	signal z: unsigned(7 downto 0) := (others => '0'); -- Floor contact height (units)
	signal vz: unsigned(4 downto 0) := (others => '0'); -- Fall speed 0..16
	signal off: signed(5 downto 0) := (others => '0'); -- Peek offset -16..16
	signal cam_x, cam_y: pos_t := (others => '0');
	signal keys: unsigned(1 downto 0) := (others => '0');
	signal cooldown: unsigned(5 downto 0) := (others => '0');
	signal flash: unsigned(2 downto 0) := (others => '0');
	signal dflash: unsigned(3 downto 0) := (others => '0'); -- damage_flash
	signal pflash: unsigned(2 downto 0) := (others => '0'); -- pickup_flash
	signal msg: unsigned(3 downto 0) := (others => '0');
	signal msg_timer: unsigned(6 downto 0) := (others => '0');
	signal phase: unsigned(4 downto 0) := (others => '0');
	signal kills, items, tkills, titems: unsigned(5 downto 0) := (others => '0');
	signal secrets, tsecrets: unsigned(3 downto 0) := (others => '0');
	signal t_frames, t_sec: unsigned(5 downto 0) := (others => '0');
	signal t_min: unsigned(6 downto 0) := (others => '0');
	signal lfsr: unsigned(15 downto 0) := (others => '0');
	signal boss_timer: unsigned(7 downto 0) := (others => '0');
	signal level_done: std_logic := '0';
	signal dead_timer: unsigned(5 downto 0) := (others => '0'); -- Saturates at 63 (only "> 30" matters)
	signal automap: std_logic := '0';
	signal on_toxic: std_logic := '0'; -- Last specials() found toxic floor (kept across levels, as the model)
	signal door_x, door_y: door_cell_t := (others => (others => '0'));
	signal door_amt: door_amt_t := (others => (others => '0')); -- Open amount 0..64
	signal door_state: door_state_t := (others => DS_IDLE);
	signal door_timer: door_timer_t := (others => (others => '0'));
	-- Movement
	signal cs, sn: trig_t := (others => '0');
	signal mdx, mdy: pos_t := (others => '0'); -- This frame's move
	signal my: std_logic := '0'; -- Moving along y (else x)
	-- Map read and box test
	signal maddr: unsigned(11 downto 0) := (others => '0'); -- y & x
	signal bx, by: pos_t := (others => '0'); -- Box center, Q6.16
	signal bsmall: std_logic := '0'; -- Camera box (CAM_HALF), else HALF
	signal bk: unsigned(1 downto 0) := (others => '0'); -- Box corner: bit 0 picks x, bit 1 picks y
	signal hit: std_logic := '0';
	signal bz: unsigned(7 downto 0) := (others => '0'); -- Height of the body the box test is for
	-- floor_at() and box_floor()
	signal fpx, fpy: pos_t := (others => '0'); -- Point, Q6.16
	signal ff: unsigned(7 downto 0) := (others => '0'); -- Floor of the point's tile
	signal fs: unsigned(16 downto 0) := (others => '0'); -- Ramp: distance from the low end, 0..65536
	signal fat: unsigned(7 downto 0) := (others => '0'); -- Result of floor_at()
	signal bfk: unsigned(1 downto 0) := (others => '0'); -- box_floor() corner
	signal bfl: unsigned(7 downto 0) := (others => '0'); -- Result of box_floor()
	-- Line of sight
	signal lx, ly, lx1, ly1: unsigned(5 downto 0) := (others => '0');
	signal ldx, ldy: signed(7 downto 0) := (others => '0');
	signal lsx, lsy: signed(1 downto 0) := (others => '0');
	signal lerr: signed(8 downto 0) := (others => '0');
	signal lcnt: unsigned(6 downto 0) := (others => '0');
	signal los: std_logic := '0';
	-- Doors
	signal di: unsigned(2 downto 0) := (others => '0');
	signal blocked: std_logic := '0';
	-- Sounds
	signal snd_id: unsigned(4 downto 0) := (others => '0');
	signal snd_act: std_logic := '0'; -- Sound comes from actor a (else full volume, centre)
	signal svol: unsigned(5 downto 0) := (others => '0');
	signal mul_a: signed(23 downto 0) := (others => '0'); -- Shared multiplier operands
	signal mul_b: trig_t := (others => '0');
	signal acc: signed(41 downto 0) := (others => '0');
	signal lat: signed(15 downto 0) := (others => '0'); -- Pan before the clamp
	signal sq: snd_queue_t := (others => (others => '0')); -- This step's commands
	signal oq: snd_queue_t := (others => (others => '0')); -- Last step's commands, going out
	signal sq_n, oq_n, oq_p: unsigned(2 downto 0) := (others => '0');
	signal dmg: unsigned(5 downto 0) := (others => '0'); -- DAMAGE argument
	-- Actors: working copy a_* of actor ai
	signal a_x, a_y: unsigned(15 downto 0) := (others => '0'); -- Q6.10
	signal a_state: unsigned(6 downto 0) := (others => '0');
	signal a_timer: unsigned(5 downto 0) := (others => '0');
	signal a_health: unsigned(11 downto 0) := (others => '0'); -- Fireball: direction; item: kind
	signal a_typ: unsigned(2 downto 0) := (others => '0');
	signal a_active, a_solid, a_awake, a_ambush: std_logic := '0';
	signal ai: unsigned(4 downto 0) := (others => '0');
	signal aaddr: unsigned(4 downto 0) := (others => '0'); -- Actor RAM read address (port 1)
	signal en_s: unsigned(6 downto 0) := (others => '0'); -- ENTER argument
	signal sp_type: unsigned(2 downto 0) := (others => '0'); -- SPAWN arguments
	signal sp_state: unsigned(6 downto 0) := (others => '0');
	signal sp_health: unsigned(11 downto 0) := (others => '0');
	signal cdist: unsigned(18 downto 0) := (others => '0'); -- dist(a) in CHASE
	signal csx, csy: signed(7 downto 0) := (others => '0'); -- CHASE step
	-- Hitscan
	signal hk: unsigned(2 downto 0) := (others => '0'); -- Column 136 + 8 hk
	signal hshot: std_logic := '0'; -- Shotgun: all 7 columns
	signal hdmg: unsigned(5 downto 0) := (others => '0');
	signal zw: unsigned(15 downto 0) := (others => '0');
	signal span_addr: unsigned(4 downto 0) := (others => '0');
	signal zw_addr: unsigned(8 downto 0) := (others => '0');
	signal best_v: std_logic := '0';
	signal best_i: unsigned(4 downto 0) := (others => '0');
	signal best_z: unsigned(15 downto 0) := (others => '0');
	-- Totals after a load
	signal tp1: std_logic := '0'; -- map_data_i holds the tile of the address before
	-- Sprite table and checksum
	signal spr_n: unsigned(5 downto 0) := (others => '0');
	signal spr_e: std_logic_vector(63 downto 0) := (others => '0');
	signal spr_ty: std_logic_vector(1 downto 0) := (others => '0'); -- Light type of the sprite's tile
	signal fxn: unsigned(7 downto 0) := (others => '0'); -- Effects frame (t_sec * 60 + t_frames) mod 256
	signal lm: std_logic_vector(4 * FX_LMOD_W - 1 downto 0) := (others => '0'); -- Light offsets of this frame
	signal kp: std_logic_vector(KEYPOS_BITS - 1 downto 0) := (others => '0');
	signal bank: std_logic := '0'; -- Sprite RAM half the renderer reads
	signal cw: unsigned(6 downto 0) := (others => '0'); -- CRC word 0..90
	signal cb: unsigned(2 downto 0) := (others => '0'); -- CRC byte 0..7
	signal cword: std_logic_vector(63 downto 0) := (others => '0'); -- Shifts one byte right per CRC byte
	-- Pulses and output registers
	signal load_req, loaded, start: std_logic := '0';
	signal cam_x_out, cam_y_out: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal angle_out: std_logic_vector(ANGLE_BITS - 1 downto 0) := (others => '0');
	signal eye_out: std_logic_vector(EYE_BITS - 1 downto 0) := (others => '0');
	signal doors_out: std_logic_vector(DOORS_BITS - 1 downto 0) := (others => '0');
	signal player_x_out, player_y_out: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal hud_out: std_logic_vector(HUD_BITS - 1 downto 0) := (others => '0');
	signal keypos_out: std_logic_vector(KEYPOS_BITS - 1 downto 0) := (others => '0');
	signal music_out, tint_out: std_logic_vector(1 downto 0) := (others => '0');
	signal fx_out: std_logic_vector(FX_BITS - 1 downto 0) := (others => '0');
	signal spr_count_out: std_logic_vector(5 downto 0) := (others => '0');
	signal crc_out: std_logic_vector(31 downto 0) := (others => '0');
	-- Sound alert: queue head and tail (tail is the clear index afterwards), queue
	-- read address, cell (y & x), neighbor 0..3 (+x, -x, +y, -y), neighbor cell,
	-- visited-RAM address
	signal qhead, qtail: unsigned(12 downto 0) := (others => '0');
	signal qra, cur, ncell, vaddr: unsigned(11 downto 0) := (others => '0');
	signal nk: unsigned(1 downto 0) := (others => '0');
	-- Write ports of the actor and sprite RAMs, registered in the state machine
	signal aram_we: std_logic := '0';
	signal aram_waddr: unsigned(4 downto 0) := (others => '0');
	signal aram_wdata: std_logic_vector(63 downto 0) := (others => '0');
	signal spr_we: std_logic := '0';
	signal spr_waddr: unsigned(5 downto 0) := (others => '0');
	signal spr_wdata: std_logic_vector(63 downto 0) := (others => '0');

	------------------------------------------------------------------
	-- Memories and registered helpers (no reset)
	------------------------------------------------------------------
	signal rom_addr: unsigned(9 downto 0);
	signal rom_data: trig_t := (others => '0');
	signal prod: signed(41 downto 0) := (others => '0');
	signal aram: actor_ram_t := (others => (others => '0'));
	signal aram_q2: std_logic_vector(63 downto 0);
	signal aw1: std_logic_vector(63 downto 0); -- Port 1 before its register
	signal aw1_x, aw1_y: pos_t; -- Its position in Q6.16
	signal aq: std_logic_vector(63 downto 0) := (others => '0'); -- Registered port 1 read
	signal hit_block, hit_pick, hit_door: std_logic := '0'; -- Scan tests of aq
	signal adist: unsigned(18 downto 0) := (others => '0'); -- Registered helpers of actor a
	signal atx, aty: signed(18 downto 0) := (others => '0');
	signal avol: unsigned(5 downto 0) := (others => '0');
	signal sdx, sdy: unsigned(13 downto 0) := (others => '0');
	signal sdist: unsigned(15 downto 0) := (others => '0');
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
	signal sram: spr_ram_t := (others => (others => '0'));
	signal spr_q: std_logic_vector(63 downto 0) := (others => '0');
	signal waddr: unsigned(6 downto 0); -- State word mux address
	signal word: std_logic_vector(63 downto 0);
	signal sdata: std_logic_vector(63 downto 0) := (others => '0');
	signal map_we: std_logic;
	signal crc_init, crc_valid: std_logic;
	signal crc_byte: std_logic_vector(7 downto 0);
	signal crc: std_logic_vector(31 downto 0);
	-- Door entry of cell maddr (8: none), its fully-open flag, first idle entry
	-- (8: none); registered, as every reader is a clock after the change
	signal didx: natural range 0 to 8 := 8;
	signal dopen: std_logic := '0';
	signal dfree: natural range 0 to 8 := 8;

	------------------------------------------------------------------
	-- Combinational helpers (concurrent assignments)
	------------------------------------------------------------------
	-- Fields of the registered actor word aq, and table lookups
	signal q_x, q_y: unsigned(15 downto 0);
	signal q_state: unsigned(6 downto 0);
	signal q_health: unsigned(11 downto 0);
	signal q_typ: unsigned(2 downto 0);
	signal q_kind: natural range 0 to 7; -- Item kind (health 2:0)
	signal q_k, a_k: natural range 0 to 3; -- TYPE_TABLE rows of q and a
	signal q_frame: unsigned(4 downto 0); -- State art frame of q
	signal q_art: unsigned(7 downto 0); -- Sprite art frame of q
	signal a_word: std_logic_vector(63 downto 0); -- a_* packed
	signal a_act, en_act: natural range 0 to 15; -- Actions of a_state and en_s
	signal a_next: unsigned(6 downto 0); -- Next state of a_state
	signal en_dur, sp_dur: unsigned(5 downto 0); -- Durations of en_s and sp_state
	signal a_spd: natural range 0 to 255;
	signal a_dx, a_dy: signed(18 downto 0); -- (px >> 6) - a_x, (py >> 6) - a_y
	-- Player and game
	signal lfsr_n: unsigned(15 downto 0); -- Next random state
	signal go: std_logic; -- Use, or fire newly pressed (not held)
	signal took: std_logic; -- Pickup q_kind is taken
	signal wpn_next: unsigned(1 downto 0); -- Weapon after this frame's selection
	signal eye_t: unsigned(6 downto 0);
	signal peek_t: signed(5 downto 0);
	signal vel_x, vel_y: signed(19 downto 0);
	signal flush_xp, flush_xn, flush_yp, flush_yn: pos_t;
	signal fall_v: unsigned(4 downto 0);
	signal use_x, use_y: pos_t;
	signal pcell, use_cell, nb_cell: unsigned(11 downto 0);
	signal box_x0, box_x1, box_y0, box_y1: pos_t;
	signal da_hp: signed(12 downto 0);
	signal arm_21, arm_save: unsigned(9 downto 0);
	-- Tile word map_data_i
	signal map_sp: natural range 0 to 7;
	signal map_floor: unsigned(5 downto 0);
	signal map_ceil: unsigned(6 downto 0);
	signal map_top: unsigned(8 downto 0);
	signal map_solid, map_hblk: std_logic;
	signal al_open: std_logic;
	signal dk: natural range 0 to 7; -- Door table entry di
	-- Line of sight step
	signal los_dx, los_dy: signed(7 downto 0);
	signal los_e2, los_nerr: signed(8 downto 0);
	signal los_sx, los_sy, los_tx, los_ty: std_logic;
	signal los_nx, los_ny: unsigned(5 downto 0);
	-- Actors, sounds, sprites
	signal fly_x, fly_y: unsigned(15 downto 0);
	signal dir_ax, dir_ay: unsigned(21 downto 0);
	signal dir_sub, fire_dir: unsigned(3 downto 0);
	signal snd_min: unsigned(13 downto 0);
	signal vol_t: unsigned(10 downto 0);
	signal vol_p: unsigned(17 downto 0);
	signal vol: unsigned(5 downto 0);
	signal pan_sum: signed(42 downto 0);
	signal pan_c: signed(5 downto 0);
	signal oq_word: std_logic_vector(SND_PRI_LO - 1 downto 0);
	signal lm_f: signed(FX_LMOD_W - 1 downto 0);
	signal lm_tri: unsigned(2 downto 0);
	signal lm_next: std_logic_vector(4 * FX_LMOD_W - 1 downto 0);
	signal spr_lmod: signed(FX_LMOD_W - 1 downto 0);
	signal spr_lsum: signed(5 downto 0);
	signal spr_light: std_logic_vector(3 downto 0);
begin
	------------------------------------------------------------------
	-- Sine ROM (cos(a) = sin(a + 256)), registered read
	------------------------------------------------------------------
	rom_addr <= angle + 256 when (core_state = CORE_P_COS) else angle;

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
			prod <= mul_a * mul_b;
		end if;
	end process;

	------------------------------------------------------------------
	-- Actor table, 32 x 64 LUT RAM. One write port (the loader's during a load),
	-- registered one clock as the write enable is decided late. Core reads go
	-- through CORE_WAIT, so they never pass an earlier write. Port 1 at aaddr
	-- for the core, port 2 for the state words
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (aram_we = '1') then
				aram(to_integer(aram_waddr)) <= aram_wdata;
			end if;
		end if;
	end process;

	-- Port 1 is registered (data one clock later, after CORE_WAIT), with three
	-- scan tests (inputs are stable during a scan): actor blocks the move box,
	-- item under the player, actor in door di's cell
	aw1 <= aram(to_integer(aaddr));
	aw1_x <= q16(unsigned(aw1(ACTOR_X_HI downto ACTOR_X_LO)));
	aw1_y <= q16(unsigned(aw1(ACTOR_Y_HI downto ACTOR_Y_LO)));

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			aq <= aw1;
			hit_block <= '0';
			hit_pick <= '0';
			hit_door <= '0';
			if ((aw1(ACTOR_ACTIVE) = '1') and (aw1(ACTOR_SOLID) = '1') and
				(unsigned(abs(aw1_x - bx)) < BLOCK_RANGE) and (unsigned(abs(aw1_y - by)) < BLOCK_RANGE)) then
				hit_block <= '1';
			end if;
			if ((aw1(ACTOR_ACTIVE) = '1') and (unsigned(aw1(ACTOR_TYPE_HI downto ACTOR_TYPE_LO)) = T_ITEM) and
				(unsigned(abs(aw1_x - px)) < PICK_RANGE) and (unsigned(abs(aw1_y - py)) < PICK_RANGE)) then
				hit_pick <= '1';
			end if;
			if ((aw1(ACTOR_ACTIVE) = '1') and (aw1(ACTOR_SOLID) = '1') and
				in_cell(aw1_x, aw1_y, door_x(dk), door_y(dk))) then
				hit_door <= '1';
			end if;
		end if;
	end process;
	aram_q2 <= aram(to_integer(waddr(4 downto 0) - 27)); -- Word 59 + j is actor j (59 = 27 mod 32)

	-- Fields of aq and the tables they index
	q_x <= unsigned(aq(ACTOR_X_HI downto ACTOR_X_LO));
	q_y <= unsigned(aq(ACTOR_Y_HI downto ACTOR_Y_LO));
	q_state <= unsigned(aq(ACTOR_STATE_HI downto ACTOR_STATE_LO));
	q_health <= unsigned(aq(ACTOR_HEALTH_HI downto ACTOR_HEALTH_LO));
	q_typ <= unsigned(aq(ACTOR_TYPE_HI downto ACTOR_TYPE_LO));
	q_kind <= to_integer(q_health(2 downto 0));
	q_k <= to_integer(q_typ(1 downto 0)); -- Monster types 0..3 (only monsters ever ask)
	q_frame <= unsigned(STATE_TABLE(to_integer(q_state))(STATE_FRAME_HI downto STATE_FRAME_LO));
	-- Art frame: items 38 + kind, fireballs 38 + state frame, monsters
	-- 0 / 9 / 18 / 27 + state frame (art.py)
	q_art <= to_unsigned(ITEM_BASE, 8) + resize(q_health(2 downto 0), 8) when (q_typ = T_ITEM) else
		to_unsigned(ITEM_BASE, 8) + resize(q_frame, 8) when (q_typ = T_FIREBALL) else
		to_unsigned(9 * q_k, 8) + resize(q_frame, 8);

	-- The working actor packed for a write back, and its tables
	a_word <= a_ambush & a_awake & a_solid & a_active & std_logic_vector(a_typ) & std_logic_vector(a_health) &
		std_logic_vector(a_timer) & std_logic_vector(a_state) & std_logic_vector(a_y) & std_logic_vector(a_x);
	a_k <= to_integer(a_typ(1 downto 0));
	a_spd <= TYPE_TABLE(a_k)(TP_SPEED);
	a_act <= to_integer(unsigned(STATE_TABLE(to_integer(a_state))(STATE_ACTION_HI downto STATE_ACTION_LO)));
	a_next <= unsigned(STATE_TABLE(to_integer(a_state))(STATE_NEXT_HI downto STATE_NEXT_LO));
	en_act <= to_integer(unsigned(STATE_TABLE(to_integer(en_s))(STATE_ACTION_HI downto STATE_ACTION_LO)));
	en_dur <= unsigned(STATE_TABLE(to_integer(en_s))(STATE_DUR_HI downto STATE_DUR_LO));
	sp_dur <= unsigned(STATE_TABLE(to_integer(sp_state))(STATE_DUR_HI downto STATE_DUR_LO));

	-- Alert queue and visited bits: write in the asking state's clock, read one
	-- clock after the address register
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (al_qwe = '1') then
				alq(to_integer(al_qwaddr)) <= al_qwdata;
			end if;
			alq_q <= alq(to_integer(qra));
		end if;
	end process;

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (al_vwe = '1') then
				vis(to_integer(al_vwaddr)) <= al_vwdata;
			end if;
			vis_q <= vis(to_integer(vaddr));
		end if;
	end process;

	-- CORE_AL0 queues and marks the player's cell; CORE_AL_NBD an open,
	-- unvisited neighbor; CORE_AL_CLR2 clears the bit of a queued cell
	al_open <= '1' when ((vis_q = '0') and (map_solid = '0')) else '0';
	al_qwe <= '1' when ((core_state = CORE_AL0) or ((core_state = CORE_AL_NBD) and (al_open = '1'))) else '0';
	al_qwaddr <= to_unsigned(0, 12) when (core_state = CORE_AL0) else qtail(11 downto 0);
	al_qwdata <= std_logic_vector(pcell) when (core_state = CORE_AL0) else std_logic_vector(ncell);
	al_vwe <= '1' when ((core_state = CORE_AL0) or (core_state = CORE_AL_CLR2) or
		((core_state = CORE_AL_NBD) and (al_open = '1'))) else '0';
	al_vwaddr <= pcell when (core_state = CORE_AL0) else
		unsigned(alq_q) when (core_state = CORE_AL_CLR2) else
		ncell;
	al_vwdata <= '0' when (core_state = CORE_AL_CLR2) else '1';

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			didx <= 8;
			dopen <= '0';
			dfree <= 8;
			for k in 7 downto 0 loop -- Counting down: the lowest entry wins
				if ((door_state(k) /= DS_IDLE) and ((door_y(k) & door_x(k)) = maddr)) then
					didx <= k;
					if (door_amt(k) = DOOR_OPEN) then
						dopen <= '1';
					else
						dopen <= '0';
					end if;
				end if;
				if (door_state(k) = DS_IDLE) then
					dfree <= k;
				end if;
			end loop;
		end if;
	end process;

	------------------------------------------------------------------
	-- Helpers of the working actor a, registered one clock behind it to keep the
	-- arithmetic off the state decode; users come a clock after a_x, a_y, px or
	-- py change. Sound volume takes three clocks; CORE_SND waits two
	------------------------------------------------------------------
	a_dx <= resize(px(23 downto 6), 19) - signed(resize(a_x, 19));
	a_dy <= resize(py(23 downto 6), 19) - signed(resize(a_y, 19));
	-- Sound distance d = dx + dy - min / 2 in 1/64 tiles; volume 63 up to 200, 0
	-- from 1200, else min(63, ((1200 - d) * 65) >> 10)
	snd_min <= sdx when (sdx < sdy) else sdy;
	vol_t <= resize(1200 - sdist, 11);
	vol_p <= shift_left(resize(vol_t, 18), 6) + vol_t;
	vol <= to_unsigned(63, 6) when (sdist <= 200) else
		to_unsigned(0, 6) when (sdist >= 1200) else
		to_unsigned(63, 6) when (vol_p(17 downto 10) > 63) else
		vol_p(15 downto 10);

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			adist <= unsigned(abs(a_dx)) + unsigned(abs(a_dy)); -- Game.dist(), Q6.10
			atx <= a_dx;
			aty <= a_dy;
			sdx <= resize(shift_right(unsigned(abs(q16(a_x) - px)), 10), 14);
			sdy <= resize(shift_right(unsigned(abs(q16(a_y) - py)), 10), 14);
			sdist <= resize(sdx, 16) + sdy - shift_right(snd_min, 1);
			avol <= vol;
		end if;
	end process;

	------------------------------------------------------------------
	-- Sprite table, 2 x 32 entries: the core fills half (not bank)
	-- during the step, the renderer reads half bank; they swap at
	-- render_start_o
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (spr_we = '1') then
				sram(to_integer(spr_waddr)) <= spr_wdata;
			end if;
			spr_q <= sram(to_integer(unsigned(bank & spr_addr_i))); -- Address bit 5 picks the half
		end if;
	end process;

	------------------------------------------------------------------
	-- State words (game.state_words()): the CRC walk reads them in
	-- CORE_CRC_W, the read-out port at other times
	------------------------------------------------------------------
	waddr <= cw when (core_state = CORE_CRC_W) else unsigned(state_addr_i);

	process(waddr, flow, level, px, py, angle, eye, z, vz, off, pl_health, pl_armor, pl_bullets, pl_shells,
		pl_weapons, pl_weapon, keys, cooldown, kills, items, secrets, lfsr, door_x, door_y, door_amt,
		door_state, door_timer, aram_q2)
		variable dw: natural range 0 to 39; -- Door word: entry dw / 5, field dw mod 5
	begin
		word <= (others => '0');
		case to_integer(waddr) is
			when 0 =>
				word(2 downto 0) <= std_logic_vector(flow);
			when 1 =>
				word(1 downto 0) <= std_logic_vector(level);
			when 2 =>
				word(21 downto 0) <= std_logic_vector(px(21 downto 0));
			when 3 =>
				word(21 downto 0) <= std_logic_vector(py(21 downto 0));
			when 4 =>
				word(9 downto 0) <= std_logic_vector(angle);
			when 5 =>
				-- eye | z << 8 | vz << 16 (z and vz are 0 on flat levels)
				word(6 downto 0) <= std_logic_vector(eye);
				word(15 downto 8) <= std_logic_vector(z);
				word(20 downto 16) <= std_logic_vector(vz);
			when 6 =>
				word(7 downto 0) <= std_logic_vector(resize(off, 8)); -- off & 0xFF
			when 7 =>
				word(7 downto 0) <= std_logic_vector(pl_health);
			when 8 =>
				word(7 downto 0) <= std_logic_vector(pl_armor);
			when 9 =>
				word(7 downto 0) <= std_logic_vector(pl_bullets);
			when 10 =>
				word(5 downto 0) <= std_logic_vector(pl_shells);
			when 11 =>
				word(1 downto 0) <= std_logic_vector(pl_weapons);
			when 12 =>
				word(1 downto 0) <= std_logic_vector(pl_weapon);
			when 13 =>
				word(1 downto 0) <= std_logic_vector(keys);
			when 14 =>
				word(5 downto 0) <= std_logic_vector(cooldown);
			when 15 =>
				word(5 downto 0) <= std_logic_vector(kills);
			when 16 =>
				word(5 downto 0) <= std_logic_vector(items);
			when 17 =>
				word(3 downto 0) <= std_logic_vector(secrets);
			when 18 =>
				word(15 downto 0) <= std_logic_vector(lfsr);
			when 19 to 58 =>
				-- Doors: 5 words each (x, y, open, state, timer)
				dw := to_integer(waddr) - 19;
				case dw mod 5 is
					when 0 =>
						word(5 downto 0) <= std_logic_vector(door_x(dw / 5));
					when 1 =>
						word(5 downto 0) <= std_logic_vector(door_y(dw / 5));
					when 2 =>
						word(7 downto 0) <= std_logic_vector(door_amt(dw / 5));
					when 3 =>
						word(1 downto 0) <= std_logic_vector(door_state(dw / 5));
					when others =>
						word(7 downto 0) <= std_logic_vector(door_timer(dw / 5));
				end case;
			when 59 to 90 =>
				word <= aram_q2;
			when others =>
				null;
		end case;
	end process;

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			sdata <= word;
		end if;
	end process;

	-- CRC-32 of the state words, 8 bytes each, low first (cword shifts per byte)
	crc_init <= '1' when (core_state = CORE_CRC0) else '0';
	crc_valid <= '1' when (core_state = CORE_CRC_B) else '0';
	crc_byte <= cword(7 downto 0);

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
	-- Combinational helpers of the state machine
	------------------------------------------------------------------
	-- Random: x^16 + x^15 + x^13 + x^4 + 1 (taps 15, 14, 12, 3), shift left;
	-- random() is the new state's low byte
	lfsr_n <= lfsr(14 downto 0) & (lfsr(15) xor lfsr(14) xor lfsr(12) xor lfsr(3));
	go <= snap(SNAP_USE) or (snap(SNAP_FIRE) and not prev_fire);
	eye_t <= to_unsigned(16, 7) when (snap(SNAP_DUCK) = '1') else to_unsigned(32, 7);
	peek_t <= to_signed(16, 6) when ((snap(SNAP_PEEK_R) = '1') and (snap(SNAP_PEEK_L) = '0')) else
		to_signed(-16, 6) when ((snap(SNAP_PEEK_R) = '0') and (snap(SNAP_PEEK_L) = '1')) else
		to_signed(0, 6);
	-- vx = move cs - strafe sn, vy = move sn + strafe cs (cs on rom_data in CORE_P_VEL)
	vel_x <= times(snap(SNAP_MOVE_HI downto SNAP_MOVE_LO), rom_data) -
		times(snap(SNAP_STRAFE_HI downto SNAP_STRAFE_LO), sn);
	vel_y <= times(snap(SNAP_MOVE_HI downto SNAP_MOVE_LO), sn) +
		times(snap(SNAP_STRAFE_HI downto SNAP_STRAFE_LO), rom_data);
	-- Flush clamps: right / lower side 1 short of the blocking cell, left / upper
	-- side on its far edge
	flush_xp <= ((bx + HALF) and x"FF0000") - HALF - 1;
	flush_xn <= ((bx - HALF) and x"FF0000") + 65536 + HALF;
	flush_yp <= ((by + HALF) and x"FF0000") - HALF - 1;
	flush_yn <= ((by - HALF) and x"FF0000") + 65536 + HALF;
	fall_v <= to_unsigned(FALL_MAX, 5) when (vz + FALL_ACC > FALL_MAX) else vz + FALL_ACC;
	-- Cells (y & x, masked like Game.tile()): the player's, the one 0.75 tile
	-- ahead (c * 3 >> 2) and alert neighbor nk of cur (6-bit wrap, as & 63)
	pcell <= unsigned(std_logic_vector(py(21 downto 16))) & unsigned(std_logic_vector(px(21 downto 16)));
	use_x <= px + resize(shift_right(resize(cs, 20) + shift_left(resize(cs, 20), 1), 2), 24);
	use_y <= py + resize(shift_right(resize(sn, 20) + shift_left(resize(sn, 20), 1), 2), 24);
	use_cell <= unsigned(std_logic_vector(use_y(21 downto 16))) & unsigned(std_logic_vector(use_x(21 downto 16)));
	nb_cell(5 downto 0) <= cur(5 downto 0) + 1 when (nk = "00") else
		cur(5 downto 0) - 1 when (nk = "01") else
		cur(5 downto 0);
	nb_cell(11 downto 6) <= cur(11 downto 6) + 1 when (nk = "10") else
		cur(11 downto 6) - 1 when (nk = "11") else
		cur(11 downto 6);
	-- Box sides around (bx, by); cell index = bits 21:16 of b -/+ half
	box_x0 <= bx - CAM_HALF when (bsmall = '1') else bx - HALF;
	box_x1 <= bx + CAM_HALF when (bsmall = '1') else bx + HALF;
	box_y0 <= by - CAM_HALF when (bsmall = '1') else by - HALF;
	box_y1 <= by + CAM_HALF when (bsmall = '1') else by + HALF;
	-- Weapon select keys, then the cycle key
	wpn_next <= unsigned(snap(SNAP_WSEL_HI downto SNAP_WSEL_LO)) when
		(((snap(SNAP_WSEL_HI downto SNAP_WSEL_LO) = "01") and (pl_weapons(0) = '1')) or
		((snap(SNAP_WSEL_HI downto SNAP_WSEL_LO) = "10") and (pl_weapons(1) = '1'))) else
		"10" when ((snap(SNAP_WCYCLE) = '1') and (pl_weapon = 1) and (pl_weapons(1) = '1')) else
		"01" when (snap(SNAP_WCYCLE) = '1') else
		pl_weapon;
	-- Item kinds 0, 1 health, 2 armor, 3 bullets, 4 shells: taken only below
	-- the cap; 5 shotgun, 6 and 7 keys: always
	took <= '1' when ((((q_kind = 0) or (q_kind = 1)) and (pl_health < 100)) or ((q_kind = 2) and (pl_armor < 100)) or
		((q_kind = 3) and (pl_bullets < 200)) or ((q_kind = 4) and (pl_shells < 50)) or (q_kind >= 5)) else '0';
	da_hp <= signed(resize(q_health, 13)) - signed(resize(hdmg, 13)); -- Signed: overkill goes below 0
	-- Armor takes (dmg * 21) >> 6 (21 = 16 + 4 + 1), at most what is left of it
	arm_21 <= shift_right(shift_left(resize(dmg, 10), 4) + shift_left(resize(dmg, 10), 2) + resize(dmg, 10), 6);
	arm_save <= resize(pl_armor, 10) when (arm_21 > pl_armor) else arm_21;

	-- Tile word on map_data_i: Game.solid() (wall unless a fully open door,
	-- specials 1..3), heights (floor_h * 8, 64 - ceil_h * 8) and Game.blocks()
	-- without solid: step up over STEP_MAX (ramps never) or headroom under BODY_H
	-- for a body at bz
	map_sp <= to_integer(unsigned(map_data_i(TILE_SPECIAL_HI downto TILE_SPECIAL_LO)));
	map_floor <= unsigned(map_data_i(TILE_FLOORH_HI downto TILE_FLOORH_LO)) & "000";
	map_ceil <= to_unsigned(64, 7) - (unsigned(map_data_i(TILE_CEILH_HI downto TILE_CEILH_LO)) & "000");
	map_solid <= '0' when (unsigned(map_data_i(TILE_WALL_HI downto TILE_WALL_LO)) = 0) else
		'0' when ((map_sp >= 1) and (map_sp <= 3) and (dopen = '1')) else
		'1';
	map_top <= resize(map_floor, 9) + BODY_H when (resize(map_floor, 9) > resize(bz, 9)) else resize(bz, 9) + BODY_H;
	map_hblk <= '1' when (((map_sp /= SPECIAL_RAMP) and (resize(map_floor, 9) > resize(bz, 9) + STEP_MAX)) or
		(resize(map_ceil, 9) < map_top)) else '0';
	dk <= to_integer(di);

	-- Line of sight (Game.los()): start deltas, then one Bresenham step
	-- (e2 = 2 err; e2 > -dy steps x, e2 < dx steps y)
	los_dx <= signed(resize(unsigned(std_logic_vector(px(21 downto 16))), 8)) - signed(resize(a_x(15 downto 10), 8));
	los_dy <= signed(resize(unsigned(std_logic_vector(py(21 downto 16))), 8)) - signed(resize(a_y(15 downto 10), 8));
	los_e2 <= shift_left(lerr, 1);
	los_sx <= '1' when (los_e2 > -resize(ldy, 9)) else '0';
	los_sy <= '1' when (los_e2 < resize(ldx, 9)) else '0';
	los_nx <= lx + unsigned(resize(lsx, 6)) when (los_sx = '1') else lx;
	los_ny <= ly + unsigned(resize(lsy, 6)) when (los_sy = '1') else ly;
	los_nerr <= lerr - resize(ldy, 9) + resize(ldx, 9) when ((los_sx = '1') and (los_sy = '1')) else
		lerr - resize(ldy, 9) when (los_sx = '1') else
		lerr + resize(ldx, 9) when (los_sy = '1') else
		lerr;
	-- The step lands on the target's column / row (both outcomes from registers;
	-- los_sx / los_sy pick one)
	los_tx <= '1' when (((los_sx = '1') and (lx + unsigned(resize(lsx, 6)) = lx1)) or
		((los_sx = '0') and (lx = lx1))) else '0';
	los_ty <= '1' when (((los_sy = '1') and (ly + unsigned(resize(lsy, 6)) = ly1)) or
		((los_sy = '0') and (ly = ly1))) else '0';

	-- Fireball: one velocity step (mod 2^16); health holds its FIRE_VEL row 0..15
	fly_x <= a_x + unsigned(to_signed(FIRE_VEL(to_integer(a_health(3 downto 0)))(0), 16));
	fly_y <= a_y + unsigned(to_signed(FIRE_VEL(to_integer(a_health(3 downto 0)))(1), 16));
	-- actors.direction16(): direction 0..15 toward (atx, aty) from compares of
	-- small multiples (5 ay < ax, 3 ay < 2 ax, 2 ay < 3 ax, ay < 5 ax)
	dir_ax <= resize(unsigned(abs(atx)), 22);
	dir_ay <= resize(unsigned(abs(aty)), 22);
	dir_sub <= to_unsigned(0, 4) when (shift_left(dir_ay, 2) + dir_ay < dir_ax) else
		to_unsigned(1, 4) when (shift_left(dir_ay, 1) + dir_ay < shift_left(dir_ax, 1)) else
		to_unsigned(2, 4) when (shift_left(dir_ay, 1) < shift_left(dir_ax, 1) + dir_ax) else
		to_unsigned(3, 4) when (dir_ay < shift_left(dir_ax, 2) + dir_ax) else
		to_unsigned(4, 4);
	fire_dir <= dir_sub when ((atx >= 0) and (aty >= 0)) else
		8 - dir_sub when ((atx < 0) and (aty >= 0)) else
		8 + dir_sub when ((atx < 0) and (aty < 0)) else
		0 - dir_sub; -- (16 - sub) & 15
	-- Pan = clamp((lateral >> 16) >> 11, -31, 31), lateral = acc + prod
	pan_sum <= resize(acc, 43) + resize(prod, 43);
	pan_c <= to_signed(31, 6) when (lat > 31) else
		to_signed(-31, 6) when (lat < -31) else
		lat(5 downto 0);

	-- Light offsets for effects frame fxn (render.light_mods): steady 0, flicker -5
	-- when FLICK, strobe -8 when bit 4, glow -(triangle(n mod 32) / 2); muzzle
	-- flash adds 2 to all. Type k at 5k + 4 .. 5k (signed)
	lm_f <= to_signed(2, FX_LMOD_W) when (flash /= 0) else to_signed(0, FX_LMOD_W);
	lm_tri <= fxn(3 downto 1) when (fxn(4) = '0') else not fxn(3 downto 1); -- triangle / 2
	lm_next(FX_LMOD_W - 1 downto 0) <= std_logic_vector(lm_f);
	lm_next(2 * FX_LMOD_W - 1 downto FX_LMOD_W) <= std_logic_vector(lm_f - 5) when (FLICK(to_integer(fxn)) = '1') else
		std_logic_vector(lm_f);
	lm_next(3 * FX_LMOD_W - 1 downto 2 * FX_LMOD_W) <= std_logic_vector(lm_f - 8) when (fxn(4) = '1') else
		std_logic_vector(lm_f);
	lm_next(4 * FX_LMOD_W - 1 downto 3 * FX_LMOD_W) <= std_logic_vector(lm_f - signed(resize(lm_tri, FX_LMOD_W)));
	-- Sprite light: clamp(tile light + offset of the tile's light type, 0, 15)
	with spr_ty select spr_lmod <=
		signed(lm(FX_LMOD_W - 1 downto 0)) when "00",
		signed(lm(2 * FX_LMOD_W - 1 downto FX_LMOD_W)) when "01",
		signed(lm(3 * FX_LMOD_W - 1 downto 2 * FX_LMOD_W)) when "10",
		signed(lm(4 * FX_LMOD_W - 1 downto 3 * FX_LMOD_W)) when others;
	spr_lsum <= signed(resize(unsigned(spr_e(SPR_LIGHT_HI downto SPR_LIGHT_LO)), 6)) + resize(spr_lmod, 6);
	spr_light <= "0000" when (spr_lsum < 0) else
		"1111" when (spr_lsum > 15) else
		std_logic_vector(spr_lsum(3 downto 0));

	------------------------------------------------------------------
	-- State machine: one Game.step per frame. Map, span, z and actor reads go
	-- through CORE_WAIT: set the address and wret, CORE_WAIT waits a clock, wret
	-- sees the data.
	------------------------------------------------------------------
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			core_state <= CORE_INIT;
			wret <= CORE_INIT;
			box_ret <= CORE_INIT;
			los_ret <= CORE_INIT;
			db_ret <= CORE_INIT;
			snd_ret <= CORE_INIT;
			dp_ret <= CORE_INIT;
			en_ret <= CORE_INIT;
			sp_ret <= CORE_INIT;
			fat_ret <= CORE_INIT;
			bfl_ret <= CORE_INIT;
			armed <= '0';
			pending <= '0';
			snap_in <= (others => '0');
			snap <= (others => '0');
			in_step <= '0';
			flow <= FL_TITLE;
			level <= "01";
			prev_fire <= '0';
			debug <= '0';
			pl_health <= to_unsigned(100, 8);
			pl_armor <= (others => '0');
			pl_bullets <= to_unsigned(50, 8);
			pl_shells <= (others => '0');
			pl_weapons <= "01";
			pl_weapon <= "01";
			saved_health <= to_unsigned(100, 8);
			saved_armor <= (others => '0');
			saved_bullets <= to_unsigned(50, 8);
			saved_shells <= (others => '0');
			saved_weapons <= "01";
			saved_weapon <= "01";
			px <= (others => '0');
			py <= (others => '0');
			angle <= (others => '0');
			eye <= to_unsigned(32, 7);
			z <= (others => '0');
			vz <= (others => '0');
			off <= (others => '0');
			cam_x <= (others => '0');
			cam_y <= (others => '0');
			keys <= (others => '0');
			cooldown <= (others => '0');
			flash <= (others => '0');
			dflash <= (others => '0');
			pflash <= (others => '0');
			msg <= (others => '0');
			msg_timer <= (others => '0');
			phase <= (others => '0');
			kills <= (others => '0');
			items <= (others => '0');
			secrets <= (others => '0');
			tkills <= (others => '0');
			titems <= (others => '0');
			tsecrets <= (others => '0');
			t_frames <= (others => '0');
			t_sec <= (others => '0');
			t_min <= (others => '0');
			lfsr <= (others => '0');
			boss_timer <= (others => '0');
			level_done <= '0';
			dead_timer <= (others => '0');
			automap <= '0';
			on_toxic <= '0';
			door_x <= (others => (others => '0'));
			door_y <= (others => (others => '0'));
			door_amt <= (others => (others => '0'));
			door_state <= (others => DS_IDLE);
			door_timer <= (others => (others => '0'));
			cs <= (others => '0');
			sn <= (others => '0');
			mdx <= (others => '0');
			mdy <= (others => '0');
			my <= '0';
			maddr <= (others => '0');
			bx <= (others => '0');
			by <= (others => '0');
			bsmall <= '0';
			bk <= (others => '0');
			hit <= '0';
			bz <= (others => '0');
			fpx <= (others => '0');
			fpy <= (others => '0');
			ff <= (others => '0');
			fs <= (others => '0');
			fat <= (others => '0');
			bfk <= (others => '0');
			bfl <= (others => '0');
			lx <= (others => '0');
			ly <= (others => '0');
			lx1 <= (others => '0');
			ly1 <= (others => '0');
			ldx <= (others => '0');
			ldy <= (others => '0');
			lsx <= (others => '0');
			lsy <= (others => '0');
			lerr <= (others => '0');
			lcnt <= (others => '0');
			los <= '0';
			di <= (others => '0');
			blocked <= '0';
			snd_id <= (others => '0');
			snd_act <= '0';
			svol <= (others => '0');
			mul_a <= (others => '0');
			mul_b <= (others => '0');
			acc <= (others => '0');
			lat <= (others => '0');
			sq <= (others => (others => '0'));
			sq_n <= (others => '0');
			oq <= (others => (others => '0'));
			oq_n <= (others => '0');
			oq_p <= (others => '0');
			dmg <= (others => '0');
			a_x <= (others => '0');
			a_y <= (others => '0');
			a_state <= (others => '0');
			a_timer <= (others => '0');
			a_health <= (others => '0');
			a_typ <= (others => '0');
			a_active <= '0';
			a_solid <= '0';
			a_awake <= '0';
			a_ambush <= '0';
			ai <= (others => '0');
			aaddr <= (others => '0');
			en_s <= (others => '0');
			sp_type <= (others => '0');
			sp_state <= (others => '0');
			sp_health <= (others => '0');
			cdist <= (others => '0');
			csx <= (others => '0');
			csy <= (others => '0');
			hk <= (others => '0');
			hshot <= '0';
			hdmg <= (others => '0');
			zw <= (others => '0');
			span_addr <= (others => '0');
			zw_addr <= (others => '0');
			best_v <= '0';
			best_i <= (others => '0');
			best_z <= (others => '0');
			tp1 <= '0';
			spr_n <= (others => '0');
			spr_e <= (others => '0');
			spr_ty <= (others => '0');
			fxn <= (others => '0');
			lm <= (others => '0');
			kp <= (others => '0');
			bank <= '0';
			cw <= (others => '0');
			cb <= (others => '0');
			cword <= (others => '0');
			load_req <= '0';
			loaded <= '0';
			start <= '0';
			cam_x_out <= (others => '0');
			cam_y_out <= (others => '0');
			angle_out <= (others => '0');
			eye_out <= (others => '0');
			doors_out <= (others => '0');
			player_x_out <= (others => '0');
			player_y_out <= (others => '0');
			hud_out <= (others => '0');
			keypos_out <= (others => '0');
			music_out <= (others => '0');
			tint_out <= (others => '0');
			fx_out <= (others => '0');
			spr_count_out <= (others => '0');
			crc_out <= (others => '0');
			qhead <= (others => '0');
			qtail <= (others => '0');
			qra <= (others => '0');
			cur <= (others => '0');
			nk <= (others => '0');
			ncell <= (others => '0');
			vaddr <= (others => '0');
			aram_we <= '0';
			aram_waddr <= (others => '0');
			aram_wdata <= (others => '0');
			spr_we <= '0';
			spr_waddr <= (others => '0');
			spr_wdata <= (others => '0');
		elsif rising_edge(clk_i) then
			-- Pulses and write enables last one clock
			load_req <= '0';
			loaded <= '0';
			start <= '0';
			aram_we <= '0';
			spr_we <= '0';

			-- Snapshot capture (any state): the step after a frame start
			if (frame_start_i = '1') then
				armed <= '1';
			end if;
			if ((snapshot_valid_i = '1') and ((armed = '1') or (frame_start_i = '1'))) then
				snap_in <= snapshot_i;
				pending <= '1';
				armed <= '0';
			end if;

			-- Sound commands of the last step go out one per handshake
			if ((oq_p /= oq_n) and (snd_ready_i = '1')) then
				oq_p <= oq_p + 1;
			end if;

			case core_state is
				--------------------------------------------------------------
				-- Level load: request, wait (loader writes the actor RAM), reset, totals
				--------------------------------------------------------------
				when CORE_INIT =>
					-- Game.__init__ loads level 1 (and stays on TITLE)
					in_step <= '0';
					core_state <= CORE_LOAD;

				when CORE_LOAD =>
					load_req <= '1';
					core_state <= CORE_LOAD_W;

				when CORE_LOAD_W =>
					-- The loader owns the actor RAM write port
					aram_we <= act_we_i;
					aram_waddr <= unsigned(act_addr_i);
					aram_wdata <= act_data_i;
					if (load_done_i = '1') then
						px <= signed(resize(unsigned(start_x_i), 24));
						py <= signed(resize(unsigned(start_y_i), 24));
						angle <= unsigned(start_angle_i);
						eye <= to_unsigned(32, 7);
						off <= (others => '0');
						cam_x <= signed(resize(unsigned(start_x_i), 24));
						cam_y <= signed(resize(unsigned(start_y_i), 24));
						keys <= (others => '0');
						cooldown <= (others => '0');
						flash <= (others => '0');
						dflash <= (others => '0');
						pflash <= (others => '0');
						msg <= (others => '0');
						msg_timer <= (others => '0');
						phase <= (others => '0');
						kills <= (others => '0');
						items <= (others => '0');
						secrets <= (others => '0');
						tkills <= (others => '0');
						titems <= (others => '0');
						tsecrets <= (others => '0');
						t_frames <= (others => '0');
						t_sec <= (others => '0');
						t_min <= (others => '0');
						lfsr <= x"ACE1" xor ("000000" & level & x"00"); -- Seed 0xACE1 ^ (level << 8)
						boss_timer <= (others => '0');
						level_done <= '0';
						dead_timer <= (others => '0');
						automap <= '0';
						door_x <= (others => (others => '0'));
						door_y <= (others => (others => '0'));
						door_amt <= (others => (others => '0'));
						door_state <= (others => DS_IDLE);
						door_timer <= (others => (others => '0'));
						aaddr <= (others => '0');
						wret <= CORE_TOTA;
						core_state <= CORE_WAIT;
					end if;

				when CORE_TOTA =>
					-- Monsters (types 0..3) and items among the active actors
					if (aq(ACTOR_ACTIVE) = '1') then
						if (q_typ < 4) then
							tkills <= tkills + 1;
						elsif (q_typ = T_ITEM) then
							titems <= titems + 1;
						end if;
					end if;
					if (aaddr = 31) then
						core_state <= CORE_TOT0;
					else
						aaddr <= aaddr + 1;
						wret <= CORE_TOTA;
						core_state <= CORE_WAIT;
					end if;

				when CORE_TOT0 =>
					maddr <= (others => '0');
					tp1 <= '0';
					core_state <= CORE_TOT;

				when CORE_TOT =>
					-- Secret tiles: one address per clock; map_data_i is the
					-- tile of the address one clock earlier (tp1 marks it valid)
					if ((tp1 = '1') and (map_sp = SPECIAL_PUSHWALL)) then
						tsecrets <= tsecrets + 1;
					end if;
					tp1 <= '1';
					if (maddr = 4095) then
						core_state <= CORE_TOT_LAST;
					else
						maddr <= maddr + 1;
					end if;

				when CORE_TOT_LAST =>
					if (map_sp = SPECIAL_PUSHWALL) then
						tsecrets <= tsecrets + 1;
					end if;
					tp1 <= '0';
					-- z = box_floor(start), vz = 0 (Game.reset_level_state)
					bx <= px;
					by <= py;
					bfl_ret <= CORE_LOAD_Z;
					core_state <= CORE_BFL;

				when CORE_LOAD_Z =>
					z <= bfl;
					vz <= (others => '0');
					loaded <= '1';
					if (in_step = '1') then
						core_state <= CORE_END;
					else
						core_state <= CORE_IDLE;
					end if;

				--------------------------------------------------------------
				-- Frame start and game flow (Game.step)
				--------------------------------------------------------------
				when CORE_IDLE =>
					if (pending = '1') then
						snap <= snap_in;
						pending <= '0';
						core_state <= CORE_STEP;
					end if;

				when CORE_STEP =>
					sq_n <= (others => '0');
					prev_fire <= snap(SNAP_FIRE);
					if (snap(SNAP_DEBUG) = '1') then
						debug <= not debug;
					end if;
					in_step <= '1';
					core_state <= CORE_END;
					case flow is
						when FL_TITLE =>
							if (go = '1') then
								pl_health <= to_unsigned(100, 8);
								pl_armor <= (others => '0');
								pl_bullets <= to_unsigned(50, 8);
								pl_shells <= (others => '0');
								pl_weapons <= "01";
								pl_weapon <= "01";
								level <= "01";
								flow <= FL_BRIEFING;
							end if;
						when FL_BRIEFING =>
							if (go = '1') then
								saved_health <= pl_health;
								saved_armor <= pl_armor;
								saved_bullets <= pl_bullets;
								saved_shells <= pl_shells;
								saved_weapons <= pl_weapons;
								saved_weapon <= pl_weapon;
								flow <= FL_PLAYING;
								core_state <= CORE_LOAD;
							end if;
						when FL_PAUSED =>
							if (snap(SNAP_MENU) = '1') then
								flow <= FL_PLAYING;
							end if;
						when FL_DEAD =>
							if (dead_timer /= 63) then
								dead_timer <= dead_timer + 1;
							end if;
							if (eye > 8) then
								eye <= eye - 2;
							end if;
							-- The new dead_timer > 30, i.e. the old one >= 30
							if ((dead_timer >= 30) and (go = '1')) then
								pl_health <= saved_health;
								pl_armor <= saved_armor;
								pl_bullets <= saved_bullets;
								pl_shells <= saved_shells;
								pl_weapons <= saved_weapons;
								pl_weapon <= saved_weapon;
								flow <= FL_PLAYING;
								core_state <= CORE_LOAD;
							end if;
						when FL_SCORE =>
							if (go = '1') then
								if (level < LEVELS) then
									level <= level + 1;
									flow <= FL_BRIEFING;
								else
									flow <= FL_ENDING;
								end if;
							end if;
						when FL_ENDING =>
							if (go = '1') then
								flow <= FL_TITLE;
							end if;
						when others =>
							-- PLAYING
							if (snap(SNAP_MENU) = '1') then
								flow <= FL_PAUSED;
							else
								core_state <= CORE_PLAY;
							end if;
					end case;

				--------------------------------------------------------------
				-- 1. Level clock, turn, duck and peek easing, automap
				--------------------------------------------------------------
				when CORE_PLAY =>
					if (t_frames = 59) then
						t_frames <= (others => '0');
						if (t_sec = 59) then
							t_sec <= (others => '0');
							if (t_min /= 99) then -- The level clock stops at 99 minutes
								t_min <= t_min + 1;
							end if;
						else
							t_sec <= t_sec + 1;
						end if;
					else
						t_frames <= t_frames + 1;
					end if;
					-- Adding the low 10 bits of the signed turn is mod 1024
					angle <= angle + unsigned(snap(SNAP_TURN_LO + 9 downto SNAP_TURN_LO));
					if (eye < eye_t) then
						eye <= eye + 2;
					elsif (eye > eye_t) then
						eye <= eye - 2;
					end if;
					if (off < peek_t) then
						off <= off + 2;
					elsif (off > peek_t) then
						off <= off - 2;
					end if;
					if (snap(SNAP_AUTOMAP) = '1') then
						automap <= not automap;
					end if;
					core_state <= CORE_P_SIN;

				when CORE_P_SIN =>
					-- rom_addr = angle, sin arrives in CORE_P_COS
					core_state <= CORE_P_COS;

				when CORE_P_COS =>
					-- rom_addr = angle + 256, cos arrives in CORE_P_VEL
					sn <= rom_data;
					core_state <= CORE_P_VEL;

				when CORE_P_VEL =>
					-- Velocity >> 3 running or >> 4 walking, one more when ducking
					cs <= rom_data;
					if ((snap(SNAP_RUN) = '1') and (snap(SNAP_DUCK) = '0')) then
						mdx <= resize(shift_right(vel_x, 3), 24);
						mdy <= resize(shift_right(vel_y, 3), 24);
					elsif ((snap(SNAP_RUN) = '1') or (snap(SNAP_DUCK) = '0')) then
						mdx <= resize(shift_right(vel_x, 4), 24);
						mdy <= resize(shift_right(vel_y, 4), 24);
					else
						mdx <= resize(shift_right(vel_x, 5), 24);
						mdy <= resize(shift_right(vel_y, 5), 24);
					end if;
					my <= '0';
					core_state <= CORE_MOVE;

				--------------------------------------------------------------
				-- 2. Move x, then y (Game.move_x, move_y)
				--------------------------------------------------------------
				when CORE_MOVE =>
					if (my = '0') then
						bx <= px + mdx;
						by <= py;
					else
						bx <= px;
						by <= py + mdy;
					end if;
					if (((my = '0') and (mdx = 0)) or ((my = '1') and (mdy = 0))) then
						core_state <= CORE_MOVE_NEXT;
					else
						bsmall <= '0';
						bz <= z;
						box_ret <= CORE_MOVE_BOX;
						core_state <= CORE_BOX;
					end if;

				when CORE_MOVE_BOX =>
					if (hit = '1') then
						-- Flush against the cell the box ran into
						if (my = '0') then
							if (mdx > 0) then
								if (flush_xp > px) then
									px <= flush_xp;
								end if;
							else
								if (flush_xn < px) then
									px <= flush_xn;
								end if;
							end if;
						else
							if (mdy > 0) then
								if (flush_yp > py) then
									py <= flush_yp;
								end if;
							else
								if (flush_yn < py) then
									py <= flush_yn;
								end if;
							end if;
						end if;
						core_state <= CORE_MOVE_NEXT;
					else
						aaddr <= (others => '0');
						wret <= CORE_AB;
						core_state <= CORE_WAIT;
					end if;

				when CORE_AB =>
					-- Game.actor_blocks(): one actor per clock
					if (hit_block = '1') then
						core_state <= CORE_MOVE_NEXT;
					elsif (aaddr = 31) then
						if (my = '0') then
							px <= bx;
						else
							py <= by;
						end if;
						core_state <= CORE_MOVE_NEXT;
					else
						aaddr <= aaddr + 1;
						wret <= CORE_AB;
						core_state <= CORE_WAIT;
					end if;

				when CORE_MOVE_NEXT =>
					if (my = '0') then
						my <= '1';
						core_state <= CORE_MOVE;
					else
						if ((snap(SNAP_MOVE_HI downto SNAP_MOVE_LO) /= "00") or
							(snap(SNAP_STRAFE_HI downto SNAP_STRAFE_LO) /= "00")) then
							phase <= phase + 1;
						end if;
						core_state <= CORE_ZF;
					end if;

				--------------------------------------------------------------
				-- Floor contact: step up at once, fall with gravity
				--------------------------------------------------------------
				when CORE_ZF =>
					bx <= px;
					by <= py;
					bfl_ret <= CORE_ZF2;
					core_state <= CORE_BFL;

				when CORE_ZF2 =>
					-- fall_v = min(vz + FALL_ACC, FALL_MAX)
					if (z > bfl) then
						if (z - bfl <= fall_v) then
							z <= bfl;
							vz <= (others => '0');
						else
							z <= z - fall_v;
							vz <= fall_v;
						end if;
					else
						z <= bfl;
						vz <= (others => '0');
					end if;
					core_state <= CORE_PEEK;

				--------------------------------------------------------------
				-- 3. Peek camera: (px + (-sn off >> 6), py + (cs off >> 6));
				-- the offset shrinks by 2 until the camera box is free
				--------------------------------------------------------------
				when CORE_PEEK =>
					if (off = 0) then
						cam_x <= px;
						cam_y <= py;
						core_state <= CORE_PICK;
					else
						mul_a <= resize(off, 24);
						mul_b <= -sn;
						core_state <= CORE_PEEK_M1;
					end if;

				when CORE_PEEK_M1 =>
					mul_b <= cs;
					core_state <= CORE_PEEK_M2;

				when CORE_PEEK_M2 =>
					acc <= prod; -- -sn * off
					core_state <= CORE_PEEK_M3;

				when CORE_PEEK_M3 =>
					bx <= px + resize(shift_right(acc, 6), 24);
					by <= py + resize(shift_right(prod, 6), 24); -- cs * off
					bsmall <= '1';
					box_ret <= CORE_PEEK2;
					core_state <= CORE_BOX;

				when CORE_PEEK2 =>
					if (hit = '0') then
						cam_x <= bx;
						cam_y <= by;
						core_state <= CORE_PICK;
					else
						if (off > 0) then
							off <= off - 2;
						else
							off <= off + 2;
						end if;
						core_state <= CORE_PEEK;
					end if;

				--------------------------------------------------------------
				-- 4. Pickups in actor order, then the floor under the player
				--------------------------------------------------------------
				when CORE_PICK =>
					aaddr <= (others => '0');
					wret <= CORE_PICK_T;
					core_state <= CORE_WAIT;

				when CORE_PICK_T =>
					core_state <= CORE_PICK_N;
					if (hit_pick = '1') then
						case q_kind is
							when 0 =>
								if (pl_health < 90) then
									pl_health <= pl_health + 10;
								else
									pl_health <= to_unsigned(100, 8);
								end if;
							when 1 =>
								if (pl_health < 75) then
									pl_health <= pl_health + 25;
								else
									pl_health <= to_unsigned(100, 8);
								end if;
							when 2 =>
								if (pl_armor < 100) then
									pl_armor <= to_unsigned(100, 8);
								end if;
							when 3 =>
								if (pl_bullets < 190) then
									pl_bullets <= pl_bullets + 10;
								else
									pl_bullets <= to_unsigned(200, 8);
								end if;
							when 4 =>
								if (pl_shells < 46) then
									pl_shells <= pl_shells + 4;
								else
									pl_shells <= to_unsigned(50, 6);
								end if;
							when 5 =>
								pl_weapons <= pl_weapons or "10";
								pl_weapon <= "10";
								if (pl_shells < 42) then
									pl_shells <= pl_shells + 8;
								else
									pl_shells <= to_unsigned(50, 6);
								end if;
							when 6 =>
								keys <= keys or "01";
							when others =>
								keys <= keys or "10";
						end case;
						if (took = '1') then
							-- Write the item back inactive
							aram_we <= '1';
							aram_waddr <= aaddr;
							aram_wdata <= aq;
							aram_wdata(ACTOR_ACTIVE) <= '0';
							items <= items + 1;
							pflash <= to_unsigned(6, 3);
							msg <= to_unsigned(q_kind + 1, 4); -- ITEM_MSG[kind]
							msg_timer <= to_unsigned(MSG_TIME, 7);
							if (q_kind = I_SHOTGUN) then
								snd_id <= to_unsigned(SND_WEAPON, 5);
							else
								snd_id <= to_unsigned(SND_ITEM, 5);
							end if;
							snd_act <= '0';
							snd_ret <= CORE_PICK_N;
							core_state <= CORE_SND;
						end if;
					end if;

				when CORE_PICK_N =>
					if (aaddr = 31) then
						core_state <= CORE_SPEC;
					else
						aaddr <= aaddr + 1;
						wret <= CORE_PICK_T;
						core_state <= CORE_WAIT;
					end if;

				when CORE_SPEC =>
					maddr <= pcell;
					wret <= CORE_SPEC2;
					core_state <= CORE_WAIT;

				when CORE_SPEC2 =>
					-- Secret: count it once (map_we_o clears the special in the
					-- map this clock); toxic floor: 5 damage every 32 frames
					if (map_sp = SPECIAL_TOXIC) then
						on_toxic <= '1';
					else
						on_toxic <= '0';
					end if;
					core_state <= CORE_USE;
					if (map_sp = SPECIAL_PUSHWALL) then
						secrets <= secrets + 1;
						msg <= to_unsigned(11, 4); -- M_SECRET
						msg_timer <= to_unsigned(MSG_TIME, 7);
					elsif ((map_sp = SPECIAL_TOXIC) and (t_frames(4 downto 0) = 0)) then
						dmg <= to_unsigned(5, 6);
						dp_ret <= CORE_USE;
						core_state <= CORE_DP;
					end if;

				--------------------------------------------------------------
				-- 5. Use: the cell 0.75 tile ahead
				--------------------------------------------------------------
				when CORE_USE =>
					maddr <= use_cell;
					if (snap(SNAP_USE) = '1') then
						wret <= CORE_USE2;
						core_state <= CORE_WAIT;
					else
						core_state <= CORE_WPN;
					end if;

				when CORE_USE2 =>
					core_state <= CORE_WPN;
					snd_act <= '0';
					snd_ret <= CORE_WPN;
					case map_sp is
						when SPECIAL_DOOR =>
							core_state <= CORE_UDOOR;
						when SPECIAL_LOCKED1 | SPECIAL_LOCKED2 =>
							if (((map_sp = SPECIAL_LOCKED1) and (keys(0) = '1')) or
								((map_sp = SPECIAL_LOCKED2) and (keys(1) = '1'))) then
								core_state <= CORE_UDOOR;
							else
								if (map_sp = SPECIAL_LOCKED1) then
									msg <= to_unsigned(9, 4); -- M_NEED1
								else
									msg <= to_unsigned(10, 4); -- M_NEED2
								end if;
								msg_timer <= to_unsigned(MSG_TIME, 7);
								snd_id <= to_unsigned(SND_NOWAY, 5);
								core_state <= CORE_SND;
							end if;
						when SPECIAL_EXIT =>
							level_done <= '1';
							snd_id <= to_unsigned(SND_SWITCH, 5);
							core_state <= CORE_SND;
						when others =>
							null;
					end case;

				when CORE_UDOOR =>
					-- Game.use_door(): new entry, close an open door, reopen a
					-- closing one
					core_state <= CORE_WPN;
					snd_act <= '0';
					snd_ret <= CORE_WPN;
					if (didx = 8) then
						if (dfree < 8) then
							door_x(dfree mod 8) <= maddr(5 downto 0);
							door_y(dfree mod 8) <= maddr(11 downto 6);
							door_amt(dfree mod 8) <= (others => '0');
							door_timer(dfree mod 8) <= (others => '0');
							door_state(dfree mod 8) <= DS_OPENING;
							snd_id <= to_unsigned(SND_DOOR_OPEN, 5);
							core_state <= CORE_SND;
						end if;
					elsif (door_state(didx mod 8) = DS_OPEN) then
						di <= to_unsigned(didx mod 8, 3);
						db_ret <= CORE_UDOOR2;
						core_state <= CORE_DB;
					elsif (door_state(didx mod 8) = DS_CLOSING) then
						door_state(didx mod 8) <= DS_OPENING;
					end if;

				when CORE_UDOOR2 =>
					core_state <= CORE_WPN;
					if (blocked = '0') then
						door_state(dk) <= DS_CLOSING;
						snd_id <= to_unsigned(SND_DOOR_CLOSE, 5);
						snd_act <= '0';
						snd_ret <= CORE_WPN;
						core_state <= CORE_SND;
					end if;

				--------------------------------------------------------------
				-- 6. Weapon: select, cooldown, fire
				--------------------------------------------------------------
				when CORE_WPN =>
					pl_weapon <= wpn_next;
					if (cooldown > 0) then
						cooldown <= cooldown - 1;
					end if;
					if (flash > 0) then
						flash <= flash - 1;
					end if;
					core_state <= CORE_ACTORS;
					snd_act <= '0';
					snd_ret <= CORE_HS_COL;
					-- Fire when the cooldown is 0 after this frame's count
					if ((snap(SNAP_FIRE) = '1') and (cooldown <= 1)) then
						if ((wpn_next = 1) and (pl_bullets > 0)) then
							pl_bullets <= pl_bullets - 1;
							cooldown <= to_unsigned(14, 6);
							flash <= to_unsigned(4, 3);
							snd_id <= to_unsigned(SND_PISTOL, 5);
							hk <= to_unsigned(3, 3); -- Column 160 only
							hshot <= '0';
							core_state <= CORE_SND;
						elsif ((wpn_next = 2) and (pl_shells > 0)) then
							pl_shells <= pl_shells - 1;
							cooldown <= to_unsigned(40, 6);
							flash <= to_unsigned(4, 3);
							snd_id <= to_unsigned(SND_SHOTGUN, 5);
							hk <= to_unsigned(0, 3); -- Columns 136, 144 .. 184
							hshot <= '1';
							core_state <= CORE_SND;
						end if;
					end if;

				--------------------------------------------------------------
				-- Hitscan (Game.hitscan): the nearest span over the column in
				-- front of the wall; damage 5 * (1 + (random & 3)) drawn first
				--------------------------------------------------------------
				when CORE_HS_COL =>
					lfsr <= lfsr_n;
					hdmg <= times_const(lfsr_n(1 downto 0) + "0001", 5);
					zw_addr <= to_unsigned(136, 9) + shift_left(resize(hk, 9), 3);
					wret <= CORE_HS_ZW;
					core_state <= CORE_WAIT;

				when CORE_HS_ZW =>
					zw <= unsigned(zwall_data_i);
					best_v <= '0';
					span_addr <= (others => '0');
					if (unsigned(span_count_i) = 0) then
						core_state <= CORE_HS_END;
					else
						wret <= CORE_HS_SP;
						core_state <= CORE_WAIT;
					end if;

				when CORE_HS_SP =>
					-- Span over column zw_addr, in front of the wall, nearest so far
					if ((unsigned(span_data_i(SPAN_X0_HI downto SPAN_X0_LO)) <= zw_addr) and
						(zw_addr <= unsigned(span_data_i(SPAN_X1_HI downto SPAN_X1_LO))) and
						(unsigned(span_data_i(SPAN_Z_HI downto SPAN_Z_LO)) < zw) and
						((best_v = '0') or (unsigned(span_data_i(SPAN_Z_HI downto SPAN_Z_LO)) < best_z))) then
						best_v <= '1';
						best_i <= unsigned(span_data_i(SPAN_IDX_HI downto SPAN_IDX_LO));
						best_z <= unsigned(span_data_i(SPAN_Z_HI downto SPAN_Z_LO));
					end if;
					if (resize(span_addr, 6) + 1 = unsigned(span_count_i)) then -- That was the last span
						core_state <= CORE_HS_END;
					else
						span_addr <= span_addr + 1;
						wret <= CORE_HS_SP;
						core_state <= CORE_WAIT;
					end if;

				when CORE_HS_END =>
					if (best_v = '1') then
						aaddr <= best_i;
						ai <= best_i;
						wret <= CORE_DA;
						core_state <= CORE_WAIT;
					else
						core_state <= CORE_HS_NEXT;
					end if;

				when CORE_DA =>
					-- Game.damage_actor(): only living (solid) actors; a = the
					-- target with its new health
					core_state <= CORE_HS_NEXT;
					if ((aq(ACTOR_ACTIVE) = '1') and (aq(ACTOR_SOLID) = '1')) then
						en_ret <= CORE_HS_WB;
						a_x <= q_x;
						a_y <= q_y;
						a_state <= q_state;
						a_timer <= unsigned(aq(ACTOR_TIMER_HI downto ACTOR_TIMER_LO));
						a_typ <= q_typ;
						a_active <= aq(ACTOR_ACTIVE);
						a_solid <= aq(ACTOR_SOLID);
						a_awake <= aq(ACTOR_AWAKE);
						a_ambush <= aq(ACTOR_AMBUSH);
						if (da_hp <= 0) then
							a_health <= (others => '0');
							en_s <= to_unsigned(TYPE_TABLE(q_k)(TP_DIE_ST), 7);
							core_state <= CORE_ENTER;
						else
							a_health <= unsigned(da_hp(11 downto 0));
							a_awake <= '1';
							lfsr <= lfsr_n;
							core_state <= CORE_HS_WB;
							if (to_integer(lfsr_n(7 downto 0)) < TYPE_TABLE(q_k)(TP_PAIN)) then -- Pain chance out of 256
								en_s <= to_unsigned(TYPE_TABLE(q_k)(TP_PAIN_ST), 7);
								core_state <= CORE_ENTER;
							elsif (aq(ACTOR_AWAKE) = '0') then
								en_s <= to_unsigned(TYPE_TABLE(q_k)(TP_CHASE), 7);
								core_state <= CORE_ENTER;
							end if;
						end if;
					end if;

				when CORE_HS_WB =>
					aram_we <= '1';
					aram_waddr <= ai;
					aram_wdata <= a_word;
					core_state <= CORE_HS_NEXT;

				when CORE_HS_NEXT =>
					if ((hshot = '1') and (hk /= 6)) then
						hk <= hk + 1;
						core_state <= CORE_HS_COL;
					else
						core_state <= CORE_AL0;
					end if;

				--------------------------------------------------------------
				-- Sound alert (Game.alert), after the shot's hitscans: breadth-first fill
				-- from the player's cell over non-solid neighbors, then the actor pass, then
				-- the visited bits are cleared through the queue (al_* decodes write)
				--------------------------------------------------------------
				when CORE_AL0 =>
					-- The player's cell is queued and marked this clock
					qhead <= (others => '0');
					qtail <= to_unsigned(1, 13); -- 13 bits: 4096 queued cells must not look empty
					core_state <= CORE_AL_POP;

				when CORE_AL_POP =>
					if (qhead = qtail) then
						-- Fill done: the actors in slot order
						ai <= (others => '0');
						aaddr <= (others => '0');
						wret <= CORE_AL_LD;
						core_state <= CORE_WAIT;
					else
						qra <= qhead(11 downto 0);
						core_state <= CORE_AL_POPW;
					end if;

				when CORE_AL_POPW =>
					-- The queue address is at the memory now; data next clock
					core_state <= CORE_AL_CUR;

				when CORE_AL_CUR =>
					cur <= unsigned(alq_q);
					qhead <= qhead + 1;
					nk <= "00";
					core_state <= CORE_AL_NB;

				when CORE_AL_NB =>
					-- Neighbor nk of the current cell
					ncell <= nb_cell;
					maddr <= nb_cell;
					vaddr <= nb_cell;
					wret <= CORE_AL_NBD;
					core_state <= CORE_WAIT;

				when CORE_AL_NBD =>
					-- Tile word, door-open flag and visited bit of ncell are here:
					-- an open, unvisited cell is marked and queued
					if (al_open = '1') then
						qtail <= qtail + 1;
					end if;
					if (nk = 3) then
						core_state <= CORE_AL_POP;
					else
						nk <= nk + 1;
						core_state <= CORE_AL_NB;
					end if;

				when CORE_AL_LD =>
					a_x <= q_x;
					a_y <= q_y;
					a_state <= q_state;
					a_timer <= unsigned(aq(ACTOR_TIMER_HI downto ACTOR_TIMER_LO));
					a_health <= q_health;
					a_typ <= q_typ;
					a_active <= aq(ACTOR_ACTIVE);
					a_solid <= aq(ACTOR_SOLID);
					a_awake <= aq(ACTOR_AWAKE);
					a_ambush <= aq(ACTOR_AMBUSH);
					vaddr <= q_y(15 downto 10) & q_x(15 downto 10); -- Integer parts of Q6.10: the actor's cell
					core_state <= CORE_AL_LD2;

				when CORE_AL_LD2 =>
					-- The actor cell's visited bit arrives next clock
					core_state <= CORE_AL_CHK;

				when CORE_AL_CHK =>
					-- A sleeping, living monster in a LOOK state, not an ambusher,
					-- in a reached cell wakes as in LOOK (CORE_LOOK2, CORE_LOOK3)
					core_state <= CORE_AL_NX;
					if ((a_active = '1') and (a_solid = '1') and (a_typ < 4) and (a_awake = '0') and
						(a_ambush = '0') and (a_act = A_LOOK) and (vis_q = '1')) then
						a_awake <= '1';
						if (a_typ = T_BOSS) then
							snd_id <= to_unsigned(SND_BOSS_SIGHT, 5);
						else
							snd_id <= to_unsigned(SND_SIGHT, 5);
						end if;
						snd_act <= '1';
						snd_ret <= CORE_AL_ENT;
						core_state <= CORE_SND;
					end if;

				when CORE_AL_ENT =>
					en_s <= to_unsigned(TYPE_TABLE(a_k)(TP_CHASE), 7);
					en_ret <= CORE_AL_WB;
					core_state <= CORE_ENTER;

				when CORE_AL_WB =>
					aram_we <= '1';
					aram_waddr <= ai;
					aram_wdata <= a_word;
					core_state <= CORE_AL_NX;

				when CORE_AL_NX =>
					if (ai = 31) then
						qhead <= (others => '0');
						core_state <= CORE_AL_CLR;
					else
						ai <= ai + 1;
						aaddr <= ai + 1;
						wret <= CORE_AL_LD;
						core_state <= CORE_WAIT;
					end if;

				when CORE_AL_CLR =>
					-- Clear the visited bit of every queued cell (qhead counts)
					if (qhead = qtail) then
						core_state <= CORE_ACTORS;
					else
						qra <= qhead(11 downto 0);
						core_state <= CORE_AL_CLRW;
					end if;

				when CORE_AL_CLRW =>
					core_state <= CORE_AL_CLR2;

				when CORE_AL_CLR2 =>
					-- The bit of cell alq_q is cleared this clock
					qhead <= qhead + 1;
					core_state <= CORE_AL_CLR;

				--------------------------------------------------------------
				-- 7. Actors 0..31 (Game.actor_step): load into a_*, run the per-frame
				-- action, count the timer down, write back
				--------------------------------------------------------------
				when CORE_ACTORS =>
					ai <= (others => '0');
					aaddr <= (others => '0');
					wret <= CORE_ACT_LD;
					core_state <= CORE_WAIT;

				when CORE_ACT_LD =>
					a_x <= q_x;
					a_y <= q_y;
					a_state <= q_state;
					a_timer <= unsigned(aq(ACTOR_TIMER_HI downto ACTOR_TIMER_LO));
					a_health <= q_health;
					a_typ <= q_typ;
					a_active <= aq(ACTOR_ACTIVE);
					a_solid <= aq(ACTOR_SOLID);
					a_awake <= aq(ACTOR_AWAKE);
					a_ambush <= aq(ACTOR_AMBUSH);
					if (aq(ACTOR_ACTIVE) = '0') then
						core_state <= CORE_ACT_NX;
					else
						core_state <= CORE_ACT_GO;
					end if;

				when CORE_ACT_GO =>
					-- One clock for the helpers (adist, atx, aty) of the new a
					case a_act is
						when A_LOOK =>
							core_state <= CORE_LOOK;
						when A_CHASE =>
							core_state <= CORE_CHASE;
						when A_FLY =>
							core_state <= CORE_FLY;
						when others =>
							core_state <= CORE_TICK;
					end case;

				when CORE_LOOK =>
					core_state <= CORE_TICK;
					if (adist < WAKE_RANGE) then
						los_ret <= CORE_LOOK2;
						core_state <= CORE_LOS;
					end if;

				when CORE_LOOK2 =>
					core_state <= CORE_TICK;
					if (los = '1') then
						a_awake <= '1';
						if (a_typ = T_BOSS) then
							snd_id <= to_unsigned(SND_BOSS_SIGHT, 5);
						else
							snd_id <= to_unsigned(SND_SIGHT, 5);
						end if;
						snd_act <= '1';
						snd_ret <= CORE_LOOK3;
						core_state <= CORE_SND;
					end if;

				when CORE_LOOK3 =>
					en_s <= to_unsigned(TYPE_TABLE(a_k)(TP_CHASE), 7);
					en_ret <= CORE_ACT_WB;
					core_state <= CORE_ENTER;

				when CORE_CHASE =>
					-- Ranged attack check needs the line of sight
					-- (TP_RANGE is in tiles; * 1024 makes it Q6.10 like adist)
					cdist <= adist;
					core_state <= CORE_CHASE3;
					if ((TYPE_TABLE(a_k)(TP_RANGED) /= 0) and (adist < TYPE_TABLE(a_k)(TP_RANGE) * 1024)) then
						los_ret <= CORE_CHASE2;
						core_state <= CORE_LOS;
					end if;

				when CORE_CHASE2 =>
					core_state <= CORE_CHASE3;
					if (los = '1') then
						lfsr <= lfsr_n;
						if ((lfsr_n(7 downto 0) and to_unsigned(TYPE_TABLE(a_k)(TP_MASK), 8)) = 0) then -- 1 chance in mask + 1
							en_s <= to_unsigned(TYPE_TABLE(a_k)(TP_AIM_ST), 7);
							en_ret <= CORE_ACT_WB;
							core_state <= CORE_ENTER;
						end if;
					end if;

				when CORE_CHASE3 =>
					-- Melee, else walk toward the player (each axis clamped to
					-- the speed, x first; a step into a solid cell is skipped)
					if ((TYPE_TABLE(a_k)(TP_MELEE) /= 0) and (cdist < MELEE_RANGE)) then
						en_s <= to_unsigned(TYPE_TABLE(a_k)(TP_MELEE_ST), 7);
						en_ret <= CORE_ACT_WB;
						core_state <= CORE_ENTER;
					elsif (cdist >= STOP_RANGE) then
						if (atx > a_spd) then
							csx <= to_signed(a_spd, 8);
						elsif (atx < -a_spd) then
							csx <= to_signed(-a_spd, 8);
						else
							csx <= atx(7 downto 0);
						end if;
						if (aty > a_spd) then
							csy <= to_signed(a_spd, 8);
						elsif (aty < -a_spd) then
							csy <= to_signed(-a_spd, 8);
						else
							csy <= aty(7 downto 0);
						end if;
						core_state <= CORE_CHASE3B;
					else
						core_state <= CORE_TICK;
					end if;

				when CORE_CHASE3B =>
					-- actor_move_ok(x + sx, y, actor_floor(a)): floor first
					core_state <= CORE_CHASE5;
					if (csx /= 0) then
						fpx <= q16(a_x);
						fpy <= q16(a_y);
						fat_ret <= CORE_CHASE3C;
						core_state <= CORE_FAT;
					end if;

				when CORE_CHASE3C =>
					bz <= fat;
					bx <= q16(a_x + unsigned(resize(csx, 16)));
					by <= q16(a_y);
					bsmall <= '0';
					box_ret <= CORE_CHASE4;
					core_state <= CORE_BOX;

				when CORE_CHASE4 =>
					if (hit = '0') then
						a_x <= a_x + unsigned(resize(csx, 16));
					end if;
					core_state <= CORE_CHASE5;

				when CORE_CHASE5 =>
					-- The floor again: a_x may have moved
					core_state <= CORE_TICK;
					if (csy /= 0) then
						fpx <= q16(a_x);
						fpy <= q16(a_y);
						fat_ret <= CORE_CHASE5B;
						core_state <= CORE_FAT;
					end if;

				when CORE_CHASE5B =>
					bz <= fat;
					bx <= q16(a_x);
					by <= q16(a_y + unsigned(resize(csy, 16)));
					bsmall <= '0';
					box_ret <= CORE_CHASE6;
					core_state <= CORE_BOX;

				when CORE_CHASE6 =>
					if (hit = '0') then
						a_y <= a_y + unsigned(resize(csy, 16));
					end if;
					core_state <= CORE_TICK;

				when CORE_FLY =>
					-- Fireball: one velocity step, then its cell
					a_x <= fly_x;
					a_y <= fly_y;
					maddr <= fly_y(15 downto 10) & fly_x(15 downto 10);
					wret <= CORE_FLY2;
					core_state <= CORE_WAIT;

				when CORE_FLY2 =>
					en_s <= to_unsigned(ST_EXPL_A, 7);
					en_ret <= CORE_ACT_WB;
					if (map_solid = '1') then
						core_state <= CORE_ENTER;
					elsif ((unsigned(abs(atx)) < FIRE_HIT) and (unsigned(abs(aty)) < FIRE_HIT)) then
						lfsr <= lfsr_n;
						dmg <= times_const(resize(lfsr_n(2 downto 0), 4) + 1, 3); -- 3 * (1 + (random & 7))
						dp_ret <= CORE_FLY3;
						core_state <= CORE_DP;
					else
						core_state <= CORE_TICK;
					end if;

				when CORE_FLY3 =>
					core_state <= CORE_ENTER;

				when CORE_TICK =>
					core_state <= CORE_ACT_WB;
					if (a_timer /= FOREVER) then
						a_timer <= a_timer - 1;
						if (a_timer = 1) then -- Runs out this frame: on to the next state
							en_s <= a_next;
							en_ret <= CORE_ACT_WB;
							core_state <= CORE_ENTER;
						end if;
					end if;

				when CORE_ACT_WB =>
					aram_we <= '1';
					aram_waddr <= ai;
					aram_wdata <= a_word;
					core_state <= CORE_ACT_NX;

				when CORE_ACT_NX =>
					if (ai = 31) then
						di <= (others => '0');
						core_state <= CORE_DOORS;
					else
						ai <= ai + 1;
						aaddr <= ai + 1;
						wret <= CORE_ACT_LD;
						core_state <= CORE_WAIT;
					end if;

				--------------------------------------------------------------
				-- 8. Doors (Game.update_doors), then the world timers
				--------------------------------------------------------------
				when CORE_DOORS =>
					core_state <= CORE_DOOR_NX;
					db_ret <= CORE_DOOR_NX;
					case door_state(dk) is
						when DS_OPENING =>
							if (door_amt(dk) + DOOR_STEP >= DOOR_OPEN) then
								door_amt(dk) <= to_signed(DOOR_OPEN, 8);
								door_state(dk) <= DS_OPEN;
								door_timer(dk) <= to_unsigned(DOOR_STAY, 8);
							else
								door_amt(dk) <= door_amt(dk) + DOOR_STEP;
							end if;
						when DS_OPEN =>
							door_timer(dk) <= door_timer(dk) - 1;
							if (door_timer(dk) = 1) then -- Runs out this frame
								db_ret <= CORE_DOOR_OPEN2;
								core_state <= CORE_DB;
							end if;
						when DS_CLOSING =>
							db_ret <= CORE_DOOR_CL2;
							core_state <= CORE_DB;
						when others =>
							null;
					end case;

				when CORE_DOOR_OPEN2 =>
					if (blocked = '1') then
						door_timer(dk) <= to_unsigned(DOOR_RETRY, 8);
					else
						door_state(dk) <= DS_CLOSING;
					end if;
					core_state <= CORE_DOOR_NX;

				when CORE_DOOR_CL2 =>
					if (blocked = '1') then
						door_state(dk) <= DS_OPENING;
					elsif (door_amt(dk) - DOOR_STEP <= 0) then
						door_amt(dk) <= (others => '0');
						door_state(dk) <= DS_IDLE;
					else
						door_amt(dk) <= door_amt(dk) - DOOR_STEP;
					end if;
					core_state <= CORE_DOOR_NX;

				when CORE_DOOR_NX =>
					if (di = 7) then
						core_state <= CORE_WORLD;
					else
						di <= di + 1;
						core_state <= CORE_DOORS;
					end if;

				when CORE_WORLD =>
					if (boss_timer > 0) then
						boss_timer <= boss_timer - 1;
						if (boss_timer = 1) then
							level_done <= '1';
						end if;
					end if;
					if (dflash > 0) then
						dflash <= dflash - 1;
					end if;
					if (pflash > 0) then
						pflash <= pflash - 1;
					end if;
					if (msg_timer > 0) then
						msg_timer <= msg_timer - 1;
						if (msg_timer = 1) then
							msg <= (others => '0');
						end if;
					end if;
					if (pl_health = 0) then
						flow <= FL_DEAD;
						dead_timer <= (others => '0');
					elsif ((level_done = '1') or (boss_timer = 1)) then -- level_done after this clock
						flow <= FL_SCORE;
					end if;
					core_state <= CORE_END;

				--------------------------------------------------------------
				-- End of every step: sprite table, key positions, checksum, outputs
				--------------------------------------------------------------
				when CORE_END =>
					-- Effects frame of this step: (t_sec * 60 + t_frames) mod 256, t_sec * 60 as
					-- (t_sec << 6) - (t_sec << 2)
					fxn <= resize(shift_left(resize(t_sec, 12), 6) - shift_left(resize(t_sec, 12), 2) +
						resize(t_frames, 12), 8);
					aaddr <= (others => '0');
					spr_n <= (others => '0');
					kp <= (others => '0');
					wret <= CORE_SPR_T;
					core_state <= CORE_WAIT;

				when CORE_SPR_T =>
					-- Light offsets of this step's effects frame (registered: the table and
					-- adders stay off the sprite light path)
					lm <= lm_next;
					core_state <= CORE_SPR_N;
					if (aq(ACTOR_ACTIVE) = '1') then
						spr_e <= (others => '0');
						spr_e(SPR_IDX_HI downto SPR_IDX_LO) <= std_logic_vector(aaddr);
						spr_e(SPR_X_HI downto SPR_X_LO) <= std_logic_vector(q_x);
						spr_e(SPR_Y_HI downto SPR_Y_LO) <= std_logic_vector(q_y);
						spr_e(SPR_FRAME_HI downto SPR_FRAME_LO) <= std_logic_vector(q_art);
						if (q_typ = T_FIREBALL) then
							spr_e(SPR_BRIGHT) <= '1';
						end if;
						if ((aq(ACTOR_SOLID) = '1') and (q_typ < 4)) then
							spr_e(SPR_TARGET) <= '1';
						end if;
						-- Keys still on the floor (first of each kind): 13-bit entry, the
						-- cell (y & x) above a valid bit
						if ((q_typ = T_ITEM) and (q_health = I_KEY1) and (kp(KEYPOS_BLUE) = '0')) then
							kp(KEYPOS_BLUE + 12 downto KEYPOS_BLUE) <= aq(ACTOR_Y_HI downto ACTOR_Y_HI - 5) &
								aq(ACTOR_X_HI downto ACTOR_X_HI - 5) & '1';
						end if;
						if ((q_typ = T_ITEM) and (q_health = I_KEY2) and (kp(KEYPOS_RED) = '0')) then
							kp(KEYPOS_RED + 12 downto KEYPOS_RED) <= aq(ACTOR_Y_HI downto ACTOR_Y_HI - 5) &
								aq(ACTOR_X_HI downto ACTOR_X_HI - 5) & '1';
						end if;
						maddr <= q_y(15 downto 10) & q_x(15 downto 10);
						wret <= CORE_SPR_L;
						core_state <= CORE_WAIT;
					end if;

				when CORE_SPR_L =>
					-- Light of the center tile, then the floor under the center
					spr_e(SPR_LIGHT_HI downto SPR_LIGHT_LO) <= map_data_i(TILE_LIGHT_HI downto TILE_LIGHT_LO);
					spr_ty <= map_data_i(TILE_LTYPE_HI downto TILE_LTYPE_LO);
					fpx <= q16(unsigned(spr_e(SPR_X_HI downto SPR_X_LO)));
					fpy <= q16(unsigned(spr_e(SPR_Y_HI downto SPR_Y_LO)));
					fat_ret <= CORE_SPR_F;
					core_state <= CORE_FAT;

				when CORE_SPR_F =>
					-- Entry spr_n into the half the renderer is not reading
					spr_we <= '1';
					spr_waddr <= (not bank) & spr_n(4 downto 0);
					spr_wdata <= spr_e;
					spr_wdata(SPR_FLOOR_HI downto SPR_FLOOR_LO) <= std_logic_vector(fat(6 downto 0)); -- 0..64 fits 7 bits
					spr_wdata(SPR_LIGHT_HI downto SPR_LIGHT_LO) <= spr_light;
					spr_n <= spr_n + 1;
					core_state <= CORE_SPR_N;

				when CORE_SPR_N =>
					if (aaddr = 31) then
						core_state <= CORE_CRC0;
					else
						aaddr <= aaddr + 1;
						wret <= CORE_SPR_T;
						core_state <= CORE_WAIT;
					end if;

				when CORE_CRC0 =>
					cw <= (others => '0');
					core_state <= CORE_CRC_W;

				when CORE_CRC_W =>
					cword <= word; -- waddr = cw in this state
					cb <= (others => '0');
					core_state <= CORE_CRC_B;

				when CORE_CRC_B =>
					-- Byte cb of the word (on cword(7:0)) goes into the CRC
					cword <= x"00" & cword(63 downto 8);
					cb <= cb + 1;
					if (cb = 7) then
						if (cw = STATE_WORDS - 1) then
							core_state <= CORE_OUT;
						else
							cw <= cw + 1;
							core_state <= CORE_CRC_W;
						end if;
					end if;

				when CORE_OUT =>
					fx_out <= std_logic_vector(fxn(4 downto 3)) & lm; -- anim = (n >> 3) & 3
					cam_x_out <= std_logic_vector(cam_x(POS_BITS - 1 downto 0));
					cam_y_out <= std_logic_vector(cam_y(POS_BITS - 1 downto 0));
					angle_out <= std_logic_vector(angle);
					-- view_eye() = min(127, z + eye)
					if (resize(z, 9) + eye > 127) then
						eye_out <= (others => '1');
					else
						eye_out <= std_logic_vector(resize(z, 7) + eye);
					end if;
					player_x_out <= std_logic_vector(px(POS_BITS - 1 downto 0));
					player_y_out <= std_logic_vector(py(POS_BITS - 1 downto 0));
					for k in 0 to 7 loop
						if (door_state(k) = DS_IDLE) then
							doors_out(DOOR_BITS * k + DOOR_BITS - 1 downto DOOR_BITS * k) <= (others => '0');
						else
							doors_out(DOOR_BITS * k + DOOR_X_HI downto DOOR_BITS * k + DOOR_X_LO) <=
								std_logic_vector(door_x(k));
							doors_out(DOOR_BITS * k + DOOR_Y_HI downto DOOR_BITS * k + DOOR_Y_LO) <=
								std_logic_vector(door_y(k));
							doors_out(DOOR_BITS * k + DOOR_OPEN_HI downto DOOR_BITS * k + DOOR_OPEN_LO) <=
								std_logic_vector(door_amt(k)(6 downto 0));
						end if;
					end loop;
					-- HUD word (game.hud())
					hud_out <= (others => '0');
					hud_out(HUD_FLOW_HI downto HUD_FLOW_LO) <= std_logic_vector(flow);
					hud_out(HUD_LEVEL_HI downto HUD_LEVEL_LO) <= std_logic_vector(level);
					hud_out(HUD_HEALTH_HI downto HUD_HEALTH_LO) <= std_logic_vector(pl_health);
					hud_out(HUD_ARMOR_HI downto HUD_ARMOR_LO) <= std_logic_vector(pl_armor);
					if (pl_weapon = 1) then
						hud_out(HUD_AMMO_HI downto HUD_AMMO_LO) <= std_logic_vector(pl_bullets);
						if (flash > 0) then
							hud_out(HUD_WFRAME_HI downto HUD_WFRAME_LO) <= std_logic_vector(to_unsigned(WEAPON_BASE + 1, 8));
						else
							hud_out(HUD_WFRAME_HI downto HUD_WFRAME_LO) <= std_logic_vector(to_unsigned(WEAPON_BASE, 8));
						end if;
					else
						hud_out(HUD_AMMO_HI downto HUD_AMMO_LO) <= std_logic_vector(resize(pl_shells, 8));
						-- Shotgun pump frames over its 40-frame cooldown
						if (cooldown > 36) then
							hud_out(HUD_WFRAME_HI downto HUD_WFRAME_LO) <= std_logic_vector(to_unsigned(WEAPON_BASE + 3, 8));
						elsif (cooldown > 16) then
							hud_out(HUD_WFRAME_HI downto HUD_WFRAME_LO) <= std_logic_vector(to_unsigned(WEAPON_BASE + 4, 8));
						else
							hud_out(HUD_WFRAME_HI downto HUD_WFRAME_LO) <= std_logic_vector(to_unsigned(WEAPON_BASE + 2, 8));
						end if;
					end if;
					hud_out(HUD_WEAPON_HI downto HUD_WEAPON_LO) <= std_logic_vector(pl_weapon);
					hud_out(HUD_KEYS_HI downto HUD_KEYS_LO) <= std_logic_vector(keys);
					-- BOB = 0 1 2 3 4 3 2 1 by phase bits 4:2, only while PLAYING
					if (flow = FL_PLAYING) then
						case phase(4 downto 2) is
							when "000" =>
								hud_out(HUD_BOB_HI downto HUD_BOB_LO) <= "000";
							when "001" | "111" =>
								hud_out(HUD_BOB_HI downto HUD_BOB_LO) <= "001";
							when "010" | "110" =>
								hud_out(HUD_BOB_HI downto HUD_BOB_LO) <= "010";
							when "011" | "101" =>
								hud_out(HUD_BOB_HI downto HUD_BOB_LO) <= "011";
							when others =>
								hud_out(HUD_BOB_HI downto HUD_BOB_LO) <= "100";
						end case;
					end if;
					hud_out(HUD_MSG_HI downto HUD_MSG_LO) <= std_logic_vector(msg);
					hud_out(HUD_KILLS_HI downto HUD_KILLS_LO) <= std_logic_vector(kills);
					hud_out(HUD_TKILLS_HI downto HUD_TKILLS_LO) <= std_logic_vector(tkills);
					hud_out(HUD_ITEMS_HI downto HUD_ITEMS_LO) <= std_logic_vector(items);
					hud_out(HUD_TITEMS_HI downto HUD_TITEMS_LO) <= std_logic_vector(titems);
					hud_out(HUD_SECRETS_HI downto HUD_SECRETS_LO) <= std_logic_vector(secrets);
					hud_out(HUD_TSECRETS_HI downto HUD_TSECRETS_LO) <= std_logic_vector(tsecrets);
					hud_out(HUD_TMIN_HI downto HUD_TMIN_LO) <= std_logic_vector(t_min);
					hud_out(HUD_TSEC_HI downto HUD_TSEC_LO) <= std_logic_vector(t_sec);
					hud_out(HUD_AUTOMAP) <= automap;
					hud_out(HUD_DEBUG) <= debug;
					keypos_out <= kp;
					if ((flow = FL_PLAYING) or (flow = FL_PAUSED) or (flow = FL_DEAD)) then
						music_out <= std_logic_vector(level);
					else
						music_out <= "00";
					end if;
					-- Screen tint (game.tint()): damage flash, pickup flash, toxic floor
					if (dflash > 0) then
						tint_out <= "01";
					elsif (pflash > 0) then
						tint_out <= "10";
					elsif ((flow = FL_PLAYING) and (on_toxic = '1')) then
						tint_out <= "11";
					else
						tint_out <= "00";
					end if;
					spr_count_out <= std_logic_vector(spr_n);
					crc_out <= crc;
					bank <= not bank;
					oq <= sq;
					oq_n <= sq_n;
					oq_p <= (others => '0');
					start <= '1';
					core_state <= CORE_IDLE;

				--------------------------------------------------------------
				-- Subroutines
				--------------------------------------------------------------
				when CORE_WAIT =>
					-- The address register is at the memory now; data next clock
					core_state <= wret;

				when CORE_BOX =>
					-- Game.box_hits(): 2 x 2 cells, stop at the first solid one
					-- (corner 0: x -, y -)
					bk <= "00";
					hit <= '0';
					maddr <= unsigned(std_logic_vector(box_y0(21 downto 16))) & unsigned(std_logic_vector(box_x0(21 downto 16)));
					wret <= CORE_BOX_D;
					core_state <= CORE_WAIT;

				when CORE_BOX_D =>
					-- Game.blocks(): solid, or (not for the camera box) too high a step or too
					-- little headroom for a body at bz
					if ((map_solid = '1') or ((bsmall = '0') and (map_hblk = '1'))) then
						hit <= '1';
						core_state <= box_ret;
					elsif (bk = 3) then
						core_state <= box_ret;
					else
						-- Corner bk + 1: bit 0 picks x -/+, bit 1 picks y -/+
						bk <= bk + 1;
						case bk is
							when "00" =>
								maddr <= unsigned(std_logic_vector(box_y0(21 downto 16))) & unsigned(std_logic_vector(box_x1(21 downto 16)));
							when "01" =>
								maddr <= unsigned(std_logic_vector(box_y1(21 downto 16))) & unsigned(std_logic_vector(box_x0(21 downto 16)));
							when others =>
								maddr <= unsigned(std_logic_vector(box_y1(21 downto 16))) & unsigned(std_logic_vector(box_x1(21 downto 16)));
						end case;
						wret <= CORE_BOX_D;
						core_state <= CORE_WAIT;
					end if;

				when CORE_FAT =>
					-- Game.floor_at(fpx, fpy): the tile's floor; a ramp adds
					-- (rise * s) >> 16, rise from the next tile in its direction
					maddr <= unsigned(std_logic_vector(fpy(21 downto 16))) & unsigned(std_logic_vector(fpx(21 downto 16)));
					wret <= CORE_FAT_D;
					core_state <= CORE_WAIT;

				when CORE_FAT_D =>
					ff <= resize(map_floor, 8);
					if (map_sp /= SPECIAL_RAMP) then
						fat <= resize(map_floor, 8);
						core_state <= fat_ret;
					else
						-- Ramp direction in ceil_tex: 0 +x, 1 -x, 2 +y, 3 -y; s from
						-- the fraction along it
						case map_data_i(TILE_CEIL_HI downto TILE_CEIL_LO) is
							when "00" =>
								fs <= resize(unsigned(std_logic_vector(fpx(15 downto 0))), 17);
								maddr <= maddr(11 downto 6) & (maddr(5 downto 0) + 1);
							when "01" =>
								fs <= to_unsigned(65536, 17) - unsigned(std_logic_vector(fpx(15 downto 0)));
								maddr <= maddr(11 downto 6) & (maddr(5 downto 0) - 1);
							when "10" =>
								fs <= resize(unsigned(std_logic_vector(fpy(15 downto 0))), 17);
								maddr <= (maddr(11 downto 6) + 1) & maddr(5 downto 0);
							when others =>
								fs <= to_unsigned(65536, 17) - unsigned(std_logic_vector(fpy(15 downto 0)));
								maddr <= (maddr(11 downto 6) - 1) & maddr(5 downto 0);
						end case;
						wret <= CORE_FAT_N;
						core_state <= CORE_WAIT;
					end if;

				when CORE_FAT_N =>
					-- rise (multiple of 8, -56..56) times s on the shared multiplier
					mul_a <= resize(signed(resize(map_floor, 9)) - signed(resize(ff, 9)), 24);
					mul_b <= signed(resize(fs, 18));
					core_state <= CORE_FAT_W;

				when CORE_FAT_W =>
					core_state <= CORE_FAT_M;

				when CORE_FAT_M =>
					-- floor + (rise * s) >> 16, mod 256 (bits 23:16 of the product)
					fat <= ff + unsigned(prod(23 downto 16));
					core_state <= fat_ret;

				when CORE_BFL =>
					-- Game.box_floor(bx, by, HALF): the highest floor_at() of the
					-- four box corners (bfk bit 0 picks x -/+, bit 1 picks y -/+)
					bfk <= "00";
					bfl <= (others => '0');
					fpx <= bx - HALF;
					fpy <= by - HALF;
					fat_ret <= CORE_BFL_N;
					core_state <= CORE_FAT;

				when CORE_BFL_N =>
					if (fat > bfl) then
						bfl <= fat;
					end if;
					if (bfk = 3) then
						core_state <= bfl_ret;
					else
						bfk <= bfk + 1;
						-- Corner bfk + 1: x - when its bit 0 is 0, y + from corner 2 on
						if (bfk(0) = '1') then
							fpx <= bx - HALF;
						else
							fpx <= bx + HALF;
						end if;
						if (bfk = 0) then
							fpy <= by - HALF;
						else
							fpy <= by + HALF;
						end if;
						fat_ret <= CORE_BFL_N;
						core_state <= CORE_FAT;
					end if;

				when CORE_LOS =>
					-- Game.los(): Bresenham from the actor's cell to the player's
					lx <= a_x(15 downto 10);
					ly <= a_y(15 downto 10);
					lx1 <= unsigned(std_logic_vector(px(21 downto 16)));
					ly1 <= unsigned(std_logic_vector(py(21 downto 16)));
					ldx <= abs(los_dx);
					ldy <= abs(los_dy);
					if (los_dx > 0) then
						lsx <= "01";
					elsif (los_dx < 0) then
						lsx <= "11";
					else
						lsx <= "00";
					end if;
					if (los_dy > 0) then
						lsy <= "01";
					elsif (los_dy < 0) then
						lsy <= "11";
					else
						lsy <= "00";
					end if;
					lerr <= resize(abs(los_dx), 9) - resize(abs(los_dy), 9);
					lcnt <= (others => '0');
					core_state <= CORE_LOS_IT;

				when CORE_LOS_IT =>
					-- One loop iteration: at the target -> visible; else step
					-- and test the new cell unless it is the target
					if ((lx = lx1) and (ly = ly1)) then
						los <= '1';
						core_state <= los_ret;
					elsif (lcnt = 64) then -- Step limit (the model's loop bound)
						los <= '0';
						core_state <= los_ret;
					else
						lerr <= los_nerr;
						lx <= los_nx;
						ly <= los_ny;
						lcnt <= lcnt + 1;
						if ((los_tx = '0') or (los_ty = '0')) then -- Not the target: test the cell
							maddr <= los_ny & los_nx;
							wret <= CORE_LOS_D;
							core_state <= CORE_WAIT;
						end if;
					end if;

				when CORE_LOS_D =>
					if (map_solid = '1') then
						los <= '0';
						core_state <= los_ret;
					else
						core_state <= CORE_LOS_IT;
					end if;

				when CORE_DB =>
					-- Game.door_blocked(door di): the player, then every
					-- active solid actor (one per clock)
					if (in_cell(px, py, door_x(dk), door_y(dk))) then
						blocked <= '1';
						core_state <= db_ret;
					else
						aaddr <= (others => '0');
						wret <= CORE_DB_S;
						core_state <= CORE_WAIT;
					end if;

				when CORE_DB_S =>
					if (hit_door = '1') then
						blocked <= '1';
						core_state <= db_ret;
					elsif (aaddr = 31) then
						blocked <= '0';
						core_state <= db_ret;
					else
						aaddr <= aaddr + 1;
						wret <= CORE_DB_S;
						core_state <= CORE_WAIT;
					end if;

				when CORE_SND =>
					-- Game.sound(): at most 4 per step; an actor's sound gets volume from its
					-- distance (0 drops it) and pan from its sideways offset (shared multiplier)
					core_state <= snd_ret;
					if (sq_n /= 4) then
						if (snd_act = '0') then
							-- The player's own sound: full volume, centred
							sq(to_integer(sq_n(1 downto 0))) <= "000000" & "111111" & std_logic_vector(snd_id);
							sq_n <= sq_n + 1;
						else
							core_state <= CORE_SND_W;
						end if;
					end if;

				when CORE_SND_W =>
					core_state <= CORE_SND_V;

				when CORE_SND_V =>
					-- avol is three clocks behind a; a may have changed in the
					-- clock before CORE_SND (CORE_DA -> CORE_ENTER -> CORE_SND)
					svol <= avol;
					core_state <= snd_ret;
					if (avol /= 0) then
						mul_a <= q16(a_x) - px; -- rx
						mul_b <= -sn;
						core_state <= CORE_SND_M1;
					end if;

				when CORE_SND_M1 =>
					mul_a <= q16(a_y) - py; -- ry
					mul_b <= cs;
					core_state <= CORE_SND_M2;

				when CORE_SND_M2 =>
					acc <= prod; -- rx * -sin
					core_state <= CORE_SND_M3;

				when CORE_SND_M3 =>
					lat <= pan_sum(42 downto 27); -- (acc + ry * cos) >> 27
					core_state <= CORE_SND_M4;

				when CORE_SND_M4 =>
					sq(to_integer(sq_n(1 downto 0))) <= std_logic_vector(pan_c) & std_logic_vector(svol) &
						std_logic_vector(snd_id);
					sq_n <= sq_n + 1;
					core_state <= snd_ret;

				when CORE_DP =>
					-- Game.damage_player(dmg): armor first (arm_save)
					core_state <= dp_ret;
					if (pl_health /= 0) then
						if (pl_armor > 0) then
							pl_armor <= pl_armor - arm_save(7 downto 0);
							dmg <= dmg - arm_save(5 downto 0);
						end if;
						core_state <= CORE_DP2;
					end if;

				when CORE_DP2 =>
					-- Health minus what the armor did not take, floor 0
					if (pl_health > dmg) then
						pl_health <= pl_health - dmg;
						snd_id <= to_unsigned(SND_PLAYER_PAIN, 5);
					else
						pl_health <= (others => '0');
						snd_id <= to_unsigned(SND_PLAYER_DEATH, 5);
					end if;
					dflash <= to_unsigned(8, 4);
					snd_act <= '0';
					snd_ret <= dp_ret;
					core_state <= CORE_SND;

				when CORE_ENTER =>
					-- Game.enter(): new state and timer; entry actions run now
					-- (LOOK, CHASE and FLY run every frame in CORE_ACT_GO instead)
					a_state <= en_s;
					a_timer <= en_dur;
					core_state <= en_ret;
					snd_act <= '1';
					snd_ret <= en_ret;
					case en_act is
						when A_SHOOT =>
							snd_id <= to_unsigned(SND_SHOOT, 5);
							snd_ret <= CORE_A_SHOOT2;
							core_state <= CORE_SND;
						when A_FIRE =>
							snd_id <= to_unsigned(SND_FIRE, 5);
							snd_ret <= CORE_A_FIRE2;
							core_state <= CORE_SND;
						when A_MELEE =>
							snd_id <= to_unsigned(SND_CLAW, 5);
							snd_ret <= CORE_A_MELEE2;
							core_state <= CORE_SND;
						when A_PAIN =>
							snd_id <= to_unsigned(SND_PAIN, 5);
							core_state <= CORE_SND;
						when A_DIE =>
							a_solid <= '0';
							kills <= kills + 1;
							if (a_typ = T_BOSS) then
								boss_timer <= to_unsigned(BOSS_TIME, 8);
							end if;
							snd_id <= to_unsigned(SND_DEATH, 5);
							snd_ret <= CORE_A_DIE2;
							core_state <= CORE_SND;
						when A_EXPLODE =>
							snd_id <= to_unsigned(SND_EXPLODE, 5);
							core_state <= CORE_SND;
						when A_REMOVE =>
							a_active <= '0';
						when others =>
							null;
					end case;

				when CORE_A_SHOOT2 =>
					los_ret <= CORE_A_SHOOT3;
					core_state <= CORE_LOS;

				when CORE_A_SHOOT3 =>
					-- Hit chance max(40, 200 - (dist >> 7)), then 3 * (1 + (random & 3)); for
					-- dist >> 7 < 160 the test is random + (dist >> 7) < 200
					core_state <= en_ret;
					if (los = '1') then
						lfsr <= lfsr_n;
						if ((adist(18 downto 7) >= 160) and (lfsr_n(7 downto 0) < 40)) or
							((adist(18 downto 7) < 160) and (resize(lfsr_n(7 downto 0), 12) + adist(18 downto 7) < 200)) then
							core_state <= CORE_A_SHOOT4;
						end if;
					end if;

				when CORE_A_SHOOT4 =>
					lfsr <= lfsr_n;
					dmg <= times_const(resize(lfsr_n(1 downto 0), 4) + 1, 3);
					dp_ret <= en_ret;
					core_state <= CORE_DP;

				when CORE_A_FIRE2 =>
					-- Fireball toward the player from the actor's position
					sp_type <= to_unsigned(T_FIREBALL, 3);
					sp_state <= to_unsigned(ST_FLY_A, 7);
					sp_health <= resize(fire_dir, 12);
					sp_ret <= en_ret;
					core_state <= CORE_SPAWN;

				when CORE_A_MELEE2 =>
					core_state <= en_ret;
					if (adist < MELEE_RANGE) then
						lfsr <= lfsr_n;
						dmg <= times_const(resize(lfsr_n(2 downto 0), 4) + 1, TYPE_TABLE(a_k)(TP_MULT)); -- mult * (1 + (random & 7))
						dp_ret <= en_ret;
						core_state <= CORE_DP;
					end if;

				when CORE_A_DIE2 =>
					-- A grunt drops a box of bullets
					core_state <= en_ret;
					if (a_typ = T_GRUNT) then
						sp_type <= to_unsigned(T_ITEM, 3);
						sp_state <= to_unsigned(ST_ITEM_IDLE, 7);
						sp_health <= to_unsigned(I_BULLETS, 12);
						sp_ret <= en_ret;
						core_state <= CORE_SPAWN;
					end if;

				when CORE_SPAWN =>
					aaddr <= (others => '0');
					wret <= CORE_SPAWN_S;
					core_state <= CORE_WAIT;

				when CORE_SPAWN_S =>
					-- Game.spawn(): first inactive slot (none free: nothing); a new
					-- active actor at a's position, not solid, awake or ambush
					if (aq(ACTOR_ACTIVE) = '0') then
						aram_we <= '1';
						aram_waddr <= aaddr;
						aram_wdata <= "0001" & std_logic_vector(sp_type) & std_logic_vector(sp_health) &
							std_logic_vector(sp_dur) & std_logic_vector(sp_state) & std_logic_vector(a_y) &
							std_logic_vector(a_x);
						core_state <= sp_ret;
					elsif (aaddr = 31) then
						core_state <= sp_ret;
					else
						aaddr <= aaddr + 1;
						wret <= CORE_SPAWN_S;
						core_state <= CORE_WAIT;
					end if;

				when others =>
					null;
			end case;
		end if;
	end process;

	------------------------------------------------------------------
	-- Outputs
	------------------------------------------------------------------
	load_req_o <= load_req;
	load_level_o <= std_logic_vector(level);
	map_addr_o <= std_logic_vector(maddr);
	-- Secret found (CORE_SPEC2 on a pushwall tile): the same tile with its
	-- special (16:14) cleared
	map_we <= '1' when ((core_state = CORE_SPEC2) and (map_sp = SPECIAL_PUSHWALL)) else '0';
	map_we_o <= map_we;
	map_wdata_o <= map_data_i(23 downto 17) & "000" & map_data_i(13 downto 0);
	span_addr_o <= std_logic_vector(span_addr);
	zwall_addr_o <= std_logic_vector(zw_addr);
	cam_x_o <= cam_x_out;
	cam_y_o <= cam_y_out;
	angle_o <= angle_out;
	eye_o <= eye_out;
	doors_o <= doors_out;
	player_x_o <= player_x_out;
	player_y_o <= player_y_out;
	hud_o <= hud_out;
	keypos_o <= keypos_out;
	music_o <= music_out;
	tint_o <= tint_out;
	fx_o <= fx_out;
	spr_data_o <= spr_q;
	spr_count_o <= spr_count_out;
	render_start_o <= start;
	busy_o <= '0' when (core_state = CORE_IDLE) else '1';
	snd_valid_o <= '1' when (oq_p /= oq_n) else '0';
	-- Command at the queue read pointer: priority (from the id) & pan & volume & id
	oq_word <= oq(to_integer(oq_p(1 downto 0)));
	snd_data_o <= std_logic_vector(to_unsigned(SOUND_PRIORITY(to_integer(unsigned(oq_word(SND_ID_HI downto SND_ID_LO)))), 4)) &
		oq_word;
	level_loaded_o <= loaded;
	state_data_o <= sdata;
	crc_o <= crc_out;
end arch;

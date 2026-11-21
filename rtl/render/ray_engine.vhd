--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Ray Engine
-- Module Name:    ray_engine
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Ray engine: for screen columns 0..319 casts one
--                 ray through the 64 x 64 tile map (DDA) front to back and
--                 emits the column as a run of spans (floor, ceiling and
--                 textured spans) for the column rasterizer, plus the clip
--                 entries of every height edge (sprite clipping) and the
--                 column's z. Bit-exact with column() and class Column in
--                 tools/model/render.py (the specification; its docstring
--                 gives the span rules).
--
--                 Fixed-point formats (render_pkg):
--                   position Q6.16 (22 bits), angle 10 bits, sin/cos,
--                   plane and ray Q2.16 signed (18 bits), deltaDist Q8.16
--                   (24 bits, saturated), sideDist and distances Q16.16 in
--                   32 bits, lineHeight Q12.8, screen rows Q.8, heights in
--                   units (64 per tile), eye 0..127.
--                 Every "x >> n" of the model is an arithmetic shift of a
--                 two's complement product, taken as a bit slice of the
--                 full-width product (floor, like Python).
--
--                 One FSM (ray_state, one clocked process). Per frame
--                 (RAY_F*): sin, cos, plane; the camera's tile (and, on a
--                 ramp, the tile its ramp rises to) gives the starting
--                 light, floor F and ceiling C of every column.
--                 Per column (RAY_C*): ray, deltaDist (two dividers),
--                 sideDist.
--                 DDA (RAY_STEP, RAY_CHECK, RAY_TILE: 3 clocks per cell;
--                 equal side distances step in y). A ramp tile being left
--                 first runs its 7 sub-edges (RAY_RK) at
--                 (sd - dd) + ((k * dd) >> 3).
--                 A new open tile whose floor or ceiling differs (RAY_OPEN;
--                 a ramp needs its neighbor tile, RAY_RN*) is a height edge;
--                 a wall, a closed door or the 128th cell ends the column.
--                 Height edge and wall (one "event", RAY_E* then RAY_X*):
--                   E0..E3  lineHeight = N_LH / d (32-bit divisor) while
--                           the shared multiplier gives the texture
--                           column and tex_step
--                   E4, E5  five rows at once: row(h) =
--                           ((30720 + ((lh * (eye - h)) >> 6)) + 127) >> 8
--                           for F, C, Fn, Cn and 64 (texture anchor),
--                           on five small dedicated multipliers
--                   E6..E8  the window rules, one per clock: floor span,
--                           ceiling span, then riser and upper wall
--                           (edge) or the wall (final); clip entry
--                           (z, top, bottom), a
--                           closed window as (z, 1, 0); up to 16 per
--                           column, then the last one is rewritten
--                   X*      the up-to-four spans go out in model order;
--                           a textured span first gets v0 =
--                           ((y0 * 256 + 128 - top) * tex_step) >> 8
--                 About 60 clocks per height edge (the divide is 34) and 3
--                 per DDA cell; under 200,000 clocks for the golden frames.
--
--                 Light (render.py Frame.light): a tile's light is
--                 clamp(light + lmod(light type), 0, 15), lmod from fx_i
--                 (the camera tile and every open tile the walk enters);
--                 spans then take clamp(light - min(15, d >> 18) - side).
--                 Interfaces: frame inputs stable from start_i to done_o; map
--                 read port with 1-clock latency (cells, ramp neighbors);
--                 descriptor out (valid/ready, render_types_pkg layout, one
--                 span each, DESC_LAST on the last span of a column; the
--                 fields a kind does not use are 0); clip and clip-count
--                 writes; z-buffer write once per column after its last
--                 span; seen bits of every cell the DDA enters; done_o after
--                 the last column.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, render_pkg,
--                 render_types_pkg, divider
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.10 - Locked doors (specials 2, 3) are doors too; seen_* writes
--                 every visited cell (minimap)
-- Revision 2.00 - Floor and ceiling heights, ramps, span
--                 descriptors, clip entries
-- Revision 2.10 - Light effects: every tile light is offset by fx_i's
--                 lmod of its light type (tile bits 13:12) and clamped to
--                 0..15 before distance and side; door-table lookup
--                 registered (timing)
-- Revision 2.20 - Plain signals instead of records; one-process state machine
-- Additional Comments:
--                 The map border must be solid (level tool enforces it),
--                 which keeps distances below 2^24 and tex_step inside its
--                 24-bit descriptor field.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.render_pkg.all;
use work.render_types_pkg.all;

entity ray_engine is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		start_i: in std_logic; -- Pulse: render a frame
		pos_x_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Camera x, Q6.16
		pos_y_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Camera y, Q6.16
		angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0); -- View angle
		eye_i: in std_logic_vector(EYE_BITS - 1 downto 0); -- Eye height 0..127
		doors_i: in std_logic_vector(DOORS_BITS - 1 downto 0); -- Door table
		fx_i: in std_logic_vector(FX_BITS - 1 downto 0); -- Effects: light offset per light type
		map_addr_o: out std_logic_vector(11 downto 0); -- Tile index y * 64 + x
		map_data_i: in std_logic_vector(23 downto 0); -- Tile word, 1 clock later
		desc_valid_o: out std_logic; -- Span descriptor present
		desc_ready_i: in std_logic; -- Span descriptor taken
		desc_o: out std_logic_vector(DESC_BITS - 1 downto 0); -- Span descriptor
		zbuf_we_o: out std_logic; -- Z-buffer write
		zbuf_addr_o: out std_logic_vector(8 downto 0); -- Column
		zbuf_data_o: out std_logic_vector(15 downto 0); -- Column z, Q6.10
		clip_we_o: out std_logic; -- Clip entry write
		clip_addr_o: out std_logic_vector(12 downto 0); -- Column & entry index
		clip_data_o: out std_logic_vector(CLIP_BITS - 1 downto 0); -- (z, top, bottom)
		ccount_we_o: out std_logic; -- Clip entry count write
		ccount_addr_o: out std_logic_vector(8 downto 0); -- Column
		ccount_data_o: out std_logic_vector(4 downto 0); -- Entries 0..16
		seen_we_o: out std_logic; -- Write a '1' to the minimap seen bit of ...
		seen_addr_o: out std_logic_vector(11 downto 0); -- ... this cell (y * 64 + x)
		busy_o: out std_logic; -- Frame in progress
		done_o: out std_logic -- Pulse: last column finished
	);
end ray_engine;

architecture arch of ray_engine is
	component divider is
		generic(
			NUM_BITS: positive := 33;
			DEN_BITS: positive := 24;
			QUO_BITS: positive := 24
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			num_i: in std_logic_vector(NUM_BITS - 1 downto 0);
			den_i: in std_logic_vector(DEN_BITS - 1 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic;
			quo_o: out std_logic_vector(QUO_BITS - 1 downto 0)
		);
	end component;

	type ray_state_type is (
		RAY_IDLE,
		RAY_F0, -- sin ROM at angle, map read of the camera cell
		RAY_F1, -- sin(a); camera tile; read the tile its ramp rises to
		RAY_F2, -- cos(a); ramp neighbor; camera tile light and heights; multiply -sin * PLANE_Q
		RAY_F3, -- plane x; multiply cos * PLANE_Q
		RAY_F4, -- plane y
		RAY_C0, -- camera x ROM read
		RAY_C1, -- multiply plane x * cam
		RAY_C2, -- ray x; multiply plane y * cam
		RAY_C3, -- ray y
		RAY_C4, -- start the deltaDist dividers
		RAY_C5, -- wait for them; multiply x fraction * deltaDist x
		RAY_C6, -- sideDist x; multiply y fraction * deltaDist y
		RAY_C7, -- sideDist y; column state from the camera tile
		RAY_STEP, -- one DDA step, map read of the new cell
		RAY_CHECK, -- new cell's tile arrives
		RAY_RK, -- sub-edge k of the ramp tile being left
		RAY_TILE, -- the new cell: wall, door or open
		RAY_DOOR, -- door: hit coordinate on the door plane
		RAY_RN0, -- open ramp tile: read the tile it rises to
		RAY_RN1, -- its floor; entry step from the face or ...
		RAY_RN2, -- ... from the hit position (multiply)
		RAY_OPEN, -- heights of the new tile: edge or not
		RAY_E0, -- event: start lineHeight; multiply d * ray (texture column)
		RAY_E1, -- texture column; multiply d * M_TS
		RAY_E2, -- tex_step
		RAY_E3, -- lineHeight
		RAY_E4, -- row products
		RAY_E5, -- rows
		RAY_E6, -- floor span
		RAY_E6B, -- ceiling span
		RAY_E7, -- riser, or the wall
		RAY_E8, -- upper wall; clip entry
		RAY_X0, -- next span to send; textured: multiply for v0
		RAY_X1, -- v0
		RAY_X2, -- descriptor out
		RAY_EVEND, -- event finished: back to the walk or end the column
		RAY_COLEND -- z-buffer and clip count, next column
	);

	subtype row_t is signed(15 downto 0); -- Screen row, far outside 0..239 allowed
	-- Span rows as naturals: an array of unsigned would make every "unsigned & unsigned"
	-- in this unit ambiguous
	type rows4_t is array (0 to 3) of natural range 0 to 255;

	------------------------------------------------------------------
	-- FSM registers (all set in the one clocked process below)
	------------------------------------------------------------------
	signal ray_state: ray_state_type := RAY_IDLE;
	signal col: unsigned(8 downto 0) := (others => '0');
	signal sn: signed(17 downto 0) := (others => '0'); -- sin(angle), Q2.16
	signal cs: signed(17 downto 0) := (others => '0'); -- cos(angle)
	signal plx: signed(17 downto 0) := (others => '0'); -- Camera plane
	signal ply: signed(17 downto 0) := (others => '0');
	signal cam: signed(17 downto 0) := (others => '0');
	signal rx: signed(17 downto 0) := (others => '0'); -- Ray direction, Q2.16
	signal ry: signed(17 downto 0) := (others => '0');
	signal ddx: unsigned(23 downto 0) := (others => '0'); -- deltaDist, Q8.16
	signal ddy: unsigned(23 downto 0) := (others => '0');
	signal sdx: unsigned(31 downto 0) := (others => '0'); -- sideDist, Q16.16
	signal sdy: unsigned(31 downto 0) := (others => '0');
	signal mx: unsigned(5 downto 0) := (others => '0'); -- Map cell
	signal my: unsigned(5 downto 0) := (others => '0');
	signal side: std_logic := '0'; -- Face of the last step: 0 x, 1 y
	signal steps: natural range 0 to MAX_STEPS := 0;
	signal dnext: unsigned(31 downto 0) := (others => '0'); -- Distance at which the last step entered its cell
	signal denter: unsigned(31 downto 0) := (others => '0'); -- Distance at which the current tile was entered
	signal ntile: std_logic_vector(23 downto 0) := (others => '0'); -- Tile of the cell just entered
	-- Camera tile (per frame)
	signal c_light: unsigned(3 downto 0) := (others => '0');
	signal c_f: unsigned(6 downto 0) := (others => '0');
	signal c_c: unsigned(6 downto 0) := (others => '0');
	signal c_ramp: std_logic := '0';
	signal c_axis: std_logic := '0';
	signal c_pos: std_logic := '0';
	signal c_base: unsigned(6 downto 0) := (others => '0');
	signal c_diff: signed(3 downto 0) := (others => '0');
	-- Walk state of the current tile
	signal light: unsigned(3 downto 0) := (others => '0'); -- Light in front of the next boundary
	signal cur_f: unsigned(6 downto 0) := (others => '0'); -- Current floor and ceiling heights
	signal cur_c: unsigned(6 downto 0) := (others => '0');
	signal ramp: std_logic := '0'; -- The current tile is a ramp ...
	signal axis: std_logic := '0'; -- ... along x (0) or y (1), ...
	signal rpos: std_logic := '0'; -- ... rising toward + (step j = q) or - (j = 7 - q), ...
	signal base: unsigned(6 downto 0) := (others => '0'); -- ... from its floor ...
	signal diff: signed(3 downto 0) := (others => '0'); -- ... by diff units per step
	-- Tile being entered (applied when the walk moves on)
	signal n_ramp: std_logic := '0';
	signal n_axis: std_logic := '0';
	signal n_pos: std_logic := '0';
	signal n_base: unsigned(6 downto 0) := (others => '0');
	signal n_diff: signed(3 downto 0) := (others => '0');
	signal n_f: unsigned(6 downto 0) := (others => '0');
	signal n_c: unsigned(6 downto 0) := (others => '0');
	-- Ramp sub-edges
	signal near: signed(33 downto 0) := (others => '0'); -- Distance of the tile's near edge on the ramp axis
	signal acc: unsigned(26 downto 0) := (others => '0'); -- k * deltaDist
	signal k: unsigned(2 downto 0) := (others => '0');
	signal mv: std_logic := '0'; -- Moving toward + on the ramp axis
	-- Door
	signal dmid: unsigned(31 downto 0) := (others => '0');
	-- Event (height edge or wall)
	signal ev_final: std_logic := '0'; -- Wall: the column ends here
	signal ev_ramp: std_logic := '0'; -- Sub-edge of a ramp (else an open tile edge)
	signal ev_d: unsigned(31 downto 0) := (others => '0'); -- Distance, PERP_MIN applied
	signal ev_side: std_logic := '0';
	signal ev_fn: unsigned(6 downto 0) := (others => '0'); -- Heights behind the edge
	signal ev_cn: unsigned(6 downto 0) := (others => '0');
	signal ev_tex: std_logic_vector(3 downto 0) := (others => '0');
	signal ev_given: std_logic := '0'; -- Texture column already known (door)
	signal tex_col: unsigned(5 downto 0) := (others => '0');
	signal tex_step: unsigned(23 downto 0) := (others => '0');
	signal lh: unsigned(19 downto 0) := (others => '0'); -- lineHeight, Q12.8
	signal rf: row_t := (others => '0'); -- First row at or below F, C, Fn, Cn
	signal rc: row_t := (others => '0');
	signal rt: row_t := (others => '0');
	signal rb: row_t := (others => '0');
	signal top_f: signed(27 downto 0) := (others => '0'); -- Q.8 row of height 64 (texture anchor)
	signal wtop: row_t := (others => '0'); -- Open window
	signal wbot: row_t := (others => '0');
	signal sv: std_logic_vector(3 downto 0) := (others => '0'); -- Spans: 0 floor, 1 ceiling, 2 riser
	signal sy0: rows4_t := (others => 0); -- or wall, 3 upper wall
	signal sy1: rows4_t := (others => 0);
	signal e_floor: unsigned(6 downto 0) := (others => '0');
	signal e_ceil: unsigned(6 downto 0) := (others => '0');
	signal closed: std_logic := '0'; -- The event ends the column
	signal last: unsigned(1 downto 0) := (others => '0'); -- Last span of the column (when closed)
	signal slot: unsigned(1 downto 0) := (others => '0');
	signal nclip: unsigned(4 downto 0) := (others => '0');
	signal zval: unsigned(15 downto 0) := (others => '0');
	signal clip_we: std_logic := '0';
	signal clip_addr: unsigned(12 downto 0) := (others => '0');
	signal clip_data: std_logic_vector(CLIP_BITS - 1 downto 0) := (others => '0');
	signal seen_we: std_logic := '0';
	signal seen_addr: std_logic_vector(11 downto 0) := (others => '0');
	signal desc: std_logic_vector(DESC_BITS - 1 downto 0) := (others => '0');
	signal desc_valid: std_logic := '0';
	signal mul_a: signed(32 downto 0) := (others => '0'); -- Multiplier operands
	signal mul_b: signed(24 downto 0) := (others => '0');
	signal mul_go: std_logic := '0';
	signal dd_go: std_logic := '0';
	signal lh_go: std_logic := '0';
	signal done: std_logic := '0';

	-- Shared multiplier pipeline: mul_a/b -> mul_p1 -> mul_p
	signal mul_p1: signed(57 downto 0) := (others => '0');
	signal mul_p: signed(57 downto 0) := (others => '0');
	signal mul_v1: std_logic := '0';
	signal mul_v: std_logic := '0';

	-- Row products lh * (eye - h), registered (RAY_E4 -> RAY_E5)
	signal lh_s: signed(20 downto 0);
	signal prod_f, prod_c, prod_fn, prod_cn, prod_64: signed(28 downto 0) := (others => '0');

	-- ROMs (registered outputs)
	signal sin_addr: unsigned(9 downto 0);
	signal sin_data: signed(17 downto 0) := (others => '0');
	signal camx_data: signed(17 downto 0) := (others => '0');

	-- Dividers
	constant TWO_32: std_logic_vector(32 downto 0) := '1' & (31 downto 0 => '0');
	constant N_LH_33: std_logic_vector(32 downto 0) := std_logic_vector('0' & N_LH);
	signal ddx_den: std_logic_vector(23 downto 0);
	signal ddy_den: std_logic_vector(23 downto 0);
	signal lh_den: std_logic_vector(31 downto 0);
	signal ddx_busy, ddy_busy, lh_busy: std_logic;
	signal ddx_q, ddy_q, lh_q: std_logic_vector(23 downto 0);

	-- Frame inputs as numbers
	signal pos_x: unsigned(21 downto 0);
	signal pos_y: unsigned(21 downto 0);
	signal eye: signed(8 downto 0);

	-- Door table lookup for the current cell: open amount << 10, registered (door_hit is
	-- the compare of this clock; RAY_DOOR reads door_open at least two clocks after
	-- RAY_STEP moved the cell, so the register always holds the current cell's entry)
	signal door_hit: unsigned(16 downto 0);
	signal door_open: unsigned(16 downto 0) := (others => '0');
	signal map_addr: std_logic_vector(11 downto 0);
	signal step_x: boolean;
	-- Ramp neighbor read: cell (rn_x, rn_y) and ramp direction (0 +x, 1 -x, 2 +y, 3 -y)
	signal rn_x, rn_y: unsigned(5 downto 0);
	signal rn_dir: std_logic_vector(1 downto 0);

	-- Fields of ntile (the tile just entered; the camera tile in RAY_F2)
	signal nt_lmod: signed(4 downto 0); -- Light offset of its light type
	signal nt_lsum: signed(6 downto 0); -- Its light + offset
	signal nt_light: unsigned(3 downto 0); -- ... clamped to 0..15
	signal nt_floor: unsigned(6 downto 0); -- floor_h * 8 units
	signal nt_ceil: unsigned(6 downto 0); -- 64 - ceil_h * 8 units
	signal nt_ramp: std_logic; -- Special 7: a ramp
	signal nb_diff: signed(3 downto 0); -- Ramp rise per step: neighbor floor_h - own floor_h

	-- Combinational values the FSM loads in one state (from registers and mul_p)
	signal frac_x, frac_y: unsigned(16 downto 0); -- Distance to the next x or y grid line
	signal along_x, along_y: unsigned(15 downto 0); -- Fraction of pos + (mul_p >> 16)
	signal hit_col: unsigned(5 downto 0); -- Texture column before mirroring
	signal door_mid: unsigned(31 downto 0); -- Distance of the door plane
	signal door_frac: unsigned(16 downto 0); -- Hit position along the door
	signal door_col: unsigned(16 downto 0); -- ... past the open part
	signal rk_d: signed(33 downto 0); -- Distance of ramp sub-edge k
	signal z_sat: unsigned(15 downto 0); -- min(ev_d >> 6, 65535)
	signal floor_top, ceil_bot, riser_top, upper_bot, upper_top: row_t; -- Window rules
	signal span_y0, span_y1: natural range 0 to 255; -- Rows of span slot
	signal v0_off: signed(27 downto 0); -- y0 * 256 + 128 - top
	signal dist_light: unsigned(3 downto 0); -- min(15, ev_d >> 18)
	signal light_diff: signed(5 downto 0); -- light - dist_light - side
	signal span_light: unsigned(3 downto 0); -- ... clamped at 0
	signal span_desc: std_logic_vector(DESC_BITS - 1 downto 0); -- Descriptor of span slot

	-- Floor of step q of a ramp: base + j * diff, j = q (rising toward +)
	-- or 7 - q; diff is the per-step rise (the rise is a multiple of 8)
	function step_height(base: unsigned(6 downto 0); diff: signed(3 downto 0); pos: std_logic;
		q: unsigned(2 downto 0)) return unsigned is
		variable j: unsigned(2 downto 0);
		variable h: signed(8 downto 0);
	begin
		if (pos = '1') then
			j := q;
		else
			j := 7 - q;
		end if;
		h := signed(resize(base, 9)) + resize(diff * signed('0' & j), 9);
		return unsigned(h(6 downto 0));
	end function;

	-- d (>= PERP_MIN)
	function clamp_d(d: unsigned(31 downto 0)) return unsigned is
	begin
		if (d < PERP_MIN) then
			return to_unsigned(PERP_MIN, 32);
		end if;
		return d;
	end function;

	-- First row at or below Q.8 coordinate 30720 + (p >> 6): (yq + 127) >> 8
	function row_of(p: signed(28 downto 0)) return signed is
	begin
		return resize(shift_right(to_signed(HORIZON * 256 + 127, 29) + shift_right(p, 6), 8), 16);
	end function;

	function smax(a, b: row_t) return row_t is
	begin
		if (a > b) then
			return a;
		end if;
		return b;
	end function;

	function smin(a, b: row_t) return row_t is
	begin
		if (a < b) then
			return a;
		end if;
		return b;
	end function;
begin
	pos_x <= unsigned(pos_x_i);
	pos_y <= unsigned(pos_y_i);
	eye <= signed(resize(unsigned(eye_i), 9));

	------------------------------------------------------------------
	-- Tables
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			sin_data <= to_signed(SIN_TABLE(to_integer(sin_addr)), 18);
			camx_data <= to_signed(CAMX_TABLE(to_integer(col)), 18);
		end if;
	end process;

	-- RAY_F1 reads cos = sin(angle + 1/4 turn), every other state sin
	sin_addr <= unsigned(angle_i) + 256 when (ray_state = RAY_F1) else unsigned(angle_i);

	-- First matching entry of the door table (an unused entry has open 0): the loop
	-- runs from the last entry down, so the lowest matching entry is assigned last
	process(doors_i, mx, my)
	begin
		door_hit <= (others => '0');
		for i in 7 downto 0 loop
			if ((unsigned(doors_i(DOOR_BITS * i + DOOR_X_HI downto DOOR_BITS * i + DOOR_X_LO)) = mx) and
				(unsigned(doors_i(DOOR_BITS * i + DOOR_Y_HI downto DOOR_BITS * i + DOOR_Y_LO)) = my)) then
				door_hit <= unsigned(doors_i(DOOR_BITS * i + DOOR_OPEN_HI downto DOOR_BITS * i + DOOR_OPEN_LO)) &
					"0000000000";
			end if;
		end loop;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			door_open <= (others => '0');
		elsif rising_edge(clk_i) then
			door_open <= door_hit;
		end if;
	end process;

	------------------------------------------------------------------
	-- Shared multiplier: 33 x 25 signed, product two clocks after the
	-- operands
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			mul_p1 <= mul_a * mul_b;
			mul_p <= mul_p1;
		end if;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			mul_v1 <= '0';
			mul_v <= '0';
		elsif rising_edge(clk_i) then
			mul_v1 <= mul_go;
			mul_v <= mul_v1;
		end if;
	end process;

	------------------------------------------------------------------
	-- Row products lh * (eye - h) for F, C, Fn, Cn and 64: five small
	-- multipliers (21 x 9 bits) side by side, so an edge's rows take one
	-- clock instead of five trips through the shared multiplier
	------------------------------------------------------------------
	lh_s <= signed('0' & lh);

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			prod_f <= resize(lh_s * (eye - signed(resize(cur_f, 9))), 29);
			prod_c <= resize(lh_s * (eye - signed(resize(cur_c, 9))), 29);
			prod_fn <= resize(lh_s * (eye - signed(resize(ev_fn, 9))), 29);
			prod_cn <= resize(lh_s * (eye - signed(resize(ev_cn, 9))), 29);
			prod_64 <= resize(lh_s * (eye - to_signed(64, 9)), 29);
		end if;
	end process;

	------------------------------------------------------------------
	-- Dividers: deltaDist x, deltaDist y (2^32 / |ray|), lineHeight
	------------------------------------------------------------------
	-- Resize to 19 bits before abs: |-2^17| does not fit in 18
	ddx_den <= std_logic_vector(resize(unsigned(abs(resize(rx, 19))), 24));
	ddy_den <= std_logic_vector(resize(unsigned(abs(resize(ry, 19))), 24));
	lh_den <= std_logic_vector(ev_d);

	div_ddx: divider
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			start_i => dd_go,
			num_i => TWO_32,
			den_i => ddx_den,
			busy_o => ddx_busy,
			done_o => open,
			quo_o => ddx_q
		);

	div_ddy: divider
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			start_i => dd_go,
			num_i => TWO_32,
			den_i => ddy_den,
			busy_o => ddy_busy,
			done_o => open,
			quo_o => ddy_q
		);

	-- lineHeight = N_LH / d with the full 32-bit distance as divisor
	div_lh: divider
		generic map (
			NUM_BITS => 33,
			DEN_BITS => 32,
			QUO_BITS => 24
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			start_i => lh_go,
			num_i => N_LH_33,
			den_i => lh_den,
			busy_o => lh_busy,
			done_o => open,
			quo_o => lh_q
		);

	------------------------------------------------------------------
	-- Fields of ntile
	------------------------------------------------------------------
	-- Tile light after the light type's offset: clamp(light + lmod(type), 0, 15),
	-- lmod signed 5-bit (FX_LMOD_W) at fx(5k + 4 .. 5k) for light type k = t(13:12)
	with ntile(13 downto 12) select
		nt_lmod <= signed(fx_i(4 downto 0)) when "00",
			signed(fx_i(9 downto 5)) when "01",
			signed(fx_i(14 downto 10)) when "10",
			signed(fx_i(19 downto 15)) when others;
	nt_lsum <= signed(resize(unsigned(ntile(11 downto 8)), 7)) + resize(nt_lmod, 7);
	nt_light <= to_unsigned(0, 4) when (nt_lsum < 0) else
		to_unsigned(15, 4) when (nt_lsum > 15) else
		unsigned(nt_lsum(3 downto 0));
	nt_floor <= resize(unsigned(ntile(19 downto 17)) & "000", 7);
	nt_ceil <= to_unsigned(64, 7) - (unsigned(ntile(22 downto 20)) & "000");
	nt_ramp <= '1' when (ntile(16 downto 14) = "111") else '0';
	-- With the neighbor tile on map_data_i (RAY_F2, RAY_RN1); one level = 8 units
	-- over 8 steps
	nb_diff <= signed('0' & map_data_i(19 downto 17)) - signed('0' & ntile(19 downto 17));

	------------------------------------------------------------------
	-- DDA step decision and the map address
	------------------------------------------------------------------
	step_x <= (sdx < sdy);

	-- RAY_F1: the tile the camera's ramp rises to (any cell if not a ramp);
	-- RAY_RN0: the tile the entered ramp rises to
	rn_x <= pos_x(21 downto 16) when (ray_state = RAY_F1) else mx;
	rn_y <= pos_y(21 downto 16) when (ray_state = RAY_F1) else my;
	rn_dir <= map_data_i(7 downto 6) when (ray_state = RAY_F1) else ntile(7 downto 6);

	process(ray_state, pos_x, pos_y, rn_x, rn_y, rn_dir, step_x, rx, ry, mx, my)
	begin
		if (ray_state = RAY_F0) then
			map_addr <= std_logic_vector(pos_y(21 downto 16) & pos_x(21 downto 16));
		elsif ((ray_state = RAY_F1) or (ray_state = RAY_RN0)) then
			case rn_dir is
				when "00" =>
					map_addr <= std_logic_vector(rn_y & (rn_x + 1));
				when "01" =>
					map_addr <= std_logic_vector(rn_y & (rn_x - 1));
				when "10" =>
					map_addr <= std_logic_vector((rn_y + 1) & rn_x);
				when others =>
					map_addr <= std_logic_vector((rn_y - 1) & rn_x);
			end case;
		elsif (step_x) then
			-- The cell entered by this step (RAY_STEP)
			if (rx < 0) then
				map_addr <= std_logic_vector(my & (mx - 1));
			else
				map_addr <= std_logic_vector(my & (mx + 1));
			end if;
		else
			if (ry < 0) then
				map_addr <= std_logic_vector((my - 1) & mx);
			else
				map_addr <= std_logic_vector((my + 1) & mx);
			end if;
		end if;
	end process;

	map_addr_o <= map_addr;

	------------------------------------------------------------------
	-- Combinational values for the FSM
	------------------------------------------------------------------
	-- sideDist start: fx * dd (ray going -x) or (65536 - fx) * dd (ray going +x)
	frac_x <= '0' & pos_x(15 downto 0) when (rx < 0) else to_unsigned(65536, 17) - pos_x(15 downto 0);
	frac_y <= '0' & pos_y(15 downto 0) when (ry < 0) else to_unsigned(65536, 17) - pos_y(15 downto 0);

	-- Only the fraction of (pos + (d * ray >> 16)) matters: low 16 bits of pos
	-- plus bits 31:16 of the product
	along_x <= pos_x(15 downto 0) + unsigned(mul_p(31 downto 16));
	along_y <= pos_y(15 downto 0) + unsigned(mul_p(31 downto 16));
	hit_col <= along_y(15 downto 10) when (ev_side = '0') else along_x(15 downto 10);

	-- Door plane half a cell in: entered at sd - dd, far edge at sd
	door_mid <= sdx - shift_right(resize(ddx, 32), 1) when (side = '0') else
		sdy - shift_right(resize(ddy, 32), 1);
	door_frac <= '0' & along_y when (side = '0') else '0' & along_x;
	door_col <= door_frac - door_open;

	-- Ramp sub-edge k: near + ((k * dd) >> 3)
	rk_d <= near + signed(resize(acc(26 downto 3), 34));

	z_sat <= to_unsigned(65535, 16) when (ev_d(31 downto 22) /= 0) else ev_d(21 downto 6);

	-- Window rules (RAY_E6 .. RAY_E8). The span tests compare against each
	-- operand of max/min separately (max(a, b) <= y is a <= y and b <= y), two short
	-- compares in parallel instead of a compare after a max/min (timing)
	floor_top <= smax(rf, wtop);
	ceil_bot <= smin(rc - 1, wbot);
	riser_top <= smax(rt, wtop);
	upper_bot <= smin(rb - 1, wbot);
	upper_top <= smax(wtop, rb) when (ev_cn < cur_c) else wtop;

	-- Span output: v0 offset and span light clamp(light - min(15, d >> 18) - side)
	span_y0 <= sy0(to_integer(slot));
	span_y1 <= sy1(to_integer(slot));
	v0_off <= to_signed(span_y0 * 256 + 128, 28) - top_f;
	dist_light <= to_unsigned(15, 4) when (ev_d(31 downto 22) /= 0) else ev_d(21 downto 18);
	light_diff <= signed(resize(light, 6)) - signed(resize(dist_light, 6)) when (ev_side = '0') else
		signed(resize(light, 6)) - signed(resize(dist_light, 6)) - 1;
	span_light <= to_unsigned(0, 4) when (light_diff < 0) else unsigned(light_diff(3 downto 0));

	-- Descriptor of span slot (loaded in RAY_X1; v0 = product >> 8)
	process(col, span_y0, span_y1, rx, ry, slot, e_floor, e_ceil, ev_tex, tex_col, mul_p, tex_step,
		span_light, ev_side, closed, last)
	begin
		span_desc <= (others => '0');
		span_desc(DESC_COL_HI downto DESC_COL_LO) <= std_logic_vector(col);
		span_desc(DESC_Y0_HI downto DESC_Y0_LO) <= std_logic_vector(to_unsigned(span_y0, 8));
		span_desc(DESC_Y1_HI downto DESC_Y1_LO) <= std_logic_vector(to_unsigned(span_y1, 8));
		span_desc(DESC_RX_HI downto DESC_RX_LO) <= std_logic_vector(rx);
		span_desc(DESC_RY_HI downto DESC_RY_LO) <= std_logic_vector(ry);
		case slot is
			when "00" =>
				span_desc(DESC_KIND_HI downto DESC_KIND_LO) <= KIND_FLOOR;
				span_desc(DESC_E_HI downto DESC_E_LO) <= std_logic_vector(e_floor);
			when "01" =>
				span_desc(DESC_KIND_HI downto DESC_KIND_LO) <= KIND_CEIL;
				span_desc(DESC_E_HI downto DESC_E_LO) <= std_logic_vector(e_ceil);
			when others =>
				span_desc(DESC_KIND_HI downto DESC_KIND_LO) <= KIND_WALL;
				if (slot = "10") then
					span_desc(DESC_TEX_HI downto DESC_TEX_LO) <= ev_tex;
				else
					span_desc(DESC_TEX_HI downto DESC_TEX_LO) <= std_logic_vector(to_unsigned(RISER_TEX, 4));
				end if;
				span_desc(DESC_TCOL_HI downto DESC_TCOL_LO) <= std_logic_vector(tex_col);
				span_desc(DESC_V0_HI downto DESC_V0_LO) <= std_logic_vector(mul_p(30 downto 8));
				span_desc(DESC_STEP_HI downto DESC_STEP_LO) <= std_logic_vector(tex_step);
				span_desc(DESC_LIGHT_HI downto DESC_LIGHT_LO) <= std_logic_vector(span_light);
				span_desc(DESC_SIDE) <= ev_side;
		end case;
		if ((closed = '1') and (slot = last)) then
			span_desc(DESC_LAST) <= '1';
		end if;
	end process;

	------------------------------------------------------------------
	-- FSM
	------------------------------------------------------------------
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			ray_state <= RAY_IDLE;
			col <= (others => '0');
			sn <= (others => '0');
			cs <= (others => '0');
			plx <= (others => '0');
			ply <= (others => '0');
			cam <= (others => '0');
			rx <= (others => '0');
			ry <= (others => '0');
			ddx <= (others => '0');
			ddy <= (others => '0');
			sdx <= (others => '0');
			sdy <= (others => '0');
			mx <= (others => '0');
			my <= (others => '0');
			side <= '0';
			steps <= 0;
			dnext <= (others => '0');
			denter <= (others => '0');
			ntile <= (others => '0');
			c_light <= (others => '0');
			c_f <= (others => '0');
			c_c <= (others => '0');
			c_ramp <= '0';
			c_axis <= '0';
			c_pos <= '0';
			c_base <= (others => '0');
			c_diff <= (others => '0');
			light <= (others => '0');
			cur_f <= (others => '0');
			cur_c <= (others => '0');
			ramp <= '0';
			axis <= '0';
			rpos <= '0';
			base <= (others => '0');
			diff <= (others => '0');
			n_ramp <= '0';
			n_axis <= '0';
			n_pos <= '0';
			n_base <= (others => '0');
			n_diff <= (others => '0');
			n_f <= (others => '0');
			n_c <= (others => '0');
			near <= (others => '0');
			acc <= (others => '0');
			k <= (others => '0');
			mv <= '0';
			dmid <= (others => '0');
			ev_final <= '0';
			ev_ramp <= '0';
			ev_d <= (others => '0');
			ev_side <= '0';
			ev_fn <= (others => '0');
			ev_cn <= (others => '0');
			ev_tex <= (others => '0');
			ev_given <= '0';
			tex_col <= (others => '0');
			tex_step <= (others => '0');
			lh <= (others => '0');
			rf <= (others => '0');
			rc <= (others => '0');
			rt <= (others => '0');
			rb <= (others => '0');
			top_f <= (others => '0');
			wtop <= (others => '0');
			wbot <= (others => '0');
			sv <= (others => '0');
			sy0 <= (others => 0);
			sy1 <= (others => 0);
			e_floor <= (others => '0');
			e_ceil <= (others => '0');
			closed <= '0';
			last <= (others => '0');
			slot <= (others => '0');
			nclip <= (others => '0');
			zval <= (others => '0');
			clip_we <= '0';
			clip_addr <= (others => '0');
			clip_data <= (others => '0');
			seen_we <= '0';
			seen_addr <= (others => '0');
			desc <= (others => '0');
			desc_valid <= '0';
			mul_a <= (others => '0');
			mul_b <= (others => '0');
			mul_go <= '0';
			dd_go <= '0';
			lh_go <= '0';
			done <= '0';
		elsif rising_edge(clk_i) then
			-- Single-clock pulses
			mul_go <= '0';
			dd_go <= '0';
			lh_go <= '0';
			done <= '0';
			clip_we <= '0';
			seen_we <= '0';

			case ray_state is
				when RAY_IDLE =>
					if (start_i = '1') then
						col <= (others => '0');
						ray_state <= RAY_F0;
					end if;

				------------------------------------------------------------
				-- Frame setup: trig, camera tile, plane
				------------------------------------------------------------
				when RAY_F0 =>
					ray_state <= RAY_F1;

				when RAY_F1 =>
					sn <= sin_data;
					ntile <= map_data_i;
					ray_state <= RAY_F2;

				when RAY_F2 =>
					-- ntile holds the camera tile, map_data_i the tile its ramp rises to
					cs <= sin_data;
					c_light <= nt_light;
					c_c <= nt_ceil;
					if (nt_ramp = '1') then
						-- A ramp's ceil_tex is its direction: bit 7 the axis (0 x, 1 y), bit 6 set = toward -
						c_ramp <= '1';
						c_axis <= ntile(7);
						c_pos <= not ntile(6);
						c_base <= nt_floor;
						c_diff <= nb_diff;
						-- The step under the camera: the eighth of the tile it stands in
						if (ntile(7) = '0') then
							c_f <= step_height(nt_floor, nb_diff, not ntile(6), pos_x(15 downto 13));
						else
							c_f <= step_height(nt_floor, nb_diff, not ntile(6), pos_y(15 downto 13));
						end if;
					else
						c_ramp <= '0';
						c_f <= nt_floor;
					end if;
					mul_a <= resize(-sn, 33);
					mul_b <= to_signed(PLANE_Q, 25);
					mul_go <= '1';
					ray_state <= RAY_F3;

				when RAY_F3 =>
					if (mul_v = '1') then
						plx <= mul_p(33 downto 16); -- (-sin * PLANE_Q) >> 16
						mul_a <= resize(cs, 33);
						mul_b <= to_signed(PLANE_Q, 25);
						mul_go <= '1';
						ray_state <= RAY_F4;
					end if;

				when RAY_F4 =>
					if (mul_v = '1') then
						ply <= mul_p(33 downto 16);
						ray_state <= RAY_C0;
					end if;

				------------------------------------------------------------
				-- Ray direction, deltaDist, sideDist
				------------------------------------------------------------
				when RAY_C0 =>
					ray_state <= RAY_C1;

				when RAY_C1 =>
					cam <= camx_data;
					mul_a <= resize(plx, 33);
					mul_b <= resize(camx_data, 25);
					mul_go <= '1';
					ray_state <= RAY_C2;

				when RAY_C2 =>
					if (mul_v = '1') then
						rx <= cs + mul_p(33 downto 16); -- ray = direction + plane * camera x
						mul_a <= resize(ply, 33);
						mul_b <= resize(cam, 25);
						mul_go <= '1';
						ray_state <= RAY_C3;
					end if;

				when RAY_C3 =>
					if (mul_v = '1') then
						ry <= sn + mul_p(33 downto 16);
						ray_state <= RAY_C4;
					end if;

				when RAY_C4 =>
					dd_go <= '1';
					ray_state <= RAY_C5;

				when RAY_C5 =>
					-- dd_go reaches the dividers one clock after RAY_C4, so busy is
					-- still low in the first cycle here
					if ((ddx_busy = '0') and (dd_go = '0')) then
						ddx <= unsigned(ddx_q);
						ddy <= unsigned(ddy_q);
						mul_a <= signed(resize(unsigned(ddx_q), 33));
						mul_b <= signed(resize(frac_x, 25));
						mul_go <= '1';
						ray_state <= RAY_C6;
					end if;

				when RAY_C6 =>
					if (mul_v = '1') then
						sdx <= unsigned(mul_p(47 downto 16)); -- Q8.16 * Q.16 >> 16 = Q16.16
						mul_a <= signed(resize(ddy, 33));
						mul_b <= signed(resize(frac_y, 25));
						mul_go <= '1';
						ray_state <= RAY_C7;
					end if;

				when RAY_C7 =>
					if (mul_v = '1') then
						sdy <= unsigned(mul_p(47 downto 16));
						mx <= pos_x(21 downto 16);
						my <= pos_y(21 downto 16);
						steps <= 0;
						denter <= (others => '0');
						light <= c_light;
						cur_f <= c_f;
						cur_c <= c_c;
						ramp <= c_ramp;
						axis <= c_axis;
						rpos <= c_pos;
						base <= c_base;
						diff <= c_diff;
						wtop <= to_signed(0, 16);
						wbot <= to_signed(SCREEN_H - 1, 16);
						nclip <= (others => '0');
						-- The camera cell is the first seen cell
						seen_we <= '1';
						seen_addr <= std_logic_vector(pos_y(21 downto 16) & pos_x(21 downto 16));
						ray_state <= RAY_STEP;
					end if;

				------------------------------------------------------------
				-- DDA
				------------------------------------------------------------
				when RAY_STEP =>
					-- The ramp axis's sideDist before this step reaches the far
					-- edge of the tile being left; its near edge is dd before it
					if (axis = '0') then
						near <= signed(resize(sdx, 34)) - signed(resize(ddx, 34));
						acc <= resize(ddx, 27);
						if (rx < 0) then
							mv <= '0';
						else
							mv <= '1';
						end if;
					else
						near <= signed(resize(sdy, 34)) - signed(resize(ddy, 34));
						acc <= resize(ddy, 27);
						if (ry < 0) then
							mv <= '0';
						else
							mv <= '1';
						end if;
					end if;
					k <= to_unsigned(1, 3);
					-- Equal side distances step in y (tie-break of the model)
					if (step_x) then
						sdx <= sdx + ddx;
						dnext <= sdx;
						if (rx < 0) then
							mx <= mx - 1;
						else
							mx <= mx + 1;
						end if;
						side <= '0';
					else
						sdy <= sdy + ddy;
						dnext <= sdy;
						if (ry < 0) then
							my <= my - 1;
						else
							my <= my + 1;
						end if;
						side <= '1';
					end if;
					ray_state <= RAY_CHECK;

				when RAY_CHECK =>
					ntile <= map_data_i;
					if (ramp = '1') then
						ray_state <= RAY_RK;
					else
						ray_state <= RAY_TILE;
					end if;

				when RAY_RK =>
					-- Sub-edge k of the ramp being left, if it lies between where
					-- the tile was entered and where the walk leaves it
					if ((rk_d <= signed(resize(denter, 34))) or (rk_d >= signed(resize(dnext, 34)))) then
						if (k = 7) then
							ray_state <= RAY_TILE;
						else
							k <= k + 1;
							if (axis = '1') then
								acc <= acc + resize(ddy, 27);
							else
								acc <= acc + resize(ddx, 27);
							end if;
						end if;
					else
						-- Floor behind the sub-edge: step k (moving +) or 7 - k
						if (mv = '1') then
							ev_fn <= step_height(base, diff, rpos, k);
						else
							ev_fn <= step_height(base, diff, rpos, 7 - k);
						end if;
						ev_d <= clamp_d(unsigned(rk_d(31 downto 0)));
						ev_side <= axis;
						ev_cn <= cur_c;
						ev_tex <= std_logic_vector(to_unsigned(RISER_TEX, 4));
						ev_given <= '0';
						ev_final <= '0';
						ev_ramp <= '1';
						ray_state <= RAY_E0;
					end if;

				when RAY_TILE =>
					steps <= steps + 1;
					seen_we <= '1';
					seen_addr <= std_logic_vector(my & mx);
					ev_d <= clamp_d(dnext);
					ev_side <= side;
					ev_tex <= ntile(3 downto 0);
					ev_given <= '0';
					ev_ramp <= '0';
					-- A textured tile is solid unless it is a door (special 1..3) on the axis just crossed (bit 23)
					if ((steps + 1 >= MAX_STEPS) or ((ntile(3 downto 0) /= "0000") and
						not ((ntile(16 downto 14) /= "000") and (ntile(16) = '0') and (ntile(23) = side)))) then
						-- Solid wall (or the DDA gave up)
						ev_final <= '1';
						ray_state <= RAY_E0;
					elsif (ntile(3 downto 0) /= "0000") then
						-- Specials 1, 2, 3 on their axis: multiply door distance * ray
						dmid <= door_mid;
						mul_a <= signed(resize(door_mid, 33));
						if (side = '0') then
							mul_b <= resize(ry, 25);
						else
							mul_b <= resize(rx, 25);
						end if;
						mul_go <= '1';
						ray_state <= RAY_DOOR;
					elsif (nt_ramp = '1') then
						ray_state <= RAY_RN0;
					else
						n_ramp <= '0';
						n_f <= nt_floor;
						n_c <= nt_ceil;
						ray_state <= RAY_OPEN;
					end if;

				when RAY_DOOR =>
					if (mul_v = '1') then
						-- Hit: the ray reaches the door plane before leaving the cell sideways, past the open part
						if (((side = '0') and (dmid < sdy)) or ((side = '1') and (dmid < sdx))) and
							(door_frac >= door_open) then
							tex_col <= door_col(15 downto 10);
							ev_given <= '1';
							ev_d <= clamp_d(dmid);
							ev_final <= '1';
							ray_state <= RAY_E0;
						else
							-- Through the open part: the door cell is an open tile
							n_ramp <= '0';
							n_f <= nt_floor;
							n_c <= nt_ceil;
							ray_state <= RAY_OPEN;
						end if;
					end if;

				when RAY_RN0 =>
					-- Map read of the tile this ramp rises to (address mux)
					ray_state <= RAY_RN1;

				when RAY_RN1 =>
					n_ramp <= '1';
					n_axis <= ntile(7);
					n_pos <= not ntile(6);
					n_base <= nt_floor;
					n_diff <= nb_diff;
					n_c <= nt_ceil;
					if (ntile(7) = side) then
						-- Entered across the ramp axis: the step at that face
						if (((ntile(7) = '0') and (rx >= 0)) or ((ntile(7) = '1') and (ry >= 0))) then
							n_f <= step_height(nt_floor, nb_diff, not ntile(6), to_unsigned(0, 3));
						else
							n_f <= step_height(nt_floor, nb_diff, not ntile(6), to_unsigned(7, 3));
						end if;
						ray_state <= RAY_OPEN;
					else
						-- Entered from a side: the step under the entry point
						mul_a <= signed(resize(dnext, 33));
						if (ntile(7) = '0') then
							mul_b <= resize(rx, 25);
						else
							mul_b <= resize(ry, 25);
						end if;
						mul_go <= '1';
						ray_state <= RAY_RN2;
					end if;

				when RAY_RN2 =>
					if (mul_v = '1') then
						if (n_axis = '0') then
							n_f <= step_height(n_base, n_diff, n_pos, along_x(15 downto 13));
						else
							n_f <= step_height(n_base, n_diff, n_pos, along_y(15 downto 13));
						end if;
						ray_state <= RAY_OPEN;
					end if;

				when RAY_OPEN =>
					if ((n_f /= cur_f) or (n_c /= cur_c)) then
						ev_fn <= n_f;
						ev_cn <= n_c;
						ev_tex <= std_logic_vector(to_unsigned(RISER_TEX, 4));
						ev_final <= '0';
						ray_state <= RAY_E0;
					else
						-- Same heights: just walk on
						light <= nt_light;
						ramp <= n_ramp;
						axis <= n_axis;
						rpos <= n_pos;
						base <= n_base;
						diff <= n_diff;
						denter <= dnext;
						ray_state <= RAY_STEP;
					end if;

				------------------------------------------------------------
				-- Event: height edge (ev_final = 0) or wall (ev_final = 1)
				------------------------------------------------------------
				when RAY_E0 =>
					lh_go <= '1';
					mul_a <= signed(resize(ev_d, 33));
					if (ev_side = '0') then
						mul_b <= resize(ry, 25);
					else
						mul_b <= resize(rx, 25);
					end if;
					mul_go <= '1';
					ray_state <= RAY_E1;

				when RAY_E1 =>
					if (mul_v = '1') then
						if (ev_given = '0') then
							-- Texture column, mirrored on +x-going x faces and
							-- -y-going y faces
							if (((ev_side = '0') and (rx > 0)) or ((ev_side = '1') and (ry < 0))) then
								tex_col <= 63 - hit_col;
							else
								tex_col <= hit_col;
							end if;
						end if;
						mul_a <= signed(resize(ev_d, 33));
						mul_b <= to_signed(M_TS, 25);
						mul_go <= '1';
						ray_state <= RAY_E2;
					end if;

				when RAY_E2 =>
					if (mul_v = '1') then
						tex_step <= unsigned(mul_p(39 downto 16));
						ray_state <= RAY_E3;
					end if;

				when RAY_E3 =>
					-- The lineHeight divide started in RAY_E0 and is busy by now
					if ((lh_busy = '0') and (lh_go = '0')) then
						if (unsigned(lh_q) > LH_MAX) then
							lh <= to_unsigned(LH_MAX, 20);
						else
							lh <= unsigned(lh_q(19 downto 0));
						end if;
						ray_state <= RAY_E4;
					end if;

				when RAY_E4 =>
					-- The row products of lh are registered at this edge
					ray_state <= RAY_E5;

				when RAY_E5 =>
					rf <= row_of(prod_f);
					rc <= row_of(prod_c);
					rt <= row_of(prod_fn);
					rb <= row_of(prod_cn);
					top_f <= resize(to_signed(HORIZON * 256, 29) + shift_right(prod_64, 6), 28);
					e_floor <= unsigned(resize(eye - signed(resize(cur_f, 9)), 7));
					e_ceil <= unsigned(resize(signed(resize(cur_c, 9)) - eye, 7));
					ray_state <= RAY_E6;

				when RAY_E6 =>
					-- Floor span: rows max(rf, wtop) .. wbot, then wbot = rf - 1
					-- (one window rule per clock keeps each compare chain short)
					if ((rf <= wbot) and (wtop <= wbot)) then
						sv <= "0001";
						sy0(0) <= to_integer(unsigned(floor_top(7 downto 0)));
						sy1(0) <= to_integer(unsigned(wbot(7 downto 0)));
					else
						sv <= "0000";
					end if;
					wbot <= smin(wbot, rf - 1);
					ray_state <= RAY_E6B;

				when RAY_E6B =>
					-- Ceiling span: rows wtop .. min(rc - 1, wbot), then wtop = rc
					if ((wtop <= rc - 1) and (wtop <= wbot)) then
						sv(1) <= '1';
						sy0(1) <= to_integer(unsigned(wtop(7 downto 0)));
						sy1(1) <= to_integer(unsigned(ceil_bot(7 downto 0)));
					end if;
					wtop <= smax(wtop, rc);
					ray_state <= RAY_E7;

				when RAY_E7 =>
					if (ev_final = '1') then
						-- The wall fills the rest of the window
						if (wtop <= wbot) then
							sv(2) <= '1';
							sy0(2) <= to_integer(unsigned(wtop(7 downto 0)));
							sy1(2) <= to_integer(unsigned(wbot(7 downto 0)));
						end if;
					elsif (ev_fn > cur_f) then
						-- Riser where the floor steps up
						if ((rt <= wbot) and (wtop <= wbot)) then
							sv(2) <= '1';
							sy0(2) <= to_integer(unsigned(riser_top(7 downto 0)));
							sy1(2) <= to_integer(unsigned(wbot(7 downto 0)));
						end if;
						wbot <= smin(wbot, rt - 1);
					end if;
					ray_state <= RAY_E8;

				when RAY_E8 =>
					if (ev_final = '1') then
						closed <= '1';
					else
						-- Upper wall where the ceiling steps down; the window
						-- top then moves to upper_top
						if ((ev_cn < cur_c) and (wtop <= rb - 1) and (wtop <= wbot)) then
							sv(3) <= '1';
							sy0(3) <= to_integer(unsigned(wtop(7 downto 0)));
							sy1(3) <= to_integer(unsigned(upper_bot(7 downto 0)));
						end if;
						wtop <= upper_top;
						-- Clip entry: the window behind this edge; 16 at most,
						-- then the last one is rewritten
						if (upper_top > wbot) then
							closed <= '1';
							clip_data <= x"00" & x"01" & std_logic_vector(z_sat); -- Bottom 0, top 1: closed
						else
							closed <= '0';
							clip_data <= std_logic_vector(wbot(7 downto 0)) & std_logic_vector(upper_top(7 downto 0)) &
								std_logic_vector(z_sat);
						end if;
						if (nclip = CLIP_MAX) then
							clip_addr <= col & to_unsigned(CLIP_MAX - 1, 4);
						else
							clip_addr <= col & nclip(3 downto 0);
							nclip <= nclip + 1;
						end if;
						clip_we <= '1';
					end if;
					zval <= z_sat;
					slot <= "00";
					ray_state <= RAY_X0;

				------------------------------------------------------------
				-- Span output, model order: floor, ceiling, riser or wall,
				-- upper wall
				------------------------------------------------------------
				when RAY_X0 =>
					-- The last span of a closing event carries DESC_LAST
					if (sv(3) = '1') then
						last <= "11";
					elsif (sv(2) = '1') then
						last <= "10";
					elsif (sv(1) = '1') then
						last <= "01";
					else
						last <= "00";
					end if;
					if (sv(to_integer(slot)) = '0') then
						if (slot = 3) then
							ray_state <= RAY_EVEND;
						else
							slot <= slot + 1;
						end if;
					elsif (slot(1) = '1') then
						-- Textured: v0 = (y0 * 256 + 128 - top) * tex_step >> 8
						mul_a <= resize(v0_off, 33);
						mul_b <= signed(resize(tex_step, 25));
						mul_go <= '1';
						ray_state <= RAY_X1;
					else
						ray_state <= RAY_X1;
					end if;

				when RAY_X1 =>
					if ((slot(1) = '0') or (mul_v = '1')) then
						desc <= span_desc;
						desc_valid <= '1';
						ray_state <= RAY_X2;
					end if;

				when RAY_X2 =>
					if (desc_ready_i = '1') then
						desc_valid <= '0';
						if (slot = 3) then
							ray_state <= RAY_EVEND;
						else
							slot <= slot + 1;
							ray_state <= RAY_X0;
						end if;
					end if;

				when RAY_EVEND =>
					if (closed = '1') then
						ray_state <= RAY_COLEND;
					elsif (ev_ramp = '1') then
						-- Next sub-edge of the ramp, from the new step's floor
						cur_f <= ev_fn;
						if (k = 7) then
							ray_state <= RAY_TILE;
						else
							k <= k + 1;
							if (axis = '0') then
								acc <= acc + resize(ddx, 27);
							else
								acc <= acc + resize(ddy, 27);
							end if;
							ray_state <= RAY_RK;
						end if;
					else
						-- Tile edge passed: the walk is in the new tile
						cur_f <= ev_fn;
						cur_c <= ev_cn;
						light <= nt_light;
						ramp <= n_ramp;
						axis <= n_axis;
						rpos <= n_pos;
						base <= n_base;
						diff <= n_diff;
						denter <= dnext;
						ray_state <= RAY_STEP;
					end if;

				when RAY_COLEND =>
					if (col = SCREEN_W - 1) then
						done <= '1';
						ray_state <= RAY_IDLE;
					else
						col <= col + 1;
						ray_state <= RAY_C0;
					end if;

				when others =>
					null;
			end case;
		end if;
	end process;

	------------------------------------------------------------------
	-- Outputs
	------------------------------------------------------------------
	desc_o <= desc;
	desc_valid_o <= desc_valid;
	-- z-buffer and clip count once per column, after its last span
	zbuf_we_o <= '1' when (ray_state = RAY_COLEND) else '0';
	zbuf_addr_o <= std_logic_vector(col);
	zbuf_data_o <= std_logic_vector(zval);
	ccount_we_o <= '1' when (ray_state = RAY_COLEND) else '0';
	ccount_addr_o <= std_logic_vector(col);
	ccount_data_o <= std_logic_vector(nclip);
	clip_we_o <= clip_we;
	clip_addr_o <= std_logic_vector(clip_addr);
	clip_data_o <= clip_data;
	seen_we_o <= seen_we;
	seen_addr_o <= seen_addr;
	busy_o <= '0' when (ray_state = RAY_IDLE) else '1';
	done_o <= done;
end arch;

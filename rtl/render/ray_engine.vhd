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
-- Description:    Stage-4 ray engine: for screen columns 0..319 casts one
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
--                 Per frame (S_F*): sin, cos, plane; the camera's tile (and,
--                 on a ramp, the tile its ramp rises to) gives the starting
--                 light, floor F and ceiling C of every column.
--                 Per column (S_C*): ray, deltaDist (two dividers), sideDist.
--                 DDA (S_STEP, S_CHECK, S_TILE: 3 clocks per cell; equal
--                 side distances step in y). A ramp tile being left first
--                 runs its 7 sub-edges (S_RK) at (sd - dd) + ((k * dd) >> 3).
--                 A new open tile whose floor or ceiling differs (S_OPEN; a
--                 ramp needs its neighbor tile, S_RN*) is a height edge; a
--                 wall, a closed door or the 128th cell ends the column.
--                 Height edge and wall (one "event", S_E* then S_X*):
--                   S_E0..S_E3  lineHeight = N_LH / d (32-bit divisor) while
--                               the shared multiplier gives the texture
--                               column and tex_step
--                   S_E4, S_E5  five rows at once: row(h) =
--                               ((30720 + ((lh * (eye - h)) >> 6)) + 127) >> 8
--                               for F, C, Fn, Cn and 64 (texture anchor),
--                               on five small dedicated multipliers
--                   S_E6..S_E8  the window rules, one per clock: floor span,
--                               ceiling span, then riser and upper wall
--                               (edge) or the wall (final); clip entry
--                               (z, top, bottom), a
--                               closed window as (z, 1, 0); up to 16 per
--                               column, then the last one is rewritten
--                   S_X*        the up-to-four spans go out in model order;
--                               a textured span first gets v0 =
--                               ((y0 * 256 + 128 - top) * tex_step) >> 8
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
-- Revision 2.00 - Stage 4: floor and ceiling heights, ramps, span
--                 descriptors, clip entries
-- Revision 2.10 - Stage 4 light effects: every tile light is offset by fx_i's
--                 lmod of its light type (tile bits 13:12) and clamped to
--                 0..15 before distance and side; door-table lookup
--                 registered (timing)
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

	type state_t is (
		S_IDLE,
		S_F0, -- sin ROM at angle, map read of the camera cell
		S_F1, -- sin(a); camera tile; read the tile its ramp rises to
		S_F2, -- cos(a); ramp neighbor; camera heights; multiply -sin * PLANE_Q
		S_F3, -- plane x; multiply cos * PLANE_Q
		S_F4, -- plane y
		S_C0, -- camera x ROM read
		S_C1, -- multiply plane x * cam
		S_C2, -- ray x; multiply plane y * cam
		S_C3, -- ray y
		S_C4, -- start the deltaDist dividers
		S_C5, -- wait for them; multiply x fraction * deltaDist x
		S_C6, -- sideDist x; multiply y fraction * deltaDist y
		S_C7, -- sideDist y; column state from the camera tile
		S_STEP, -- one DDA step, map read of the new cell
		S_CHECK, -- new cell's tile arrives
		S_RK, -- sub-edge k of the ramp tile being left
		S_TILE, -- the new cell: wall, door or open
		S_DOOR, -- door: hit coordinate on the door plane
		S_RN0, -- open ramp tile: read the tile it rises to
		S_RN1, -- its floor; entry step from the face or ...
		S_RN2, -- ... from the hit position (multiply)
		S_OPEN, -- heights of the new tile: edge or not
		S_E0, -- event: start lineHeight; multiply d * ray (texture column)
		S_E1, -- texture column; multiply d * M_TS
		S_E2, -- tex_step
		S_E3, -- lineHeight
		S_E4, -- row products
		S_E5, -- rows
		S_E6, -- floor span
		S_E6B, -- ceiling span
		S_E7, -- riser, or the wall
		S_E8, -- upper wall; clip entry
		S_X0, -- next span to send; textured: multiply for v0
		S_X1, -- v0
		S_X2, -- descriptor out
		S_EVEND, -- event finished: back to the walk or end the column
		S_COLEND -- z-buffer and clip count, next column
	);

	subtype row_t is signed(15 downto 0); -- Screen row, far outside 0..239 allowed
	-- Span rows as naturals: an array of unsigned would make every "unsigned & unsigned"
	-- in this unit ambiguous
	type rows4_t is array (0 to 3) of natural range 0 to 255;

	type regs_t is record
		state: state_t;
		col: unsigned(8 downto 0);
		sn: signed(17 downto 0); -- sin(angle), Q2.16
		cs: signed(17 downto 0); -- cos(angle)
		plx: signed(17 downto 0); -- Camera plane
		ply: signed(17 downto 0);
		cam: signed(17 downto 0);
		rx: signed(17 downto 0); -- Ray direction, Q2.16
		ry: signed(17 downto 0);
		ddx: unsigned(23 downto 0); -- deltaDist, Q8.16
		ddy: unsigned(23 downto 0);
		sdx: unsigned(31 downto 0); -- sideDist, Q16.16
		sdy: unsigned(31 downto 0);
		mx: unsigned(5 downto 0); -- Map cell
		my: unsigned(5 downto 0);
		side: std_logic; -- Face of the last step: 0 x, 1 y
		steps: natural range 0 to MAX_STEPS;
		dnext: unsigned(31 downto 0); -- Distance at which the last step entered its cell
		denter: unsigned(31 downto 0); -- Distance at which the current tile was entered
		ntile: std_logic_vector(23 downto 0); -- Tile of the cell just entered
		-- Camera tile (per frame)
		c_light: unsigned(3 downto 0);
		c_f: unsigned(6 downto 0);
		c_c: unsigned(6 downto 0);
		c_ramp: std_logic;
		c_axis: std_logic;
		c_pos: std_logic;
		c_base: unsigned(6 downto 0);
		c_diff: signed(3 downto 0);
		-- Walk state of the current tile
		light: unsigned(3 downto 0); -- Light in front of the next boundary
		f: unsigned(6 downto 0); -- Current floor and ceiling heights
		c: unsigned(6 downto 0);
		ramp: std_logic; -- The current tile is a ramp ...
		axis: std_logic; -- ... along x (0) or y (1), ...
		rpos: std_logic; -- ... rising toward + (step j = q) or - (j = 7 - q), ...
		base: unsigned(6 downto 0); -- ... from its floor ...
		diff: signed(3 downto 0); -- ... by diff units per step
		-- Tile being entered (applied when the walk moves on)
		n_ramp: std_logic;
		n_axis: std_logic;
		n_pos: std_logic;
		n_base: unsigned(6 downto 0);
		n_diff: signed(3 downto 0);
		n_f: unsigned(6 downto 0);
		n_c: unsigned(6 downto 0);
		-- Ramp sub-edges
		near: signed(33 downto 0); -- Distance of the tile's near edge on the ramp axis
		acc: unsigned(26 downto 0); -- k * deltaDist
		k: unsigned(2 downto 0);
		mv: std_logic; -- Moving toward + on the ramp axis
		-- Door
		dmid: unsigned(31 downto 0);
		-- Event (height edge or wall)
		ev_final: std_logic; -- Wall: the column ends here
		ev_ramp: std_logic; -- Sub-edge of a ramp (else an open tile edge)
		ev_d: unsigned(31 downto 0); -- Distance, PERP_MIN applied
		ev_side: std_logic;
		ev_fn: unsigned(6 downto 0); -- Heights behind the edge
		ev_cn: unsigned(6 downto 0);
		ev_tex: std_logic_vector(3 downto 0);
		ev_given: std_logic; -- Texture column already known (door)
		tex_col: unsigned(5 downto 0);
		tex_step: unsigned(23 downto 0);
		lh: unsigned(19 downto 0); -- lineHeight, Q12.8
		rf: row_t; -- First row at or below F, C, Fn, Cn
		rc: row_t;
		rt: row_t;
		rb: row_t;
		top_f: signed(27 downto 0); -- Q.8 row of height 64 (texture anchor)
		wtop: row_t; -- Open window
		wbot: row_t;
		sv: std_logic_vector(3 downto 0); -- Spans: 0 floor, 1 ceiling, 2 riser
		sy0: rows4_t; -- or wall, 3 upper wall
		sy1: rows4_t;
		e_floor: unsigned(6 downto 0);
		e_ceil: unsigned(6 downto 0);
		closed: std_logic; -- The event ends the column
		last: unsigned(1 downto 0); -- Last span of the column (when closed)
		slot: unsigned(1 downto 0);
		nclip: unsigned(4 downto 0);
		zval: unsigned(15 downto 0);
		clip_we: std_logic;
		clip_addr: unsigned(12 downto 0);
		clip_data: std_logic_vector(CLIP_BITS - 1 downto 0);
		seen_we: std_logic;
		seen_addr: std_logic_vector(11 downto 0);
		desc: std_logic_vector(DESC_BITS - 1 downto 0);
		desc_valid: std_logic;
		mul_a: signed(32 downto 0); -- Multiplier operands
		mul_b: signed(24 downto 0);
		mul_go: std_logic;
		dd_go: std_logic;
		lh_go: std_logic;
		done: std_logic;
	end record;

	constant REGS_INIT: regs_t := (
		state => S_IDLE,
		col => (others => '0'),
		sn => (others => '0'),
		cs => (others => '0'),
		plx => (others => '0'),
		ply => (others => '0'),
		cam => (others => '0'),
		rx => (others => '0'),
		ry => (others => '0'),
		ddx => (others => '0'),
		ddy => (others => '0'),
		sdx => (others => '0'),
		sdy => (others => '0'),
		mx => (others => '0'),
		my => (others => '0'),
		side => '0',
		steps => 0,
		dnext => (others => '0'),
		denter => (others => '0'),
		ntile => (others => '0'),
		c_light => (others => '0'),
		c_f => (others => '0'),
		c_c => (others => '0'),
		c_ramp => '0',
		c_axis => '0',
		c_pos => '0',
		c_base => (others => '0'),
		c_diff => (others => '0'),
		light => (others => '0'),
		f => (others => '0'),
		c => (others => '0'),
		ramp => '0',
		axis => '0',
		rpos => '0',
		base => (others => '0'),
		diff => (others => '0'),
		n_ramp => '0',
		n_axis => '0',
		n_pos => '0',
		n_base => (others => '0'),
		n_diff => (others => '0'),
		n_f => (others => '0'),
		n_c => (others => '0'),
		near => (others => '0'),
		acc => (others => '0'),
		k => (others => '0'),
		mv => '0',
		dmid => (others => '0'),
		ev_final => '0',
		ev_ramp => '0',
		ev_d => (others => '0'),
		ev_side => '0',
		ev_fn => (others => '0'),
		ev_cn => (others => '0'),
		ev_tex => (others => '0'),
		ev_given => '0',
		tex_col => (others => '0'),
		tex_step => (others => '0'),
		lh => (others => '0'),
		rf => (others => '0'),
		rc => (others => '0'),
		rt => (others => '0'),
		rb => (others => '0'),
		top_f => (others => '0'),
		wtop => (others => '0'),
		wbot => (others => '0'),
		sv => (others => '0'),
		sy0 => (others => 0),
		sy1 => (others => 0),
		e_floor => (others => '0'),
		e_ceil => (others => '0'),
		closed => '0',
		last => (others => '0'),
		slot => (others => '0'),
		nclip => (others => '0'),
		zval => (others => '0'),
		clip_we => '0',
		clip_addr => (others => '0'),
		clip_data => (others => '0'),
		seen_we => '0',
		seen_addr => (others => '0'),
		desc => (others => '0'),
		desc_valid => '0',
		mul_a => (others => '0'),
		mul_b => (others => '0'),
		mul_go => '0',
		dd_go => '0',
		lh_go => '0',
		done => '0'
	);

	signal r: regs_t := REGS_INIT;
	signal r_next: regs_t;

	-- Shared multiplier pipeline: r.mul_a/b -> mul_p1 -> mul_p
	signal mul_p1: signed(57 downto 0) := (others => '0');
	signal mul_p: signed(57 downto 0) := (others => '0');
	signal mul_v1: std_logic := '0';
	signal mul_v: std_logic := '0';

	-- Row products lh * (eye - h), registered (S_E4 -> S_E5)
	signal prod_f, prod_c, prod_fn, prod_cn, prod_64: signed(28 downto 0) := (others => '0');

	-- ROMs (registered outputs)
	signal sin_addr: unsigned(9 downto 0);
	signal sin_data: signed(17 downto 0) := (others => '0');
	signal camx_data: signed(17 downto 0) := (others => '0');

	-- Dividers
	constant TWO_32: std_logic_vector(32 downto 0) := '1' & (31 downto 0 => '0');
	signal ddx_den: std_logic_vector(23 downto 0);
	signal ddy_den: std_logic_vector(23 downto 0);
	signal ddx_busy, ddy_busy, lh_busy: std_logic;
	signal ddx_q, ddy_q, lh_q: std_logic_vector(23 downto 0);

	-- Frame inputs as numbers
	signal pos_x: unsigned(21 downto 0);
	signal pos_y: unsigned(21 downto 0);
	signal eye: signed(8 downto 0);

	-- Door table lookup for the current cell: open amount << 10, registered (door_hit is
	-- the compare of this clock; S_DOOR reads door_open at least two clocks after S_STEP
	-- moved the cell, so the register always holds the current cell's entry)
	signal door_hit: unsigned(16 downto 0);
	signal door_open: unsigned(16 downto 0) := (others => '0');
	signal map_addr: std_logic_vector(11 downto 0);
	signal step_x: boolean;

	-- Tile light after the light type's offset: clamp(light + lmod(type), 0, 15), lmod
	-- signed 5-bit at fx(5k + 4 .. 5k) for light type k = t(13:12)
	function tile_light(t: std_logic_vector(23 downto 0); fx: std_logic_vector(FX_BITS - 1 downto 0))
		return unsigned is
		variable k: natural range 0 to 3;
		variable l: signed(6 downto 0);
	begin
		k := to_integer(unsigned(t(13 downto 12)));
		l := signed(resize(unsigned(t(11 downto 8)), 7)) +
			resize(signed(fx(FX_LMOD_W * k + FX_LMOD_W - 1 downto FX_LMOD_W * k)), 7);
		if (l < 0) then
			return to_unsigned(0, 4);
		elsif (l > 15) then
			return to_unsigned(15, 4);
		end if;
		return unsigned(l(3 downto 0));
	end function;

	-- floor_h * 8 units
	function floor_height(t: std_logic_vector(23 downto 0)) return unsigned is
	begin
		return resize(unsigned(t(19 downto 17)) & "000", 7);
	end function;

	-- 64 - ceil_h * 8 units
	function ceil_height(t: std_logic_vector(23 downto 0)) return unsigned is
	begin
		return to_unsigned(64, 7) - (unsigned(t(22 downto 20)) & "000");
	end function;

	function is_ramp(t: std_logic_vector(23 downto 0)) return boolean is
	begin
		return t(16 downto 14) = "111";
	end function;

	-- Cell next to (x, y) in ramp direction dir (0 +x, 1 -x, 2 +y, 3 -y)
	function ramp_neighbor(x, y: unsigned(5 downto 0); dir: std_logic_vector(1 downto 0))
		return std_logic_vector is
		variable nx, ny: unsigned(5 downto 0);
	begin
		nx := x;
		ny := y;
		case dir is
			when "00" =>
				nx := x + 1;
			when "01" =>
				nx := x - 1;
			when "10" =>
				ny := y + 1;
			when others =>
				ny := y - 1;
		end case;
		return std_logic_vector(ny) & std_logic_vector(nx);
	end function;

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

	-- min(d >> 6, 65535)
	function zsat(d: unsigned(31 downto 0)) return unsigned is
	begin
		if (d(31 downto 22) /= 0) then
			return to_unsigned(65535, 16);
		end if;
		return d(21 downto 6);
	end function;

	-- clamp(light - min(15, d >> 18) - side)
	function eff_light(l: unsigned(3 downto 0); d: unsigned(31 downto 0); side: std_logic)
		return unsigned is
		variable dl: unsigned(3 downto 0);
		variable le: signed(5 downto 0);
	begin
		if (d(31 downto 22) /= 0) then
			dl := to_unsigned(15, 4);
		else
			dl := d(21 downto 18);
		end if;
		le := signed(resize(l, 6)) - signed(resize(dl, 6));
		if (side = '1') then
			le := le - 1;
		end if;
		if (le < 0) then
			le := (others => '0');
		end if;
		return unsigned(le(3 downto 0));
	end function;

	-- First row at or below Q.8 coordinate 30720 + (p >> 6): (yq + 127) >> 8
	function row_of(p: signed(28 downto 0)) return signed is
		variable yq: signed(28 downto 0);
	begin
		yq := to_signed(HORIZON * 256 + 127, 29) + shift_right(p, 6);
		return resize(shift_right(yq, 8), 16);
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
			camx_data <= to_signed(CAMX_TABLE(to_integer(r.col)), 18);
		end if;
	end process;

	-- S_F1 reads cos = sin(angle + 1/4 turn), every other state sin
	sin_addr <= unsigned(angle_i) + 256 when (r.state = S_F1) else unsigned(angle_i);

	-- First matching entry of the door table (an unused entry has open 0)
	process(doors_i, r.mx, r.my)
		variable e: std_logic_vector(DOOR_BITS - 1 downto 0);
		variable found: boolean;
	begin
		door_hit <= (others => '0');
		found := false;
		for k in 0 to 7 loop
			e := doors_i(DOOR_BITS * k + DOOR_BITS - 1 downto DOOR_BITS * k);
			if ((not found) and (unsigned(e(DOOR_X_HI downto DOOR_X_LO)) = r.mx) and
				(unsigned(e(DOOR_Y_HI downto DOOR_Y_LO)) = r.my)) then
				door_hit <= unsigned(e(DOOR_OPEN_HI downto DOOR_OPEN_LO)) & "0000000000";
				found := true;
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
			mul_p1 <= r.mul_a * r.mul_b;
			mul_p <= mul_p1;
		end if;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			mul_v1 <= '0';
			mul_v <= '0';
		elsif rising_edge(clk_i) then
			mul_v1 <= r.mul_go;
			mul_v <= mul_v1;
		end if;
	end process;

	------------------------------------------------------------------
	-- Row products lh * (eye - h) for F, C, Fn, Cn and 64: five small
	-- multipliers (21 x 9 bits) side by side, so an edge's rows take one
	-- clock instead of five trips through the shared multiplier
	------------------------------------------------------------------
	process(clk_i)
		variable lhs: signed(20 downto 0);
	begin
		if rising_edge(clk_i) then
			lhs := signed('0' & r.lh);
			prod_f <= resize(lhs * (eye - signed(resize(r.f, 9))), 29);
			prod_c <= resize(lhs * (eye - signed(resize(r.c, 9))), 29);
			prod_fn <= resize(lhs * (eye - signed(resize(r.ev_fn, 9))), 29);
			prod_cn <= resize(lhs * (eye - signed(resize(r.ev_cn, 9))), 29);
			prod_64 <= resize(lhs * (eye - to_signed(64, 9)), 29);
		end if;
	end process;

	------------------------------------------------------------------
	-- Dividers: deltaDist x, deltaDist y (2^32 / |ray|), lineHeight
	------------------------------------------------------------------
	-- Resize to 19 bits before abs: |-2^17| does not fit in 18
	ddx_den <= std_logic_vector(resize(unsigned(abs(resize(r.rx, 19))), 24));
	ddy_den <= std_logic_vector(resize(unsigned(abs(resize(r.ry, 19))), 24));

	div_ddx: divider
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			start_i => r.dd_go,
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
			start_i => r.dd_go,
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
			start_i => r.lh_go,
			num_i => std_logic_vector('0' & N_LH),
			den_i => std_logic_vector(r.ev_d),
			busy_o => lh_busy,
			done_o => open,
			quo_o => lh_q
		);

	------------------------------------------------------------------
	-- DDA step decision and the map address
	------------------------------------------------------------------
	step_x <= (r.sdx < r.sdy);

	process(r, step_x, pos_x, pos_y, map_data_i)
	begin
		case r.state is
			when S_F0 =>
				map_addr <= std_logic_vector(pos_y(21 downto 16) & pos_x(21 downto 16));
			when S_F1 =>
				-- The tile the camera's ramp rises to (any cell if not a ramp)
				map_addr <= ramp_neighbor(pos_x(21 downto 16), pos_y(21 downto 16), map_data_i(7 downto 6));
			when S_RN0 =>
				map_addr <= ramp_neighbor(r.mx, r.my, r.ntile(7 downto 6));
			when others =>
				-- The cell entered by this step (S_STEP)
				if (step_x) then
					if (r.rx < 0) then
						map_addr <= std_logic_vector(r.my & (r.mx - 1));
					else
						map_addr <= std_logic_vector(r.my & (r.mx + 1));
					end if;
				else
					if (r.ry < 0) then
						map_addr <= std_logic_vector((r.my - 1) & r.mx);
					else
						map_addr <= std_logic_vector((r.my + 1) & r.mx);
					end if;
				end if;
		end case;
	end process;

	map_addr_o <= map_addr;

	------------------------------------------------------------------
	-- Next state
	------------------------------------------------------------------
	process(r, start_i, pos_x, pos_y, eye, sin_data, camx_data, map_data_i, mul_v, mul_p, prod_f, prod_c, prod_fn, prod_cn, prod_64,
		ddx_busy, ddx_q, ddy_q, lh_busy, lh_q, desc_ready_i, step_x, door_open, fx_i)
		variable v: regs_t;
		variable fx: unsigned(16 downto 0);
		variable t: std_logic_vector(23 downto 0);
		variable pos_lo: unsigned(15 downto 0);
		variable along: unsigned(15 downto 0);
		variable frac: unsigned(16 downto 0);
		variable col_bits: unsigned(5 downto 0);
		variable lhq: unsigned(23 downto 0);
		variable dk: signed(33 downto 0);
		variable q: unsigned(2 downto 0);
		variable wt, wb, a, b: row_t;
		variable offset: signed(27 downto 0);
		variable dsc: std_logic_vector(DESC_BITS - 1 downto 0);
		variable idx: unsigned(3 downto 0);
	begin
		v := r;
		v.mul_go := '0';
		v.dd_go := '0';
		v.lh_go := '0';
		v.done := '0';
		v.clip_we := '0';
		v.seen_we := '0';

		case r.state is
			when S_IDLE =>
				if (start_i = '1') then
					v.col := (others => '0');
					v.state := S_F0;
				end if;

			------------------------------------------------------------
			-- Frame setup: trig, camera tile, plane
			------------------------------------------------------------
			when S_F0 =>
				v.state := S_F1;

			when S_F1 =>
				v.sn := sin_data;
				t := map_data_i;
				v.ntile := t;
				v.c_light := tile_light(t, fx_i);
				v.c_c := ceil_height(t);
				v.state := S_F2;

			when S_F2 =>
				v.cs := sin_data;
				-- Camera tile heights: a ramp's step under the camera
				t := r.ntile;
				if (is_ramp(t)) then
					-- A ramp's ceil_tex is its direction: bit 7 the axis (0 x, 1 y), bit 6 set = toward -
					v.c_ramp := '1';
					v.c_axis := t(7);
					v.c_pos := not t(6);
					v.c_base := floor_height(t);
					-- Rise per step: neighbor floor_h - own floor_h (one level = 8 units over 8 steps)
					v.c_diff := signed('0' & map_data_i(19 downto 17)) - signed('0' & t(19 downto 17));
					-- q = the eighth of the tile the camera stands in
					if (t(7) = '0') then
						q := pos_x(15 downto 13);
					else
						q := pos_y(15 downto 13);
					end if;
					v.c_f := step_height(floor_height(t), v.c_diff, not t(6), q);
				else
					v.c_ramp := '0';
					v.c_f := floor_height(t);
				end if;
				v.mul_a := resize(-r.sn, 33);
				v.mul_b := to_signed(PLANE_Q, 25);
				v.mul_go := '1';
				v.state := S_F3;

			when S_F3 =>
				if (mul_v = '1') then
					v.plx := mul_p(33 downto 16); -- (-sin * PLANE_Q) >> 16
					v.mul_a := resize(r.cs, 33);
					v.mul_b := to_signed(PLANE_Q, 25);
					v.mul_go := '1';
					v.state := S_F4;
				end if;

			when S_F4 =>
				if (mul_v = '1') then
					v.ply := mul_p(33 downto 16);
					v.state := S_C0;
				end if;

			------------------------------------------------------------
			-- Ray direction, deltaDist, sideDist
			------------------------------------------------------------
			when S_C0 =>
				v.state := S_C1;

			when S_C1 =>
				v.cam := camx_data;
				v.mul_a := resize(r.plx, 33);
				v.mul_b := resize(camx_data, 25);
				v.mul_go := '1';
				v.state := S_C2;

			when S_C2 =>
				if (mul_v = '1') then
					v.rx := r.cs + mul_p(33 downto 16); -- ray = direction + plane * camera x
					v.mul_a := resize(r.ply, 33);
					v.mul_b := resize(r.cam, 25);
					v.mul_go := '1';
					v.state := S_C3;
				end if;

			when S_C3 =>
				if (mul_v = '1') then
					v.ry := r.sn + mul_p(33 downto 16);
					v.state := S_C4;
				end if;

			when S_C4 =>
				v.dd_go := '1';
				v.state := S_C5;

			when S_C5 =>
				-- dd_go reaches the dividers one clock after S_C4, so busy is
				-- still low in the first cycle here
				if ((ddx_busy = '0') and (r.dd_go = '0')) then
					v.ddx := unsigned(ddx_q);
					v.ddy := unsigned(ddy_q);
					-- sideDist x = fx * ddx >> 16 (ray going -x) or
					-- (65536 - fx) * ddx >> 16 (ray going +x)
					if (r.rx < 0) then
						fx := '0' & pos_x(15 downto 0);
					else
						fx := to_unsigned(65536, 17) - pos_x(15 downto 0);
					end if;
					v.mul_a := signed(resize(unsigned(ddx_q), 33));
					v.mul_b := signed(resize(fx, 25));
					v.mul_go := '1';
					v.state := S_C6;
				end if;

			when S_C6 =>
				if (mul_v = '1') then
					v.sdx := unsigned(mul_p(47 downto 16)); -- Q8.16 * Q.16 >> 16 = Q16.16
					if (r.ry < 0) then
						fx := '0' & pos_y(15 downto 0);
					else
						fx := to_unsigned(65536, 17) - pos_y(15 downto 0);
					end if;
					v.mul_a := signed(resize(r.ddy, 33));
					v.mul_b := signed(resize(fx, 25));
					v.mul_go := '1';
					v.state := S_C7;
				end if;

			when S_C7 =>
				if (mul_v = '1') then
					v.sdy := unsigned(mul_p(47 downto 16));
					v.mx := pos_x(21 downto 16);
					v.my := pos_y(21 downto 16);
					v.steps := 0;
					v.denter := (others => '0');
					v.light := r.c_light;
					v.f := r.c_f;
					v.c := r.c_c;
					v.ramp := r.c_ramp;
					v.axis := r.c_axis;
					v.rpos := r.c_pos;
					v.base := r.c_base;
					v.diff := r.c_diff;
					v.wtop := to_signed(0, 16);
					v.wbot := to_signed(SCREEN_H - 1, 16);
					v.nclip := (others => '0');
					-- The camera cell is the first seen cell
					v.seen_we := '1';
					v.seen_addr := std_logic_vector(pos_y(21 downto 16) & pos_x(21 downto 16));
					v.state := S_STEP;
				end if;

			------------------------------------------------------------
			-- DDA
			------------------------------------------------------------
			when S_STEP =>
				-- The ramp axis's sideDist before this step reaches the far
				-- edge of the tile being left; its near edge is dd before it
				if (r.axis = '0') then
					v.near := signed(resize(r.sdx, 34)) - signed(resize(r.ddx, 34));
					v.acc := resize(r.ddx, 27);
					if (r.rx < 0) then
						v.mv := '0';
					else
						v.mv := '1';
					end if;
				else
					v.near := signed(resize(r.sdy, 34)) - signed(resize(r.ddy, 34));
					v.acc := resize(r.ddy, 27);
					if (r.ry < 0) then
						v.mv := '0';
					else
						v.mv := '1';
					end if;
				end if;
				v.k := to_unsigned(1, 3);
				-- Equal side distances step in y (tie-break of the model)
				if (step_x) then
					v.sdx := r.sdx + r.ddx;
					v.dnext := r.sdx;
					if (r.rx < 0) then
						v.mx := r.mx - 1;
					else
						v.mx := r.mx + 1;
					end if;
					v.side := '0';
				else
					v.sdy := r.sdy + r.ddy;
					v.dnext := r.sdy;
					if (r.ry < 0) then
						v.my := r.my - 1;
					else
						v.my := r.my + 1;
					end if;
					v.side := '1';
				end if;
				v.state := S_CHECK;

			when S_CHECK =>
				v.ntile := map_data_i;
				if (r.ramp = '1') then
					v.state := S_RK;
				else
					v.state := S_TILE;
				end if;

			when S_RK =>
				-- Sub-edge k of the ramp being left, if it lies between where
				-- the tile was entered and where the walk leaves it
				dk := r.near + signed(resize(r.acc(26 downto 3), 34)); -- near + ((k * dd) >> 3)
				if ((dk <= signed(resize(r.denter, 34))) or (dk >= signed(resize(r.dnext, 34)))) then
					if (r.k = 7) then
						v.state := S_TILE;
					else
						v.k := r.k + 1;
						v.acc := r.acc + resize(r.ddx, 27);
						if (r.axis = '1') then
							v.acc := r.acc + resize(r.ddy, 27);
						end if;
					end if;
				else
					if (r.mv = '1') then
						q := r.k;
					else
						q := 7 - r.k;
					end if;
					v.ev_d := clamp_d(unsigned(dk(31 downto 0)));
					v.ev_side := r.axis;
					v.ev_fn := step_height(r.base, r.diff, r.rpos, q);
					v.ev_cn := r.c;
					v.ev_tex := std_logic_vector(to_unsigned(RISER_TEX, 4));
					v.ev_given := '0';
					v.ev_final := '0';
					v.ev_ramp := '1';
					v.state := S_E0;
				end if;

			when S_TILE =>
				t := r.ntile;
				v.steps := r.steps + 1;
				v.seen_we := '1';
				v.seen_addr := std_logic_vector(r.my & r.mx);
				v.ev_d := clamp_d(r.dnext);
				v.ev_side := r.side;
				v.ev_tex := t(3 downto 0);
				v.ev_given := '0';
				v.ev_ramp := '0';
				-- A textured tile is solid unless it is a door (special 1..3) on the axis just crossed (bit 23)
				if ((r.steps + 1 >= MAX_STEPS) or ((t(3 downto 0) /= "0000") and
					not ((t(16 downto 14) /= "000") and (t(16) = '0') and (t(23) = r.side)))) then
					-- Solid wall (or the DDA gave up)
					v.ev_final := '1';
					v.state := S_E0;
				elsif (t(3 downto 0) /= "0000") then
					-- Specials 1, 2, 3 on their axis: door plane half a cell
					-- in, entered at sd - dd, far edge at sd
					if (r.side = '0') then
						v.dmid := r.sdx - shift_right(resize(r.ddx, 32), 1);
						v.mul_b := resize(r.ry, 25);
					else
						v.dmid := r.sdy - shift_right(resize(r.ddy, 32), 1);
						v.mul_b := resize(r.rx, 25);
					end if;
					v.mul_a := signed(resize(v.dmid, 33));
					v.mul_go := '1';
					v.state := S_DOOR;
				elsif (is_ramp(t)) then
					v.state := S_RN0;
				else
					v.n_ramp := '0';
					v.n_f := floor_height(t);
					v.n_c := ceil_height(t);
					v.state := S_OPEN;
				end if;

			when S_DOOR =>
				if (mul_v = '1') then
					-- Only the fraction of (pos + (dmid * ray >> 16)) matters:
					-- low 16 bits of pos plus bits 31:16 of the product
					if (r.side = '0') then
						pos_lo := pos_y(15 downto 0);
					else
						pos_lo := pos_x(15 downto 0);
					end if;
					along := pos_lo + unsigned(mul_p(31 downto 16));
					frac := '0' & along;
					-- Hit: the ray reaches the door plane before leaving the cell sideways, past the open part
					if (((r.side = '0') and (r.dmid < r.sdy)) or ((r.side = '1') and (r.dmid < r.sdx))) and
						(frac >= door_open) then
						frac := frac - door_open;
						v.tex_col := frac(15 downto 10);
						v.ev_given := '1';
						v.ev_d := clamp_d(r.dmid);
						v.ev_final := '1';
						v.state := S_E0;
					else
						-- Through the open part: the door cell is an open tile
						v.n_ramp := '0';
						v.n_f := floor_height(r.ntile);
						v.n_c := ceil_height(r.ntile);
						v.state := S_OPEN;
					end if;
				end if;

			when S_RN0 =>
				-- Map read of the tile this ramp rises to (address mux)
				v.state := S_RN1;

			when S_RN1 =>
				t := r.ntile;
				v.n_ramp := '1';
				v.n_axis := t(7);
				v.n_pos := not t(6);
				v.n_base := floor_height(t);
				v.n_diff := signed('0' & map_data_i(19 downto 17)) - signed('0' & t(19 downto 17));
				v.n_c := ceil_height(t);
				if (t(7) = r.side) then
					-- Entered across the ramp axis: the step at that face
					if (((t(7) = '0') and (r.rx >= 0)) or ((t(7) = '1') and (r.ry >= 0))) then
						q := "000";
					else
						q := "111";
					end if;
					v.n_f := step_height(floor_height(t), v.n_diff, not t(6), q);
					v.state := S_OPEN;
				else
					-- Entered from a side: the step under the entry point
					v.mul_a := signed(resize(r.dnext, 33));
					if (t(7) = '0') then
						v.mul_b := resize(r.rx, 25);
					else
						v.mul_b := resize(r.ry, 25);
					end if;
					v.mul_go := '1';
					v.state := S_RN2;
				end if;

			when S_RN2 =>
				if (mul_v = '1') then
					if (r.n_axis = '0') then
						pos_lo := pos_x(15 downto 0);
					else
						pos_lo := pos_y(15 downto 0);
					end if;
					along := pos_lo + unsigned(mul_p(31 downto 16));
					v.n_f := step_height(r.n_base, r.n_diff, r.n_pos, along(15 downto 13));
					v.state := S_OPEN;
				end if;

			when S_OPEN =>
				if ((r.n_f /= r.f) or (r.n_c /= r.c)) then
					v.ev_fn := r.n_f;
					v.ev_cn := r.n_c;
					v.ev_tex := std_logic_vector(to_unsigned(RISER_TEX, 4));
					v.ev_final := '0';
					v.state := S_E0;
				else
					-- Same heights: just walk on
					v.light := tile_light(r.ntile, fx_i);
					v.ramp := r.n_ramp;
					v.axis := r.n_axis;
					v.rpos := r.n_pos;
					v.base := r.n_base;
					v.diff := r.n_diff;
					v.denter := r.dnext;
					v.state := S_STEP;
				end if;

			------------------------------------------------------------
			-- Event: height edge (ev_final = 0) or wall (ev_final = 1)
			------------------------------------------------------------
			when S_E0 =>
				v.lh_go := '1';
				v.mul_a := signed(resize(r.ev_d, 33));
				if (r.ev_side = '0') then
					v.mul_b := resize(r.ry, 25);
				else
					v.mul_b := resize(r.rx, 25);
				end if;
				v.mul_go := '1';
				v.state := S_E1;

			when S_E1 =>
				if (mul_v = '1') then
					if (r.ev_given = '0') then
						-- Texture column: fraction of pos + (d * ray >> 16),
						-- mirrored on +x-going x faces and -y-going y faces
						if (r.ev_side = '0') then
							pos_lo := pos_y(15 downto 0);
						else
							pos_lo := pos_x(15 downto 0);
						end if;
						along := pos_lo + unsigned(mul_p(31 downto 16));
						col_bits := along(15 downto 10);
						if (((r.ev_side = '0') and (r.rx > 0)) or ((r.ev_side = '1') and (r.ry < 0))) then
							col_bits := 63 - col_bits;
						end if;
						v.tex_col := col_bits;
					end if;
					v.mul_a := signed(resize(r.ev_d, 33));
					v.mul_b := to_signed(M_TS, 25);
					v.mul_go := '1';
					v.state := S_E2;
				end if;

			when S_E2 =>
				if (mul_v = '1') then
					v.tex_step := unsigned(mul_p(39 downto 16));
					v.state := S_E3;
				end if;

			when S_E3 =>
				-- The lineHeight divide started in S_E0 and is busy by now
				if ((lh_busy = '0') and (r.lh_go = '0')) then
					lhq := unsigned(lh_q);
					if (lhq > LH_MAX) then
						v.lh := to_unsigned(LH_MAX, 20);
					else
						v.lh := lhq(19 downto 0);
					end if;
					v.state := S_E4;
				end if;

			when S_E4 =>
				-- The row products of r.lh are registered at this edge
				v.state := S_E5;

			when S_E5 =>
				v.rf := row_of(prod_f);
				v.rc := row_of(prod_c);
				v.rt := row_of(prod_fn);
				v.rb := row_of(prod_cn);
				v.top_f := resize(to_signed(HORIZON * 256, 29) + shift_right(prod_64, 6), 28);
				v.e_floor := unsigned(resize(eye - signed(resize(r.f, 9)), 7));
				v.e_ceil := unsigned(resize(signed(resize(r.c, 9)) - eye, 7));
				v.state := S_E6;

			when S_E6 =>
				-- Floor span: rows max(rf, wtop) .. wbot, then wbot = rf - 1
				-- (one window rule per clock keeps each compare chain short)
				v.sv := "0000";
				a := smax(r.rf, r.wtop);
				if (a <= r.wbot) then
					v.sv(0) := '1';
					v.sy0(0) := to_integer(unsigned(a(7 downto 0)));
					v.sy1(0) := to_integer(unsigned(r.wbot(7 downto 0)));
				end if;
				v.wbot := smin(r.wbot, r.rf - 1);
				v.state := S_E6B;

			when S_E6B =>
				-- Ceiling span: rows wtop .. min(rc - 1, wbot), then wtop = rc
				b := smin(r.rc - 1, r.wbot);
				if (r.wtop <= b) then
					v.sv(1) := '1';
					v.sy0(1) := to_integer(unsigned(r.wtop(7 downto 0)));
					v.sy1(1) := to_integer(unsigned(b(7 downto 0)));
				end if;
				v.wtop := smax(r.wtop, r.rc);
				v.state := S_E7;

			when S_E7 =>
				if (r.ev_final = '1') then
					-- The wall fills the rest of the window
					if (r.wtop <= r.wbot) then
						v.sv(2) := '1';
						v.sy0(2) := to_integer(unsigned(r.wtop(7 downto 0)));
						v.sy1(2) := to_integer(unsigned(r.wbot(7 downto 0)));
					end if;
				elsif (r.ev_fn > r.f) then
					-- Riser where the floor steps up
					a := smax(r.rt, r.wtop);
					if (a <= r.wbot) then
						v.sv(2) := '1';
						v.sy0(2) := to_integer(unsigned(a(7 downto 0)));
						v.sy1(2) := to_integer(unsigned(r.wbot(7 downto 0)));
					end if;
					v.wbot := smin(r.wbot, r.rt - 1);
				end if;
				v.state := S_E8;

			when S_E8 =>
				wt := r.wtop;
				wb := r.wbot;
				if (r.ev_final = '1') then
					v.closed := '1';
				else
					-- Upper wall where the ceiling steps down
					if (r.ev_cn < r.c) then
						b := smin(r.rb - 1, wb);
						if (wt <= b) then
							v.sv(3) := '1';
							v.sy0(3) := to_integer(unsigned(wt(7 downto 0)));
							v.sy1(3) := to_integer(unsigned(b(7 downto 0)));
						end if;
						wt := smax(wt, r.rb);
					end if;
					v.wtop := wt;
					-- Clip entry: the window behind this edge; 16 at most,
					-- then the last one is rewritten
					if (wt > wb) then
						v.closed := '1';
						v.clip_data := x"00" & x"01" & std_logic_vector(zsat(r.ev_d)); -- Bottom 0, top 1: closed
					else
						v.closed := '0';
						v.clip_data := std_logic_vector(wb(7 downto 0)) & std_logic_vector(wt(7 downto 0)) &
							std_logic_vector(zsat(r.ev_d));
					end if;
					if (r.nclip = CLIP_MAX) then
						idx := to_unsigned(CLIP_MAX - 1, 4);
					else
						idx := r.nclip(3 downto 0);
						v.nclip := r.nclip + 1;
					end if;
					v.clip_addr := r.col & idx;
					v.clip_we := '1';
				end if;
				v.zval := zsat(r.ev_d);
				v.slot := "00";
				v.state := S_X0;

			------------------------------------------------------------
			-- Span output, model order: floor, ceiling, riser or wall,
			-- upper wall
			------------------------------------------------------------
			when S_X0 =>
				-- The last span of a closing event carries DESC_LAST
				if (r.sv(3) = '1') then
					v.last := "11";
				elsif (r.sv(2) = '1') then
					v.last := "10";
				elsif (r.sv(1) = '1') then
					v.last := "01";
				else
					v.last := "00";
				end if;
				if (r.sv(to_integer(r.slot)) = '0') then
					if (r.slot = 3) then
						v.state := S_EVEND;
					else
						v.slot := r.slot + 1;
					end if;
				elsif (r.slot(1) = '1') then
					-- Textured: v0 = (y0 * 256 + 128 - top) * tex_step >> 8
					offset := to_signed(r.sy0(to_integer(r.slot)) * 256 + 128, 28) - r.top_f;
					v.mul_a := resize(offset, 33);
					v.mul_b := signed(resize(r.tex_step, 25));
					v.mul_go := '1';
					v.state := S_X1;
				else
					v.state := S_X1;
				end if;

			when S_X1 =>
				if ((r.slot(1) = '0') or (mul_v = '1')) then
					dsc := (others => '0');
					dsc(DESC_COL_HI downto DESC_COL_LO) := std_logic_vector(r.col);
					dsc(DESC_Y0_HI downto DESC_Y0_LO) := std_logic_vector(to_unsigned(r.sy0(to_integer(r.slot)), 8));
					dsc(DESC_Y1_HI downto DESC_Y1_LO) := std_logic_vector(to_unsigned(r.sy1(to_integer(r.slot)), 8));
					dsc(DESC_RX_HI downto DESC_RX_LO) := std_logic_vector(r.rx);
					dsc(DESC_RY_HI downto DESC_RY_LO) := std_logic_vector(r.ry);
					case r.slot is
						when "00" =>
							dsc(DESC_KIND_HI downto DESC_KIND_LO) := KIND_FLOOR;
							dsc(DESC_E_HI downto DESC_E_LO) := std_logic_vector(r.e_floor);
						when "01" =>
							dsc(DESC_KIND_HI downto DESC_KIND_LO) := KIND_CEIL;
							dsc(DESC_E_HI downto DESC_E_LO) := std_logic_vector(r.e_ceil);
						when others =>
							dsc(DESC_KIND_HI downto DESC_KIND_LO) := KIND_WALL;
							if (r.slot = "10") then
								dsc(DESC_TEX_HI downto DESC_TEX_LO) := r.ev_tex;
							else
								dsc(DESC_TEX_HI downto DESC_TEX_LO) := std_logic_vector(to_unsigned(RISER_TEX, 4));
							end if;
							dsc(DESC_TCOL_HI downto DESC_TCOL_LO) := std_logic_vector(r.tex_col);
							dsc(DESC_V0_HI downto DESC_V0_LO) := std_logic_vector(mul_p(30 downto 8)); -- Product >> 8
							dsc(DESC_STEP_HI downto DESC_STEP_LO) := std_logic_vector(r.tex_step);
							dsc(DESC_LIGHT_HI downto DESC_LIGHT_LO) :=
								std_logic_vector(eff_light(r.light, r.ev_d, r.ev_side));
							dsc(DESC_SIDE) := r.ev_side;
					end case;
					if ((r.closed = '1') and (r.slot = r.last)) then
						dsc(DESC_LAST) := '1';
					end if;
					v.desc := dsc;
					v.desc_valid := '1';
					v.state := S_X2;
				end if;

			when S_X2 =>
				if (desc_ready_i = '1') then
					v.desc_valid := '0';
					if (r.slot = 3) then
						v.state := S_EVEND;
					else
						v.slot := r.slot + 1;
						v.state := S_X0;
					end if;
				end if;

			when S_EVEND =>
				if (r.closed = '1') then
					v.state := S_COLEND;
				elsif (r.ev_ramp = '1') then
					-- Next sub-edge of the ramp, from the new step's floor
					v.f := r.ev_fn;
					if (r.k = 7) then
						v.state := S_TILE;
					else
						v.k := r.k + 1;
						if (r.axis = '0') then
							v.acc := r.acc + resize(r.ddx, 27);
						else
							v.acc := r.acc + resize(r.ddy, 27);
						end if;
						v.state := S_RK;
					end if;
				else
					-- Tile edge passed: the walk is in the new tile
					v.f := r.ev_fn;
					v.c := r.ev_cn;
					v.light := tile_light(r.ntile, fx_i);
					v.ramp := r.n_ramp;
					v.axis := r.n_axis;
					v.rpos := r.n_pos;
					v.base := r.n_base;
					v.diff := r.n_diff;
					v.denter := r.dnext;
					v.state := S_STEP;
				end if;

			when S_COLEND =>
				if (r.col = SCREEN_W - 1) then
					v.done := '1';
					v.state := S_IDLE;
				else
					v.col := r.col + 1;
					v.state := S_C0;
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

	------------------------------------------------------------------
	-- Outputs
	------------------------------------------------------------------
	desc_o <= r.desc;
	desc_valid_o <= r.desc_valid;
	-- z-buffer and clip count once per column, after its last span
	zbuf_we_o <= '1' when (r.state = S_COLEND) else '0';
	zbuf_addr_o <= std_logic_vector(r.col);
	zbuf_data_o <= std_logic_vector(r.zval);
	ccount_we_o <= '1' when (r.state = S_COLEND) else '0';
	ccount_addr_o <= std_logic_vector(r.col);
	ccount_data_o <= std_logic_vector(r.nclip);
	clip_we_o <= r.clip_we;
	clip_addr_o <= std_logic_vector(r.clip_addr);
	clip_data_o <= r.clip_data;
	seen_we_o <= r.seen_we;
	seen_addr_o <= r.seen_addr;
	busy_o <= '0' when (r.state = S_IDLE) else '1';
	done_o <= r.done;
end arch;

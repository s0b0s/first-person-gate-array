--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Sprite Engine
-- Module Name:    sprite_engine
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Draws the frame's sprites (enemies, items, fireballs) over
--                 the walls, matching tools/model/sprites.py bit for bit.
--                 Pass 1: for every sprite table entry, depth =
--                   (rx * cos + ry * sin) >> 16 with rx, ry = (x << 6) - cam
--                   (Q.16 tiles); entries with depth < 1/8 tile are culled.
--                 Pass 2: repeatedly pick the farthest remaining entry
--                   (strictly larger depth wins, so equal depths keep table
--                   order: the model's stable sort), project it in full:
--                     lateral = (-rx * sin + ry * cos) >> 16
--                     lh      = min(N_LH / depth, LH_MAX)       (divider)
--                     w_f, h_f = (lh * width) >> 6, (lh * height) >> 6
--                     left    = 40960 + ((lateral * lh) >> 16) - (w_f >> 1)
--                     bottom  = 30720 + ((lh * (eye - floor)) >> 6),
--                               top = bottom - h_f (floor: the sprite's floor
--                               height, stage 4; eye - floor may be negative)
--                     x0, x1, y0, y1 by the pixel-center rule, clipped
--                     step    = (depth * M_TS) >> 16  texels per pixel, Q.16
--                   then draw it at once, column by column: a column is
--                   drawn only where z = min(depth >> 6, 65535) is below the
--                   wall z; u starts at ((x0 * 256 + 128 - left) * step) >> 8
--                   and v at ((y0 * 256 + 128 - top) * step) >> 8 and both
--                   advance by step (exact: ((d + 256) * s) >> 8 equals
--                   ((d * s) >> 8) + s), clamped to the frame size.
--                   Stage 4 clip windows: before a column is drawn its clip
--                   list (render_top: count and entries, nearest first) is
--                   scanned, one entry per clock, for the last entry with
--                   entry z <= sprite z; only rows inside that window are
--                   read and written (rows 0..239 without entries). Rows
--                   above the window are skipped one per clock while v
--                   still advances, rows below it end the column.
--                 Texels are read from the art in SRAM (column-major at
--                 ART_BASE + frame offset + u * height + v) through an
--                 arbiter master port, several reads in flight. Each read
--                 carries its pixel address and light level through a
--                 16-word FIFO; returned texels other than 255 go through
--                 the light table into a 16-word output FIFO feeding the
--                 pixel port. A read is issued only while
--                 reads in flight + pipeline + output FIFO < 12, so neither
--                 FIFO can overflow under back-pressure.
--                 Spans (actor index, x0, x1, z) of every target sprite that
--                 survives culling are written in drawing order into the
--                 bank not being read; the banks swap when the frame ends,
--                 so the game always reads the last finished frame.
--                 Multiplies share one signed 32 x 25 multiplier with three
--                 pipeline registers (4 clocks per product); one divider.
--                 Clock domain: clk_i (system). About 100 clocks per sprite
--                 plus about 4 clocks per drawn texel (2 per SRAM read and
--                 2 per pixel write share the SRAM).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, render_pkg,
--                 render_types_pkg, game_pkg, game_tables_pkg, hw_pkg,
--                 divider, light_rom, sprite_fifo
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 2.00 - Stage 4: sprite floor height, clip windows
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;
use work.game_pkg.all;
use work.render_pkg.all;
use work.render_types_pkg.all;
use work.game_tables_pkg.all;

entity sprite_engine is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		start_i: in std_logic; -- Pulse after the walls are done
		cam_x_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Camera x, Q6.16
		cam_y_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Camera y, Q6.16
		angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0); -- View angle
		eye_i: in std_logic_vector(EYE_BITS - 1 downto 0); -- Eye height 0..127
		buf_i: in std_logic; -- Framebuffer to draw
		spr_addr_o: out std_logic_vector(4 downto 0); -- Sprite table read, 1 clock
		spr_data_i: in std_logic_vector(SPR_BITS - 1 downto 0);
		spr_count_i: in std_logic_vector(5 downto 0); -- Entries in the table
		zwall_addr_o: out std_logic_vector(8 downto 0); -- Wall z read, 1 clock
		zwall_data_i: in std_logic_vector(15 downto 0);
		clip_addr_o: out std_logic_vector(12 downto 0); -- Clip entry read: column & index, 1 clock
		clip_data_i: in std_logic_vector(CLIP_BITS - 1 downto 0);
		ccount_addr_o: out std_logic_vector(8 downto 0); -- Clip entry count of a column, 1 clock
		ccount_data_i: in std_logic_vector(4 downto 0);
		m_req_o: out std_logic; -- SRAM arbiter master port (reads)
		m_addr_o: out std_logic_vector(18 downto 0);
		m_gnt_i: in std_logic;
		m_rvalid_i: in std_logic;
		m_rdata_i: in std_logic_vector(7 downto 0);
		pix_valid_o: out std_logic; -- Pixel write port
		pix_ready_i: in std_logic;
		pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
		span_raddr_i: in std_logic_vector(4 downto 0); -- Spans of the last frame
		span_rdata_o: out std_logic_vector(SPAN_BITS - 1 downto 0);
		span_count_o: out std_logic_vector(5 downto 0);
		busy_o: out std_logic; -- Frame in progress
		done_o: out std_logic; -- Pulse: every sprite pixel accepted
		pixels_o: out std_logic_vector(15 downto 0) -- Sprite pixels last frame (saturates)
	);
end sprite_engine;

architecture arch of sprite_engine is
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
	component light_rom is
		port(
			clk_i: in std_logic;
			addr_i: in std_logic_vector(11 downto 0);
			data_o: out std_logic_vector(7 downto 0)
		);
	end component;
	component sprite_fifo is
		generic(
			WIDTH: positive := 8
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			push_i: in std_logic;
			din_i: in std_logic_vector(WIDTH - 1 downto 0);
			pop_i: in std_logic;
			dout_o: out std_logic_vector(WIDTH - 1 downto 0);
			empty_o: out std_logic;
			level_o: out std_logic_vector(4 downto 0)
		);
	end component;

	constant DEPTH_MIN: natural := 8192; -- 1/8 tile
	constant CREDITS: natural := 12; -- Reads in flight + pipeline + output FIFO limit

	type state_t is (
		S_IDLE,
		S_TRIG, -- Read sin and cos of the view angle
		S_P1_READ, -- Pass 1: sprite table address on the bus
		S_P1_REL, -- rx, ry; multiply rx * cos
		S_P1_M2, -- multiply ry * sin
		S_P1_STORE, -- depth, culled flag
		S_SEL, -- Pass 2: scan for the farthest remaining sprite
		S_P2_READ, -- Its table entry
		S_P2_REL, -- rx, ry, frame size, light, z; divider; rx * -sin
		S_P2_LAT, -- ry * cos
		S_P2_LAT2, -- lateral
		S_P2_DIV, -- wait for lineHeight; lh * width
		S_P2_W, -- lh * height
		S_P2_H, -- lateral * lh
		S_P2_C, -- lh * (eye - floor)
		S_P2_E, -- depth * M_TS
		S_P2_S, -- left, top
		S_P2_EDGE, -- unclipped columns and rows
		S_P2_CLIP, -- clipping, span
		S_P2_DX, -- (x0 term) * step
		S_P2_U, -- (y0 term) * step
		S_P2_V, -- start drawing
		S_COL, -- wall z address of the column
		S_COLZ, -- depth test, clip count
		S_CLIPA, -- first clip entry address
		S_CLIPD, -- one clip entry per clock: window at the sprite's depth
		S_CSTART, -- column start: art column, first row, last row
		S_ROW, -- issue texel reads down the column
		S_FINISH, -- wait until every pixel has left
		S_MULW -- wait for a product, then go to ret
	);

	type depth_array_t is array (0 to 31) of unsigned(25 downto 0);

	type regs_t is record
		state: state_t;
		ret: state_t;
		mcnt: natural range 0 to 3;
		cam_x, cam_y: signed(23 downto 0);
		angle: unsigned(9 downto 0);
		eye: unsigned(6 downto 0);
		floor: unsigned(6 downto 0); -- Floor height under the current sprite
		buf: std_logic;
		count: unsigned(5 downto 0);
		cs, sn: signed(17 downto 0);
		k: unsigned(5 downto 0); -- Pass 1 index / pass 2 scan index
		depth: depth_array_t;
		live: std_logic_vector(31 downto 0); -- Not culled and not yet drawn
		best: unsigned(5 downto 0);
		found: std_logic;
		sel: unsigned(4 downto 0);
		rx, ry: signed(23 downto 0);
		pa: signed(56 downto 0);
		mul_a: signed(31 downto 0);
		mul_b: signed(24 downto 0);
		div_start: std_logic;
		div_ok: std_logic;
		-- Current sprite
		idx: unsigned(4 downto 0);
		target: std_logic;
		off: unsigned(17 downto 0);
		fw, fh: unsigned(6 downto 0);
		lvl: unsigned(3 downto 0);
		z: unsigned(15 downto 0);
		d: unsigned(25 downto 0);
		lateral: signed(31 downto 0);
		lh: unsigned(19 downto 0);
		w_f, h_f: signed(31 downto 0);
		center, bottom, left, top: signed(31 downto 0);
		ex0, ex1, ey0, ey1: signed(31 downto 0); -- Unclipped first and last column and row
		step: unsigned(24 downto 0);
		x, x1, y, y1: unsigned(8 downto 0);
		y0: unsigned(8 downto 0);
		u, v, vs: unsigned(49 downto 0);
		base: unsigned(18 downto 0); -- Art offset of the column
		wt, wb: unsigned(7 downto 0); -- Clip window of the column (wt > wb: closed)
		cj: unsigned(4 downto 0); -- Clip entry index on the read port
		ccnt: unsigned(4 downto 0); -- Clip entries of the column
		ylast: unsigned(8 downto 0); -- Last row drawn in the column
		paddr: unsigned(16 downto 0);
		-- Spans
		span_we: std_logic;
		span_n: unsigned(5 downto 0);
		span_data: std_logic_vector(SPAN_BITS - 1 downto 0);
		bank: std_logic; -- Bank the game reads
		span_last: unsigned(5 downto 0);
		pixels: unsigned(15 downto 0);
		pixels_last: unsigned(15 downto 0);
		done: std_logic;
	end record;

	constant REGS_INIT: regs_t := (
		state => S_IDLE, ret => S_IDLE, mcnt => 0,
		cam_x => (others => '0'), cam_y => (others => '0'), angle => (others => '0'),
		eye => (others => '0'), floor => (others => '0'), buf => '0', count => (others => '0'),
		cs => (others => '0'), sn => (others => '0'), k => (others => '0'),
		depth => (others => (others => '0')), live => (others => '0'),
		best => (others => '0'), found => '0', sel => (others => '0'),
		rx => (others => '0'), ry => (others => '0'), pa => (others => '0'),
		mul_a => (others => '0'), mul_b => (others => '0'), div_start => '0', div_ok => '0',
		idx => (others => '0'), target => '0', off => (others => '0'), fw => (others => '0'),
		fh => (others => '0'), lvl => (others => '0'), z => (others => '0'), d => (others => '0'),
		lateral => (others => '0'), lh => (others => '0'), w_f => (others => '0'),
		h_f => (others => '0'), center => (others => '0'), bottom => (others => '0'),
		left => (others => '0'), top => (others => '0'), ex0 => (others => '0'),
		ex1 => (others => '0'), ey0 => (others => '0'), ey1 => (others => '0'), step => (others => '0'),
		x => (others => '0'), x1 => (others => '0'), y => (others => '0'), y1 => (others => '0'),
		y0 => (others => '0'), u => (others => '0'), v => (others => '0'), vs => (others => '0'),
		base => (others => '0'), wt => (others => '0'), wb => (others => '0'),
		cj => (others => '0'), ccnt => (others => '0'), ylast => (others => '0'),
		paddr => (others => '0'), span_we => '0',
		span_n => (others => '0'), span_data => (others => '0'), bank => '0',
		span_last => (others => '0'), pixels => (others => '0'), pixels_last => (others => '0'),
		done => '0'
	);

	signal r: regs_t := REGS_INIT;
	signal r_next: regs_t;

	-- Multiplier pipeline
	signal m1_a: signed(31 downto 0) := (others => '0');
	signal m1_b: signed(24 downto 0) := (others => '0');
	signal m2, m3: signed(56 downto 0) := (others => '0');

	signal div_done: std_logic;
	signal div_quo: std_logic_vector(23 downto 0);

	-- Read return path
	signal issue: std_logic;
	signal in_flight: unsigned(4 downto 0) := (others => '0');
	signal coord_din, coord_dout: std_logic_vector(20 downto 0); -- light 20:17, pixel address 16:0
	signal a_valid, b_valid: std_logic := '0';
	signal a_addr, b_addr: std_logic_vector(16 downto 0) := (others => '0');
	signal light_addr: std_logic_vector(11 downto 0) := (others => '0');
	signal light_data: std_logic_vector(7 downto 0);
	signal out_din, out_dout: std_logic_vector(PIXW_BITS - 1 downto 0);
	signal out_empty: std_logic;
	signal out_level: std_logic_vector(4 downto 0);
	signal out_pop: std_logic;
	signal credit_ok: std_logic;
	signal in_win: std_logic; -- Current row is inside the clip window
	signal art_addr: unsigned(18 downto 0);

	type span_ram_t is array (0 to 63) of std_logic_vector(SPAN_BITS - 1 downto 0);
	signal span_ram: span_ram_t := (others => (others => '0'));
	-- 64 x 48 bits is a whole RAMB36 (wider than 36 bits); about 50 LUTs
	-- of distributed RAM instead keeps the block within its 1-BRAM budget
	attribute ram_style: string;
	attribute ram_style of span_ram: signal is "distributed";

	-- Pixel-center rule: first pixel whose center (p * 256 + 128) is at or
	-- past f, i.e. ceil((f - 128) / 256) = (f + 127) >> 8 (floor shift)
	function first_pixel(f: signed(31 downto 0)) return signed is
	begin
		return shift_right(f + 127, 8);
	end function;
begin
	divide: divider
		generic map (
			NUM_BITS => 33,
			DEN_BITS => 26,
			QUO_BITS => 24
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			start_i => r.div_start,
			num_i => '0' & std_logic_vector(N_LH),
			den_i => std_logic_vector(r.d),
			busy_o => open,
			done_o => div_done,
			quo_o => div_quo
		);

	-- Shared multiplier: operands registered, product, one more register
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			m1_a <= r.mul_a;
			m1_b <= r.mul_b;
			m2 <= m1_a * m1_b;
			m3 <= m2;
		end if;
	end process;

	-- Art address of the next texel: frame offset + column base + row
	process(r)
		variable vrow: unsigned(6 downto 0);
	begin
		-- Row = v >> 16, clamped to the last row of the frame
		if (r.v(49 downto 16) >= resize(r.fh, 34)) then
			vrow := r.fh - 1;
		else
			vrow := r.v(22 downto 16);
		end if;
		art_addr <= to_unsigned(ART_BASE, 19) + r.base + resize(vrow, 19);
	end process;

	-- Reads in flight + stages A and B + output FIFO words must stay below CREDITS
	credit_ok <= '1' when (resize(in_flight, 6) + ("00000" & a_valid) + ("00000" & b_valid) +
		resize(unsigned(out_level), 6) < CREDITS) else '0';
	in_win <= '1' when (r.y >= resize(r.wt, 9)) else '0';
	issue <= '1' when ((r.state = S_ROW) and (in_win = '1') and (credit_ok = '1') and (m_gnt_i = '1')) else '0';

	------------------------------------------------------------------
	-- Next state
	------------------------------------------------------------------
	process(r, spr_data_i, spr_count_i, zwall_data_i, clip_data_i, ccount_data_i, div_done,
		div_quo, m3, issue, in_win, cam_x_i, cam_y_i, angle_i, eye_i, buf_i, start_i, in_flight,
		a_valid, b_valid, out_empty)
		variable v: regs_t;
		variable sx, sy: unsigned(15 downto 0);
		variable prod: signed(56 downto 0);
		variable dep: signed(56 downto 0);
		variable f: natural range 0 to 60;
		variable light: signed(5 downto 0);
		variable x0s, x1s, y0s, y1s: signed(31 downto 0);
		variable dx: signed(31 downto 0);
		variable ucol: unsigned(6 downto 0);
		variable col_off: unsigned(13 downto 0);
		variable q: unsigned(23 downto 0);
		variable ef: signed(8 downto 0); -- eye - floor
		variable ylo: unsigned(8 downto 0);

		procedure multiply(variable vv: inout regs_t; a: signed; b: signed; ret: state_t) is
		begin
			vv.mul_a := resize(a, 32);
			vv.mul_b := resize(b, 25);
			vv.mcnt := 3; -- Operands, product, register: the product is in m3 when ret starts
			vv.ret := ret;
			vv.state := S_MULW;
		end procedure;

		-- Step to the next column, or back to the sprite scan after the last
		procedure next_column(variable vv: inout regs_t) is
		begin
			if (vv.x = vv.x1) then
				vv.k := (others => '0');
				vv.found := '0';
				vv.state := S_SEL;
			else
				vv.x := vv.x + 1;
				vv.u := vv.u + resize(vv.step, 50);
				vv.state := S_COL;
			end if;
		end procedure;
	begin
		v := r;
		v.div_start := '0';
		v.span_we := '0';
		v.done := '0';
		prod := m3;
		if (div_done = '1') then
			v.div_ok := '1';
		end if;

		case r.state is
			when S_IDLE =>
				if (start_i = '1') then
					v.cam_x := signed(resize(unsigned(cam_x_i), 24));
					v.cam_y := signed(resize(unsigned(cam_y_i), 24));
					v.angle := unsigned(angle_i);
					v.eye := unsigned(eye_i);
					v.buf := buf_i;
					v.count := unsigned(spr_count_i);
					v.k := (others => '0');
					v.live := (others => '0');
					v.span_n := (others => '0');
					v.pixels := (others => '0');
					v.state := S_TRIG;
				end if;

			when S_TRIG =>
				v.sn := to_signed(SIN_TABLE(to_integer(r.angle)), 18);
				v.cs := to_signed(SIN_TABLE(to_integer(r.angle + 256)), 18); -- cos = sin(angle + 1/4 turn)
				if (r.count = 0) then
					v.state := S_FINISH;
				else
					v.state := S_P1_READ;
				end if;

			-- Pass 1: depth of every entry -------------------------------------
			when S_P1_READ =>
				v.state := S_P1_REL;

			when S_P1_REL =>
				sx := unsigned(spr_data_i(SPR_X_HI downto SPR_X_LO));
				sy := unsigned(spr_data_i(SPR_Y_HI downto SPR_Y_LO));
				-- Sprite position is Q6.10; << 6 makes it Q6.16 like the camera
				v.rx := signed(shift_left(resize(sx, 24), 6)) - r.cam_x;
				v.ry := signed(shift_left(resize(sy, 24), 6)) - r.cam_y;
				multiply(v, v.rx, r.cs, S_P1_M2);

			when S_P1_M2 =>
				v.pa := prod;
				multiply(v, r.ry, r.sn, S_P1_STORE);

			when S_P1_STORE =>
				dep := shift_right(r.pa + prod, 16);
				v.depth(to_integer(r.k(4 downto 0))) := unsigned(dep(25 downto 0));
				if (dep >= DEPTH_MIN) then
					v.live(to_integer(r.k(4 downto 0))) := '1';
				end if;
				if (r.k + 1 = r.count) then
					v.k := (others => '0');
					v.found := '0';
					v.state := S_SEL;
				else
					v.k := r.k + 1;
					v.state := S_P1_READ;
				end if;

			-- Pass 2: farthest live sprite first ---------------------------------
			when S_SEL =>
				if (r.k = r.count) then
					if (r.found = '1') then
						v.sel := r.best(4 downto 0);
						v.live(to_integer(r.best(4 downto 0))) := '0';
						v.state := S_P2_READ;
					else
						v.state := S_FINISH;
					end if;
				else
					if (r.live(to_integer(r.k(4 downto 0))) = '1') then
						if ((r.found = '0') or
							(r.depth(to_integer(r.k(4 downto 0))) > r.depth(to_integer(r.best(4 downto 0))))) then
							v.best := r.k;
							v.found := '1';
						end if;
					end if;
					v.k := r.k + 1;
				end if;

			when S_P2_READ =>
				v.state := S_P2_REL;

			when S_P2_REL =>
				sx := unsigned(spr_data_i(SPR_X_HI downto SPR_X_LO));
				sy := unsigned(spr_data_i(SPR_Y_HI downto SPR_Y_LO));
				v.rx := signed(shift_left(resize(sx, 24), 6)) - r.cam_x;
				v.ry := signed(shift_left(resize(sy, 24), 6)) - r.cam_y;
				v.idx := unsigned(spr_data_i(SPR_IDX_HI downto SPR_IDX_LO));
				v.target := spr_data_i(SPR_TARGET);
				v.floor := unsigned(spr_data_i(SPR_FLOOR_HI downto SPR_FLOOR_LO));
				f := 0; -- Frame numbers past the table (60) fall back to frame 0
				if (unsigned(spr_data_i(SPR_FRAME_HI downto SPR_FRAME_LO)) <= 60) then
					f := to_integer(unsigned(spr_data_i(SPR_FRAME_HI downto SPR_FRAME_LO)));
				end if;
				v.off := to_unsigned(FRAME_TABLE(f)(0), 18);
				v.fw := to_unsigned(FRAME_TABLE(f)(1), 7);
				v.fh := to_unsigned(FRAME_TABLE(f)(2), 7);
				v.d := r.depth(to_integer(r.sel));
				-- Light: fullbright, or tile light minus min(15, depth >> 18)
				if (spr_data_i(SPR_BRIGHT) = '1') then
					v.lvl := to_unsigned(15, 4);
				else
					-- depth >= 2^22 means depth >> 18 >= 16: the distance term is 15
					if (v.d(25 downto 22) /= 0) then
						light := signed(resize(unsigned(spr_data_i(SPR_LIGHT_HI downto SPR_LIGHT_LO)), 6)) - 15;
					else
						light := signed(resize(unsigned(spr_data_i(SPR_LIGHT_HI downto SPR_LIGHT_LO)), 6)) -
							signed(resize(v.d(21 downto 18), 6));
					end if;
					if (light < 0) then
						v.lvl := (others => '0');
					else
						v.lvl := unsigned(light(3 downto 0));
					end if;
				end if;
				-- z = min(depth >> 6, 65535)
				if (v.d(25 downto 22) /= 0) then
					v.z := (others => '1');
				else
					v.z := v.d(21 downto 6);
				end if;
				v.div_start := '1';
				v.div_ok := '0';
				multiply(v, v.rx, -resize(r.sn, 19), S_P2_LAT);

			when S_P2_LAT =>
				v.pa := prod;
				multiply(v, r.ry, r.cs, S_P2_LAT2);

			when S_P2_LAT2 =>
				dep := shift_right(r.pa + prod, 16);
				v.lateral := dep(31 downto 0);
				v.state := S_P2_DIV;

			when S_P2_DIV =>
				if (r.div_ok = '1') then
					q := unsigned(div_quo);
					if (q > LH_MAX) then
						v.lh := to_unsigned(LH_MAX, 20);
					else
						v.lh := q(19 downto 0);
					end if;
					multiply(v, signed('0' & v.lh), signed('0' & r.fw), S_P2_W);
				end if;

			when S_P2_W =>
				v.w_f := shift_right(prod, 6)(31 downto 0);
				multiply(v, signed('0' & r.lh), signed('0' & r.fh), S_P2_H);

			when S_P2_H =>
				v.h_f := shift_right(prod, 6)(31 downto 0);
				multiply(v, r.lateral, signed('0' & r.lh), S_P2_C);

			when S_P2_C =>
				v.center := 40960 + shift_right(prod, 16)(31 downto 0); -- 40960 = 160 * 256, screen center x
				ef := signed(resize(r.eye, 9)) - signed(resize(r.floor, 9));
				multiply(v, signed('0' & r.lh), ef, S_P2_E);

			when S_P2_E =>
				v.bottom := 30720 + shift_right(prod, 6)(31 downto 0); -- 30720 = 120 * 256, horizon row
				multiply(v, signed('0' & r.d), to_signed(M_TS, 25), S_P2_S);

			when S_P2_S =>
				v.step := unsigned(shift_right(prod, 16)(24 downto 0));
				v.left := r.center - shift_right(r.w_f, 1);
				v.top := r.bottom - r.h_f;
				v.state := S_P2_EDGE;

			when S_P2_EDGE =>
				-- Unclipped columns and rows; the last one is
				-- ((e + 127) >> 8) - 1 = (e - 129) >> 8
				v.ex0 := first_pixel(r.left);
				v.ex1 := shift_right(r.left + r.w_f - 129, 8);
				v.ey0 := first_pixel(r.top);
				v.ey1 := shift_right(r.bottom - 129, 8);
				v.state := S_P2_CLIP;

			when S_P2_CLIP =>
				x0s := r.ex0;
				x1s := r.ex1;
				y0s := r.ey0;
				y1s := r.ey1;
				if (x0s < 0) then
					x0s := (others => '0');
				end if;
				if (x1s > SCREEN_W - 1) then
					x1s := to_signed(SCREEN_W - 1, 32);
				end if;
				if (y0s < 0) then
					y0s := (others => '0');
				end if;
				if (y1s > SCREEN_H - 1) then
					y1s := to_signed(SCREEN_H - 1, 32);
				end if;
				-- Clipped x0 > x1 written on the unclipped edges, so the
				-- compares run in parallel with the clamps
				if ((r.ex0 > r.ex1) or (r.ex0 > SCREEN_W - 1) or (r.ex1 < 0) or
					(r.ey0 > r.ey1) or (r.ey0 > SCREEN_H - 1) or (r.ey1 < 0)) then
					-- Off screen: next sprite
					v.k := (others => '0');
					v.found := '0';
					v.state := S_SEL;
				else
					v.x := unsigned(x0s(8 downto 0));
					v.x1 := unsigned(x1s(8 downto 0));
					v.y0 := unsigned(y0s(8 downto 0));
					v.y1 := unsigned(y1s(8 downto 0));
					if (r.target = '1') then
						v.span_we := '1';
						v.span_data := (others => '0');
						v.span_data(SPAN_IDX_HI downto SPAN_IDX_LO) := std_logic_vector(r.idx);
						v.span_data(SPAN_X0_HI downto SPAN_X0_LO) := std_logic_vector(x0s(8 downto 0));
						v.span_data(SPAN_X1_HI downto SPAN_X1_LO) := std_logic_vector(x1s(8 downto 0));
						v.span_data(SPAN_Z_HI downto SPAN_Z_LO) := std_logic_vector(r.z);
					end if;
					v.state := S_P2_DX;
				end if;

			when S_P2_DX =>
				-- Center of pixel x0 minus the left edge, in 1/256 pixels
				dx := shift_left(resize(signed('0' & r.x), 32), 8) + 128 - r.left;
				multiply(v, dx, signed('0' & r.step(23 downto 0)), S_P2_U);

			when S_P2_U =>
				v.u := unsigned(shift_right(prod, 8)(49 downto 0));
				dx := shift_left(resize(signed('0' & r.y0), 32), 8) + 128 - r.top;
				multiply(v, dx, signed('0' & r.step(23 downto 0)), S_P2_V);

			when S_P2_V =>
				v.vs := unsigned(shift_right(prod, 8)(49 downto 0));
				v.state := S_COL;

			-- Drawing -------------------------------------------------------------
			when S_COL =>
				v.state := S_COLZ;

			when S_COLZ =>
				-- Wall z and the clip count of column x are on the read ports
				if (r.z >= unsigned(zwall_data_i)) then
					next_column(v);
				else
					v.wt := (others => '0');
					v.wb := to_unsigned(SCREEN_H - 1, 8);
					v.ccnt := unsigned(ccount_data_i);
					v.cj := (others => '0');
					if (unsigned(ccount_data_i) = 0) then
						v.state := S_CSTART;
					else
						v.state := S_CLIPA;
					end if;
				end if;

			when S_CLIPA =>
				-- Entry 0 is addressed now; from here the port runs one entry ahead
				v.cj := r.cj + 1;
				v.state := S_CLIPD;

			when S_CLIPD =>
				-- clip_data_i is entry cj - 1: the window is that of the last entry
				-- with entry z <= sprite z (tools/model/sprites.py window())
				if (unsigned(clip_data_i(CLIP_Z_HI downto CLIP_Z_LO)) <= r.z) then
					v.wt := unsigned(clip_data_i(CLIP_TOP_HI downto CLIP_TOP_LO));
					v.wb := unsigned(clip_data_i(CLIP_BOT_HI downto CLIP_BOT_LO));
					if (r.cj = r.ccnt) then
						v.state := S_CSTART;
					else
						v.cj := r.cj + 1;
					end if;
				else
					v.state := S_CSTART;
				end if;

			when S_CSTART =>
				-- Rows y0 .. min(y1, wb); rows above wt are skipped in S_ROW
				if (r.y1 > resize(r.wb, 9)) then
					v.ylast := resize(r.wb, 9);
				else
					v.ylast := r.y1;
				end if;
				if (r.y0 > resize(r.wt, 9)) then
					ylo := r.y0;
				else
					ylo := resize(r.wt, 9);
				end if;
				if ((r.wt > r.wb) or (ylo > v.ylast)) then
					-- Nothing of this column is open at the sprite's depth
					next_column(v);
				else
					if (r.u(49 downto 16) >= resize(r.fw, 34)) then
						ucol := r.fw - 1;
					else
						ucol := r.u(22 downto 16);
					end if;
					col_off := ucol * r.fh;
					v.base := resize(r.off, 19) + resize(col_off, 19);
					v.y := r.y0;
					v.v := r.vs;
					-- Pixel address y0 * 320 + x = (y0 << 8) + (y0 << 6) + x
					v.paddr := shift_left(resize(r.y0, 17), 8) + shift_left(resize(r.y0, 17), 6) +
						resize(r.x, 17);
					v.state := S_ROW;
				end if;

			when S_ROW =>
				-- A row inside the window advances when its read is issued, a row
				-- above the window at once (no read; v still steps)
				if ((issue = '1') or (in_win = '0')) then
					v.v := r.v + resize(r.step, 50);
					v.paddr := r.paddr + 320;
					if (r.y = r.ylast) then
						next_column(v);
					else
						v.y := r.y + 1;
					end if;
				end if;

			when S_FINISH =>
				if ((in_flight = 0) and (a_valid = '0') and (b_valid = '0') and (out_empty = '1')) then
					v.bank := not r.bank;
					v.span_last := r.span_n;
					v.pixels_last := r.pixels;
					v.done := '1';
					v.state := S_IDLE;
				end if;

			when S_MULW =>
				if (r.mcnt = 1) then
					v.state := r.ret;
				else
					v.mcnt := r.mcnt - 1;
				end if;
		end case;

		if (r.span_we = '1') then
			v.span_n := r.span_n + 1;
		end if;
		if ((b_valid = '1') and (r.pixels /= x"FFFF")) then
			v.pixels := r.pixels + 1;
		end if;
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
	-- Spans: written into the bank the game is not reading
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (r.span_we = '1') then
				span_ram(to_integer((not r.bank) & r.span_n(4 downto 0))) <= r.span_data;
			end if;
			span_rdata_o <= span_ram(to_integer(r.bank & unsigned(span_raddr_i)));
		end if;
	end process;

	------------------------------------------------------------------
	-- Texel reads and their return path
	------------------------------------------------------------------
	coord_din <= std_logic_vector(r.lvl) & std_logic_vector(r.paddr);

	coords: sprite_fifo
		generic map (
			WIDTH => 21
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			push_i => issue,
			din_i => coord_din,
			pop_i => m_rvalid_i,
			dout_o => coord_dout,
			empty_o => open,
			level_o => open
		);

	-- Stage A: returned texel; transparent ones stop here. Stage B: the
	-- light table output, pushed into the output FIFO.
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			in_flight <= (others => '0');
			a_valid <= '0';
			b_valid <= '0';
			a_addr <= (others => '0');
			b_addr <= (others => '0');
			light_addr <= (others => '0');
		elsif rising_edge(clk_i) then
			-- Reads granted but not yet returned
			if ((issue = '1') and (m_rvalid_i = '0')) then
				in_flight <= in_flight + 1;
			elsif ((issue = '0') and (m_rvalid_i = '1')) then
				in_flight <= in_flight - 1;
			end if;
			if ((m_rvalid_i = '1') and (m_rdata_i /= x"FF")) then -- Texel 255 is transparent
				a_valid <= '1';
			else
				a_valid <= '0';
			end if;
			a_addr <= coord_dout(16 downto 0);
			light_addr <= coord_dout(20 downto 17) & m_rdata_i; -- Light level, texel
			b_valid <= a_valid;
			b_addr <= a_addr;
		end if;
	end process;

	lights: light_rom
		port map (
			clk_i => clk_i,
			addr_i => light_addr,
			data_o => light_data
		);

	out_din <= r.buf & b_addr & light_data;
	out_pop <= pix_ready_i and (not out_empty);

	pixels_out: sprite_fifo
		generic map (
			WIDTH => PIXW_BITS
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			push_i => b_valid,
			din_i => out_din,
			pop_i => out_pop,
			dout_o => out_dout,
			empty_o => out_empty,
			level_o => out_level
		);

	-- The selected entry while pass 2 reads it, otherwise the scan index
	spr_addr_o <= std_logic_vector(r.sel) when ((r.state = S_P2_READ) or (r.state = S_P2_REL)) else
		std_logic_vector(r.k(4 downto 0));
	zwall_addr_o <= std_logic_vector(r.x);
	ccount_addr_o <= std_logic_vector(r.x);
	clip_addr_o <= std_logic_vector(r.x) & std_logic_vector(r.cj(3 downto 0)); -- Column x, entry cj
	m_req_o <= '1' when ((r.state = S_ROW) and (in_win = '1') and (credit_ok = '1')) else '0';
	m_addr_o <= std_logic_vector(art_addr);
	pix_valid_o <= not out_empty;
	pix_data_o <= out_dout;
	span_count_o <= std_logic_vector(r.span_last);
	busy_o <= '0' when (r.state = S_IDLE) else '1';
	done_o <= r.done;
	pixels_o <= std_logic_vector(r.pixels_last);
end arch;

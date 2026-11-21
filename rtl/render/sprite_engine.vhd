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
-- Description:    Draws the frame's sprites over the walls, bit-exact with
--                 tools/model/sprites.py.
--                 Pass 1: depth = (rx * cos + ry * sin) >> 16 per table
--                   entry, rx, ry = (x << 6) - cam (Q.16 tiles); depth
--                   below 1/8 tile is culled.
--                 Pass 2: take the farthest remaining entry (strictly
--                   larger wins, so ties keep table order like the model's
--                   stable sort) and project it:
--                     lateral = (-rx * sin + ry * cos) >> 16
--                     lh      = min(N_LH / depth, LH_MAX)       (divider)
--                     w_f, h_f = (lh * width) >> 6, (lh * height) >> 6
--                     left    = 40960 + ((lateral * lh) >> 16) - (w_f >> 1)
--                     bottom  = 30720 + ((lh * (eye - floor)) >> 6),
--                               top = bottom - h_f (eye - floor may be < 0)
--                     x0, x1, y0, y1 by the pixel-center rule, clipped
--                     step    = (depth * M_TS) >> 16  texels per pixel, Q.16
--                   Then draw it column by column where z = min(depth >> 6,
--                   65535) is below the wall z. u starts at
--                   ((x0 * 256 + 128 - left) * step) >> 8, v likewise from
--                   y0 and top; both advance by step (exact) and clamp to
--                   the frame size. Each column's clip list (nearest
--                   first) is scanned one entry per clock for the last
--                   entry with z <= sprite z; only rows in that window are
--                   drawn (rows above are skipped while v advances).
--                 Texels come from column-major art in SRAM (ART_BASE +
--                 frame offset + u * height + v) with several reads in
--                 flight. Pixel address and light ride a 16-word FIFO;
--                 texels other than 255 go through the light table into a
--                 16-word output FIFO. Reads issue only while in flight +
--                 pipeline + output FIFO < 12, so no FIFO overflows.
--                 Spans (actor index, x0, x1, z) of target sprites go into
--                 the bank the game is not reading; banks swap at frame end.
--                 One shared signed 32 x 25 multiplier (4 clocks per
--                 product) and one divider.
--                 Clock domain: clk_i (system). About 100 clocks per sprite
--                 plus about 4 per drawn texel (SRAM read and pixel write).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, render_pkg,
--                 render_types_pkg, game_pkg, game_tables_pkg, hw_pkg,
--                 divider, light_rom, sprite_fifo
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 2.00 - Sprite floor height, clip windows
-- Revision 2.01 - Plain signals instead of records; one-process state machine
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
	constant MUL_CLOCKS: natural := 3; -- Operands, product, register: the product is in m3 when mul_ret starts

	type sprite_state_type is (
		SPRITE_IDLE,
		SPRITE_TRIG, -- Read sin and cos of the view angle
		SPRITE_P1_READ, -- Pass 1: sprite table address on the bus
		SPRITE_P1_REL, -- rx, ry; multiply rx * cos
		SPRITE_P1_M2, -- multiply ry * sin
		SPRITE_P1_STORE, -- depth, culled flag
		SPRITE_SEL, -- Pass 2: scan for the farthest remaining sprite
		SPRITE_P2_READ, -- Its table entry
		SPRITE_P2_REL, -- rx, ry, frame size, light, z; divider; rx * -sin
		SPRITE_P2_LAT, -- ry * cos
		SPRITE_P2_LAT2, -- lateral
		SPRITE_P2_DIV, -- wait for lineHeight; lh * width
		SPRITE_P2_W, -- lh * height
		SPRITE_P2_H, -- lateral * lh
		SPRITE_P2_C, -- lh * (eye - floor)
		SPRITE_P2_E, -- depth * M_TS
		SPRITE_P2_S, -- left, top
		SPRITE_P2_EDGE, -- unclipped columns and rows
		SPRITE_P2_CLIP, -- clipping, span
		SPRITE_P2_DX, -- (x0 term) * step
		SPRITE_P2_U, -- (y0 term) * step
		SPRITE_P2_V, -- start drawing
		SPRITE_COL, -- wall z address of the column
		SPRITE_COLZ, -- depth test, clip count
		SPRITE_CLIPA, -- first clip entry address
		SPRITE_CLIPD, -- one clip entry per clock: window at the sprite's depth
		SPRITE_CSTART, -- column start: art column, first row, last row
		SPRITE_ROW, -- issue texel reads down the column
		SPRITE_FINISH, -- wait until every pixel has left
		SPRITE_MULW -- wait for a product, then go to mul_ret
	);

	type depth_array_type is array (0 to 31) of unsigned(25 downto 0);

	signal sprite_state: sprite_state_type := SPRITE_IDLE;
	signal mul_ret: sprite_state_type := SPRITE_IDLE; -- State after SPRITE_MULW
	signal mcnt: unsigned(1 downto 0) := (others => '0'); -- Clocks left in SPRITE_MULW

	-- Frame inputs, latched at start_i
	signal cam_x, cam_y: signed(23 downto 0) := (others => '0');
	signal angle: unsigned(9 downto 0) := (others => '0');
	signal eye: unsigned(6 downto 0) := (others => '0');
	signal buf: std_logic := '0';
	signal count: unsigned(5 downto 0) := (others => '0');
	signal cs, sn: signed(17 downto 0) := (others => '0');

	-- Pass 1 and the pass 2 scan
	signal k: unsigned(5 downto 0) := (others => '0'); -- Pass 1 index / pass 2 scan index
	signal depth: depth_array_type := (others => (others => '0'));
	signal live: std_logic_vector(31 downto 0) := (others => '0'); -- Not culled and not yet drawn
	signal best: unsigned(5 downto 0) := (others => '0');
	signal found: std_logic := '0';
	signal sel: unsigned(4 downto 0) := (others => '0');
	signal rx, ry: signed(23 downto 0) := (others => '0');
	signal pa: signed(56 downto 0) := (others => '0'); -- First product of a sum of two
	signal mul_a: signed(31 downto 0) := (others => '0');
	signal mul_b: signed(24 downto 0) := (others => '0');
	signal div_start: std_logic := '0';
	signal div_ok: std_logic := '0'; -- Divider finished since it was started

	-- Current sprite
	signal idx: unsigned(4 downto 0) := (others => '0');
	signal target: std_logic := '0';
	signal floor: unsigned(6 downto 0) := (others => '0'); -- Floor height under the sprite
	signal off: unsigned(17 downto 0) := (others => '0');
	signal fw, fh: unsigned(6 downto 0) := (others => '0');
	signal lvl: unsigned(3 downto 0) := (others => '0');
	signal z: unsigned(15 downto 0) := (others => '0');
	signal d: unsigned(25 downto 0) := (others => '0');
	signal lateral: signed(31 downto 0) := (others => '0');
	signal lh: unsigned(19 downto 0) := (others => '0');
	-- Screen edges in 1/256 pixels
	signal w_f, h_f: signed(31 downto 0) := (others => '0');
	signal center_f, bottom_f, left_f, top_f: signed(31 downto 0) := (others => '0');
	signal ex0, ex1, ey0, ey1: signed(31 downto 0) := (others => '0'); -- Unclipped first and last column and row
	signal step: unsigned(24 downto 0) := (others => '0');
	signal x, x1, y, y1: unsigned(8 downto 0) := (others => '0');
	signal y0: unsigned(8 downto 0) := (others => '0');
	signal u, v, vs: unsigned(49 downto 0) := (others => '0'); -- Texel coordinates, Q.16
	signal base: unsigned(18 downto 0) := (others => '0'); -- Art offset of the column
	signal wt, wb: unsigned(7 downto 0) := (others => '0'); -- Clip window of the column (wt > wb: closed)
	signal cj: unsigned(4 downto 0) := (others => '0'); -- Clip entry index on the read port
	signal ccnt: unsigned(4 downto 0) := (others => '0'); -- Clip entries of the column
	signal ylast: unsigned(8 downto 0) := (others => '0'); -- Last row drawn in the column
	signal paddr: unsigned(16 downto 0) := (others => '0');

	-- Spans and frame results
	signal span_we: std_logic := '0';
	signal span_n: unsigned(5 downto 0) := (others => '0');
	signal span_data: std_logic_vector(SPAN_BITS - 1 downto 0) := (others => '0');
	signal bank: std_logic := '0'; -- Bank the game reads
	signal span_last: unsigned(5 downto 0) := (others => '0');
	signal pixels: unsigned(15 downto 0) := (others => '0');
	signal pixels_last: unsigned(15 downto 0) := (others => '0');
	signal done: std_logic := '0';

	-- Combinational helpers of the state machine
	signal rel_x, rel_y: signed(23 downto 0); -- Table entry position minus camera, Q6.16
	signal sum16: signed(56 downto 0); -- (pa + product) >> 16: depth or lateral
	signal frame_no: natural range 0 to 60;
	signal sel_depth: unsigned(25 downto 0);
	signal light: signed(5 downto 0);
	signal lh_q: unsigned(19 downto 0);
	signal clip_x0, clip_x1, clip_y0, clip_y1: unsigned(8 downto 0);
	signal ylo, ylast_c: unsigned(8 downto 0);
	signal ucol, vrow: unsigned(6 downto 0);
	signal col_off: unsigned(13 downto 0);

	-- Multiplier pipeline
	signal m1_a: signed(31 downto 0) := (others => '0');
	signal m1_b: signed(24 downto 0) := (others => '0');
	signal m2, m3: signed(56 downto 0) := (others => '0');

	signal div_done: std_logic;
	signal div_quo: std_logic_vector(23 downto 0);
	signal div_num: std_logic_vector(32 downto 0);

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

	type span_ram_type is array (0 to 63) of std_logic_vector(SPAN_BITS - 1 downto 0);
	signal span_ram: span_ram_type := (others => (others => '0'));
	-- 64 x 48 bits would take a whole RAMB36; about 50 LUTs of distributed
	-- RAM keep the block within its 1-BRAM budget
	attribute ram_style: string;
	attribute ram_style of span_ram: signal is "distributed";
begin
	div_num <= '0' & std_logic_vector(N_LH);

	divide: divider
		generic map (
			NUM_BITS => 33,
			DEN_BITS => 26,
			QUO_BITS => 24
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			start_i => div_start,
			num_i => div_num,
			den_i => std_logic_vector(d),
			busy_o => open,
			done_o => div_done,
			quo_o => div_quo
		);

	-- Shared multiplier: operands registered, product, one more register
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			m1_a <= mul_a;
			m1_b <= mul_b;
			m2 <= m1_a * m1_b;
			m3 <= m2;
		end if;
	end process;

	------------------------------------------------------------------
	-- Combinational values the state machine uses
	------------------------------------------------------------------
	-- Sprite position is Q6.10; << 6 makes it Q6.16 like the camera
	rel_x <= signed(shift_left(resize(unsigned(spr_data_i(SPR_X_HI downto SPR_X_LO)), 24), 6)) - cam_x;
	rel_y <= signed(shift_left(resize(unsigned(spr_data_i(SPR_Y_HI downto SPR_Y_LO)), 24), 6)) - cam_y;
	sum16 <= shift_right(pa + m3, 16);
	-- Frame numbers past the table (60) fall back to frame 0
	frame_no <= to_integer(unsigned(spr_data_i(SPR_FRAME_HI downto SPR_FRAME_LO)))
		when (unsigned(spr_data_i(SPR_FRAME_HI downto SPR_FRAME_LO)) <= 60) else 0;
	sel_depth <= depth(to_integer(sel));
	-- Light: tile light minus min(15, depth >> 18) (15 once depth >= 2^22)
	light <= signed(resize(unsigned(spr_data_i(SPR_LIGHT_HI downto SPR_LIGHT_LO)), 6)) - 15
		when (sel_depth(25 downto 22) /= 0) else
		signed(resize(unsigned(spr_data_i(SPR_LIGHT_HI downto SPR_LIGHT_LO)), 6)) -
		signed(resize(sel_depth(21 downto 18), 6));
	-- lineHeight = min(quotient, LH_MAX)
	lh_q <= to_unsigned(LH_MAX, 20) when (unsigned(div_quo) > LH_MAX) else unsigned(div_quo(19 downto 0));
	-- Clipped first and last column and row
	clip_x0 <= (others => '0') when (ex0 < 0) else unsigned(ex0(8 downto 0));
	clip_x1 <= to_unsigned(SCREEN_W - 1, 9) when (ex1 > SCREEN_W - 1) else unsigned(ex1(8 downto 0));
	clip_y0 <= (others => '0') when (ey0 < 0) else unsigned(ey0(8 downto 0));
	clip_y1 <= to_unsigned(SCREEN_H - 1, 9) when (ey1 > SCREEN_H - 1) else unsigned(ey1(8 downto 0));
	-- Rows of a column: max(y0, wt) .. min(y1, wb)
	ylo <= y0 when (y0 > resize(wt, 9)) else resize(wt, 9);
	ylast_c <= resize(wb, 9) when (y1 > resize(wb, 9)) else y1;
	-- Art column = u >> 16 and row = v >> 16, clamped to the frame size
	ucol <= fw - 1 when (u(49 downto 16) >= resize(fw, 34)) else u(22 downto 16);
	col_off <= ucol * fh;
	vrow <= fh - 1 when (v(49 downto 16) >= resize(fh, 34)) else v(22 downto 16);
	-- Art address of the next texel: frame offset + column base + row
	art_addr <= to_unsigned(ART_BASE, 19) + base + resize(vrow, 19);

	-- Reads in flight + stages A and B + output FIFO words must stay below CREDITS
	credit_ok <= '1' when (resize(in_flight, 6) + ("00000" & a_valid) + ("00000" & b_valid) +
		resize(unsigned(out_level), 6) < CREDITS) else '0';
	in_win <= '1' when (y >= resize(wt, 9)) else '0';
	issue <= '1' when ((sprite_state = SPRITE_ROW) and (in_win = '1') and (credit_ok = '1') and (m_gnt_i = '1')) else '0';

	------------------------------------------------------------------
	-- State machine. A multiply loads mul_a, mul_b, mcnt and mul_ret and
	-- waits in SPRITE_MULW; the product is in m3 when mul_ret starts.
	-- A column ends by stepping x (and u), or after the last column by
	-- returning to SPRITE_SEL.
	------------------------------------------------------------------
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			sprite_state <= SPRITE_IDLE;
			mul_ret <= SPRITE_IDLE;
			mcnt <= (others => '0');
			cam_x <= (others => '0');
			cam_y <= (others => '0');
			angle <= (others => '0');
			eye <= (others => '0');
			buf <= '0';
			count <= (others => '0');
			cs <= (others => '0');
			sn <= (others => '0');
			k <= (others => '0');
			depth <= (others => (others => '0'));
			live <= (others => '0');
			best <= (others => '0');
			found <= '0';
			sel <= (others => '0');
			rx <= (others => '0');
			ry <= (others => '0');
			pa <= (others => '0');
			mul_a <= (others => '0');
			mul_b <= (others => '0');
			div_start <= '0';
			div_ok <= '0';
			idx <= (others => '0');
			target <= '0';
			floor <= (others => '0');
			off <= (others => '0');
			fw <= (others => '0');
			fh <= (others => '0');
			lvl <= (others => '0');
			z <= (others => '0');
			d <= (others => '0');
			lateral <= (others => '0');
			lh <= (others => '0');
			w_f <= (others => '0');
			h_f <= (others => '0');
			center_f <= (others => '0');
			bottom_f <= (others => '0');
			left_f <= (others => '0');
			top_f <= (others => '0');
			ex0 <= (others => '0');
			ex1 <= (others => '0');
			ey0 <= (others => '0');
			ey1 <= (others => '0');
			step <= (others => '0');
			x <= (others => '0');
			x1 <= (others => '0');
			y <= (others => '0');
			y1 <= (others => '0');
			y0 <= (others => '0');
			u <= (others => '0');
			v <= (others => '0');
			vs <= (others => '0');
			base <= (others => '0');
			wt <= (others => '0');
			wb <= (others => '0');
			cj <= (others => '0');
			ccnt <= (others => '0');
			ylast <= (others => '0');
			paddr <= (others => '0');
			span_we <= '0';
			span_n <= (others => '0');
			span_data <= (others => '0');
			bank <= '0';
			span_last <= (others => '0');
			pixels <= (others => '0');
			pixels_last <= (others => '0');
			done <= '0';
		elsif rising_edge(clk_i) then
			-- One-clock pulses
			div_start <= '0';
			span_we <= '0';
			done <= '0';
			if (div_done = '1') then
				div_ok <= '1';
			end if;

			case sprite_state is
				when SPRITE_IDLE =>
					if (start_i = '1') then
						cam_x <= signed(resize(unsigned(cam_x_i), 24));
						cam_y <= signed(resize(unsigned(cam_y_i), 24));
						angle <= unsigned(angle_i);
						eye <= unsigned(eye_i);
						buf <= buf_i;
						count <= unsigned(spr_count_i);
						k <= (others => '0');
						live <= (others => '0');
						span_n <= (others => '0');
						pixels <= (others => '0');
						sprite_state <= SPRITE_TRIG;
					end if;

				when SPRITE_TRIG =>
					sn <= to_signed(SIN_TABLE(to_integer(angle)), 18);
					cs <= to_signed(SIN_TABLE(to_integer(angle + 256)), 18); -- cos = sin(angle + 1/4 turn)
					if (count = 0) then
						sprite_state <= SPRITE_FINISH;
					else
						sprite_state <= SPRITE_P1_READ;
					end if;

				-- Pass 1: depth of every entry -------------------------------------
				when SPRITE_P1_READ =>
					sprite_state <= SPRITE_P1_REL;

				when SPRITE_P1_REL =>
					rx <= rel_x;
					ry <= rel_y;
					mul_a <= resize(rel_x, 32);
					mul_b <= resize(cs, 25);
					mcnt <= to_unsigned(MUL_CLOCKS, 2);
					mul_ret <= SPRITE_P1_M2;
					sprite_state <= SPRITE_MULW;

				when SPRITE_P1_M2 =>
					pa <= m3;
					mul_a <= resize(ry, 32);
					mul_b <= resize(sn, 25);
					mcnt <= to_unsigned(MUL_CLOCKS, 2);
					mul_ret <= SPRITE_P1_STORE;
					sprite_state <= SPRITE_MULW;

				when SPRITE_P1_STORE =>
					depth(to_integer(k(4 downto 0))) <= unsigned(sum16(25 downto 0));
					if (sum16 >= DEPTH_MIN) then
						live(to_integer(k(4 downto 0))) <= '1';
					end if;
					if (k + 1 = count) then
						k <= (others => '0');
						found <= '0';
						sprite_state <= SPRITE_SEL;
					else
						k <= k + 1;
						sprite_state <= SPRITE_P1_READ;
					end if;

				-- Pass 2: farthest live sprite first ---------------------------------
				when SPRITE_SEL =>
					if (k = count) then
						if (found = '1') then
							sel <= best(4 downto 0);
							live(to_integer(best(4 downto 0))) <= '0';
							sprite_state <= SPRITE_P2_READ;
						else
							sprite_state <= SPRITE_FINISH;
						end if;
					else
						if (live(to_integer(k(4 downto 0))) = '1') then
							if ((found = '0') or
								(depth(to_integer(k(4 downto 0))) > depth(to_integer(best(4 downto 0))))) then
								best <= k;
								found <= '1';
							end if;
						end if;
						k <= k + 1;
					end if;

				when SPRITE_P2_READ =>
					sprite_state <= SPRITE_P2_REL;

				when SPRITE_P2_REL =>
					rx <= rel_x;
					ry <= rel_y;
					idx <= unsigned(spr_data_i(SPR_IDX_HI downto SPR_IDX_LO));
					target <= spr_data_i(SPR_TARGET);
					floor <= unsigned(spr_data_i(SPR_FLOOR_HI downto SPR_FLOOR_LO));
					off <= to_unsigned(FRAME_TABLE(frame_no)(0), 18);
					fw <= to_unsigned(FRAME_TABLE(frame_no)(1), 7);
					fh <= to_unsigned(FRAME_TABLE(frame_no)(2), 7);
					d <= sel_depth;
					-- Light level: fullbright, or the distance-dimmed tile light, at least 0
					if (spr_data_i(SPR_BRIGHT) = '1') then
						lvl <= to_unsigned(15, 4);
					elsif (light < 0) then
						lvl <= (others => '0');
					else
						lvl <= unsigned(light(3 downto 0));
					end if;
					-- z = min(depth >> 6, 65535)
					if (sel_depth(25 downto 22) /= 0) then
						z <= (others => '1');
					else
						z <= sel_depth(21 downto 6);
					end if;
					div_start <= '1';
					div_ok <= '0';
					mul_a <= resize(rel_x, 32);
					mul_b <= resize(-resize(sn, 19), 25);
					mcnt <= to_unsigned(MUL_CLOCKS, 2);
					mul_ret <= SPRITE_P2_LAT;
					sprite_state <= SPRITE_MULW;

				when SPRITE_P2_LAT =>
					pa <= m3;
					mul_a <= resize(ry, 32);
					mul_b <= resize(cs, 25);
					mcnt <= to_unsigned(MUL_CLOCKS, 2);
					mul_ret <= SPRITE_P2_LAT2;
					sprite_state <= SPRITE_MULW;

				when SPRITE_P2_LAT2 =>
					lateral <= sum16(31 downto 0);
					sprite_state <= SPRITE_P2_DIV;

				when SPRITE_P2_DIV =>
					if (div_ok = '1') then
						lh <= lh_q;
						mul_a <= resize(signed('0' & lh_q), 32);
						mul_b <= resize(signed('0' & fw), 25);
						mcnt <= to_unsigned(MUL_CLOCKS, 2);
						mul_ret <= SPRITE_P2_W;
						sprite_state <= SPRITE_MULW;
					end if;

				when SPRITE_P2_W =>
					w_f <= shift_right(m3, 6)(31 downto 0);
					mul_a <= resize(signed('0' & lh), 32);
					mul_b <= resize(signed('0' & fh), 25);
					mcnt <= to_unsigned(MUL_CLOCKS, 2);
					mul_ret <= SPRITE_P2_H;
					sprite_state <= SPRITE_MULW;

				when SPRITE_P2_H =>
					h_f <= shift_right(m3, 6)(31 downto 0);
					mul_a <= lateral;
					mul_b <= resize(signed('0' & lh), 25);
					mcnt <= to_unsigned(MUL_CLOCKS, 2);
					mul_ret <= SPRITE_P2_C;
					sprite_state <= SPRITE_MULW;

				when SPRITE_P2_C =>
					center_f <= 40960 + shift_right(m3, 16)(31 downto 0); -- 40960 = 160 * 256, screen center x
					-- lh * (eye - floor); eye - floor may be negative
					mul_a <= resize(signed('0' & lh), 32);
					mul_b <= resize(signed(resize(eye, 9)) - signed(resize(floor, 9)), 25);
					mcnt <= to_unsigned(MUL_CLOCKS, 2);
					mul_ret <= SPRITE_P2_E;
					sprite_state <= SPRITE_MULW;

				when SPRITE_P2_E =>
					bottom_f <= 30720 + shift_right(m3, 6)(31 downto 0); -- 30720 = 120 * 256, horizon row
					mul_a <= resize(signed('0' & d), 32);
					mul_b <= to_signed(M_TS, 25);
					mcnt <= to_unsigned(MUL_CLOCKS, 2);
					mul_ret <= SPRITE_P2_S;
					sprite_state <= SPRITE_MULW;

				when SPRITE_P2_S =>
					step <= unsigned(shift_right(m3, 16)(24 downto 0));
					left_f <= center_f - shift_right(w_f, 1);
					top_f <= bottom_f - h_f;
					sprite_state <= SPRITE_P2_EDGE;

				when SPRITE_P2_EDGE =>
					-- Pixel-center rule: first pixel with center (p * 256 + 128) >= e
					-- is (e + 127) >> 8; the last one before e is (e - 129) >> 8
					ex0 <= shift_right(left_f + 127, 8);
					ex1 <= shift_right(left_f + w_f - 129, 8);
					ey0 <= shift_right(top_f + 127, 8);
					ey1 <= shift_right(bottom_f - 129, 8);
					sprite_state <= SPRITE_P2_CLIP;

				when SPRITE_P2_CLIP =>
					-- Off-screen test on the unclipped edges, in parallel with the clamps
					if ((ex0 > ex1) or (ex0 > SCREEN_W - 1) or (ex1 < 0) or
						(ey0 > ey1) or (ey0 > SCREEN_H - 1) or (ey1 < 0)) then
						-- Off screen: next sprite
						k <= (others => '0');
						found <= '0';
						sprite_state <= SPRITE_SEL;
					else
						x <= clip_x0;
						x1 <= clip_x1;
						y0 <= clip_y0;
						y1 <= clip_y1;
						if (target = '1') then
							span_we <= '1';
							span_data <= (others => '0');
							span_data(SPAN_IDX_HI downto SPAN_IDX_LO) <= std_logic_vector(idx);
							span_data(SPAN_X0_HI downto SPAN_X0_LO) <= std_logic_vector(clip_x0);
							span_data(SPAN_X1_HI downto SPAN_X1_LO) <= std_logic_vector(clip_x1);
							span_data(SPAN_Z_HI downto SPAN_Z_LO) <= std_logic_vector(z);
						end if;
						sprite_state <= SPRITE_P2_DX;
					end if;

				when SPRITE_P2_DX =>
					-- Center of pixel x0 minus the left edge, in 1/256 pixels, times step
					mul_a <= shift_left(resize(signed('0' & x), 32), 8) + 128 - left_f;
					mul_b <= signed('0' & step(23 downto 0));
					mcnt <= to_unsigned(MUL_CLOCKS, 2);
					mul_ret <= SPRITE_P2_U;
					sprite_state <= SPRITE_MULW;

				when SPRITE_P2_U =>
					u <= unsigned(shift_right(m3, 8)(49 downto 0));
					mul_a <= shift_left(resize(signed('0' & y0), 32), 8) + 128 - top_f;
					mul_b <= signed('0' & step(23 downto 0));
					mcnt <= to_unsigned(MUL_CLOCKS, 2);
					mul_ret <= SPRITE_P2_V;
					sprite_state <= SPRITE_MULW;

				when SPRITE_P2_V =>
					vs <= unsigned(shift_right(m3, 8)(49 downto 0));
					sprite_state <= SPRITE_COL;

				-- Drawing -------------------------------------------------------------
				when SPRITE_COL =>
					sprite_state <= SPRITE_COLZ;

				when SPRITE_COLZ =>
					-- Wall z and the clip count of column x are on the read ports
					if (z >= unsigned(zwall_data_i)) then
						-- Hidden by the wall: end of the column
						if (x = x1) then
							k <= (others => '0');
							found <= '0';
							sprite_state <= SPRITE_SEL;
						else
							x <= x + 1;
							u <= u + resize(step, 50);
							sprite_state <= SPRITE_COL;
						end if;
					else
						wt <= (others => '0');
						wb <= to_unsigned(SCREEN_H - 1, 8);
						ccnt <= unsigned(ccount_data_i);
						cj <= (others => '0');
						if (unsigned(ccount_data_i) = 0) then
							sprite_state <= SPRITE_CSTART;
						else
							sprite_state <= SPRITE_CLIPA;
						end if;
					end if;

				when SPRITE_CLIPA =>
					-- Entry 0 is addressed now; from here the port runs one entry ahead
					cj <= cj + 1;
					sprite_state <= SPRITE_CLIPD;

				when SPRITE_CLIPD =>
					-- clip_data_i is entry cj - 1: the window is that of the last entry
					-- with entry z <= sprite z (tools/model/sprites.py window())
					if (unsigned(clip_data_i(CLIP_Z_HI downto CLIP_Z_LO)) <= z) then
						wt <= unsigned(clip_data_i(CLIP_TOP_HI downto CLIP_TOP_LO));
						wb <= unsigned(clip_data_i(CLIP_BOT_HI downto CLIP_BOT_LO));
						if (cj = ccnt) then
							sprite_state <= SPRITE_CSTART;
						else
							cj <= cj + 1;
						end if;
					else
						sprite_state <= SPRITE_CSTART;
					end if;

				when SPRITE_CSTART =>
					-- Rows y0 .. min(y1, wb); rows above wt are skipped in SPRITE_ROW
					ylast <= ylast_c;
					if ((wt > wb) or (ylo > ylast_c)) then
						-- Nothing of this column is open at the sprite's depth: end of the column
						if (x = x1) then
							k <= (others => '0');
							found <= '0';
							sprite_state <= SPRITE_SEL;
						else
							x <= x + 1;
							u <= u + resize(step, 50);
							sprite_state <= SPRITE_COL;
						end if;
					else
						base <= resize(off, 19) + resize(col_off, 19);
						y <= y0;
						v <= vs;
						-- Pixel address y0 * 320 + x = (y0 << 8) + (y0 << 6) + x
						paddr <= shift_left(resize(y0, 17), 8) + shift_left(resize(y0, 17), 6) +
							resize(x, 17);
						sprite_state <= SPRITE_ROW;
					end if;

				when SPRITE_ROW =>
					-- Rows in the window advance when their read issues; rows above it
					-- advance at once (no read, v still steps)
					if ((issue = '1') or (in_win = '0')) then
						v <= v + resize(step, 50);
						paddr <= paddr + 320;
						if (y = ylast) then
							-- End of the column
							if (x = x1) then
								k <= (others => '0');
								found <= '0';
								sprite_state <= SPRITE_SEL;
							else
								x <= x + 1;
								u <= u + resize(step, 50);
								sprite_state <= SPRITE_COL;
							end if;
						else
							y <= y + 1;
						end if;
					end if;

				when SPRITE_FINISH =>
					if ((in_flight = 0) and (a_valid = '0') and (b_valid = '0') and (out_empty = '1')) then
						bank <= not bank;
						span_last <= span_n;
						pixels_last <= pixels;
						done <= '1';
						sprite_state <= SPRITE_IDLE;
					end if;

				when SPRITE_MULW =>
					if (mcnt = 1) then
						sprite_state <= mul_ret;
					else
						mcnt <= mcnt - 1;
					end if;

				when others =>
					null;
			end case;

			-- Side counters; assigned last, so they win over the SPRITE_IDLE clears
			if (span_we = '1') then
				span_n <= span_n + 1;
			end if;
			if ((b_valid = '1') and (pixels /= x"FFFF")) then
				pixels <= pixels + 1;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Spans: written into the bank the game is not reading
	------------------------------------------------------------------
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (span_we = '1') then
				span_ram(to_integer((not bank) & span_n(4 downto 0))) <= span_data;
			end if;
			span_rdata_o <= span_ram(to_integer(bank & unsigned(span_raddr_i)));
		end if;
	end process;

	------------------------------------------------------------------
	-- Texel reads and their return path
	------------------------------------------------------------------
	coord_din <= std_logic_vector(lvl) & std_logic_vector(paddr);

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

	out_din <= buf & b_addr & light_data;
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
	spr_addr_o <= std_logic_vector(sel) when ((sprite_state = SPRITE_P2_READ) or (sprite_state = SPRITE_P2_REL)) else
		std_logic_vector(k(4 downto 0));
	zwall_addr_o <= std_logic_vector(x);
	ccount_addr_o <= std_logic_vector(x);
	clip_addr_o <= std_logic_vector(x) & std_logic_vector(cj(3 downto 0)); -- Column x, entry cj
	m_req_o <= '1' when ((sprite_state = SPRITE_ROW) and (in_win = '1') and (credit_ok = '1')) else '0';
	m_addr_o <= std_logic_vector(art_addr);
	pix_valid_o <= not out_empty;
	pix_data_o <= out_dout;
	span_count_o <= std_logic_vector(span_last);
	busy_o <= '0' when (sprite_state = SPRITE_IDLE) else '1';
	done_o <= done;
	pixels_o <= std_logic_vector(pixels_last);
end arch;

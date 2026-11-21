--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Column Rasterizer
-- Module Name:    column_rasterizer
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Draws every column's spans through the pixel write port.
--                 Bit exact with raster_spans() and row_dist() in
--                 tools/model/render.py.
--                 A span (DESC_*) is rows y0..y1 of one column and kind;
--                 a column's spans come in any order, cover each row once,
--                 and the last has DESC_LAST.
--                 Per pixel:
--                   textured (walls, risers, upper walls): texel =
--                     WALL[slot][tex_col][min(v >> 16, 63)], slot = (tex_id
--                     - 1) mod 8, slime (6) cycles slots 5, 8, 9, 10 with
--                     the animation frame; v += tex_step per row; color =
--                     LIGHT[span light][texel] (light type already applied)
--                   floor/ceiling: rd = min(DD_MAX, (E * RINV(y)) >> 8),
--                     E = eye distance from the span; w = pos + ((rd * ray)
--                     >> 16) per axis (Q6.16 mod 2^22); tile =
--                     map[wy(21:16)][wx(21:16)]; u = wx(15:10), v =
--                     wy(15:10); flat = floor_tex, or ceil_tex (0 on a ramp
--                     tile); light = max(0, clamp(tile light + lmod(type),
--                     0, 15) - min(15, rd >> 18)), lmod from fx_i
--                   sky: ceiling pixel over an open tile with bit 23 set:
--                     SKY[u][v], u = ((angle + SKYX(col)) >> 1) mod 256,
--                     v = min(63, (y * 17) >> 5), unlit
--                 Pipeline (fixed latency, never stalls; S0 = issue):
--                   S0  wall and RINV ROM addresses
--                   S1  texel, RINV(y), SKYX(col) and sky row arrive
--                   S2  E * RINV (7 x 27)
--                   S3  rd = min(DD_MAX, product >> 8)
--                   S4  DSP operand registers; distance light term
--                   S5  rd * rx, rd * ry (25 x 18 signed)
--                   S6  world point; map address out
--                   S7  tile word: flat ROM address; tile fields registered
--                   S8  flat texel; light offset, clamp, distance
--                   S9  light and sky ROM addresses
--                   S10 palette index into the output FIFO
--                 Back-pressure: credits for the 15-word output FIFO (minus
--                 one per issue, plus one per accepted pixel), so the
--                 pipeline never stalls. Frame done when all credits are
--                 back after column 319.
--                 Clock domain: clk_i (system). Throughput one pixel per
--                 clock plus one per span; the SRAM limits it to one per 2.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, render_pkg,
--                 render_types_pkg, game_pkg, wall_rom, anim_rom, flat_rom,
--                 light_rom, sky_rom, sync_fifo
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 2.10 - Effects: light types, sky, animated slime (2.00:
--                 spans for heights and ramps; per-row reciprocal ROM instead
--                 of the per-frame divider table)
-- Revision 2.20 - Plain signals instead of records; one-process state machine
-- Additional Comments:
--                 start_i is only taken while idle. Spans must have
--                 y0 <= y1; the frame ends after 320 LAST spans.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.render_pkg.all;
use work.render_types_pkg.all;
use work.game_pkg.all;

entity column_rasterizer is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		start_i: in std_logic; -- Pulse at frame start; inputs below stable until done_o
		pos_x_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Camera x, Q6.16
		pos_y_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Camera y, Q6.16
		angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0); -- View angle (sky)
		fx_i: in std_logic_vector(FX_BITS - 1 downto 0); -- Light type offsets, animation frame
		buf_i: in std_logic; -- Framebuffer to draw
		desc_valid_i: in std_logic; -- Span descriptor port
		desc_ready_o: out std_logic;
		desc_i: in std_logic_vector(DESC_BITS - 1 downto 0);
		map_addr_o: out std_logic_vector(11 downto 0); -- Tile map, y * 64 + x
		map_data_i: in std_logic_vector(23 downto 0); -- Tile word, 1 clock after the address
		pix_valid_o: out std_logic; -- Pixel write port
		pix_ready_i: in std_logic;
		pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0); -- buf, y * 320 + x, index
		busy_o: out std_logic; -- Frame in progress
		done_o: out std_logic -- Pulse: every pixel of the frame accepted
	);
end column_rasterizer;

architecture arch of column_rasterizer is
	component wall_rom is
		port(
			clk_i: in std_logic;
			addr_i: in std_logic_vector(14 downto 0);
			data_o: out std_logic_vector(7 downto 0)
		);
	end component;
	component anim_rom is
		port(
			clk_i: in std_logic;
			addr_i: in std_logic_vector(13 downto 0);
			data_o: out std_logic_vector(7 downto 0)
		);
	end component;
	component sky_rom is
		port(
			clk_i: in std_logic;
			addr_i: in std_logic_vector(13 downto 0);
			data_o: out std_logic_vector(7 downto 0)
		);
	end component;
	component flat_rom is
		port(
			clk_i: in std_logic;
			addr_i: in std_logic_vector(13 downto 0);
			data_o: out std_logic_vector(7 downto 0)
		);
	end component;
	component light_rom is
		port(
			clk_i: in std_logic;
			addr_i: in std_logic_vector(11 downto 0);
			data_o: out std_logic_vector(7 downto 0)
		);
	end component;
	component sync_fifo is
		generic(
			WIDTH: positive := 8;
			DEPTH_BITS: positive := 9
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			in_valid_i: in std_logic;
			in_ready_o: out std_logic;
			in_data_i: in std_logic_vector(WIDTH - 1 downto 0);
			out_valid_o: out std_logic;
			out_ready_i: in std_logic;
			out_data_o: out std_logic_vector(WIDTH - 1 downto 0);
			level_o: out std_logic_vector(DEPTH_BITS - 1 downto 0)
		);
	end component;

	constant FIFO_BITS: natural := 4;
	constant CREDITS: natural := 2 ** FIFO_BITS - 1; -- Output FIFO capacity (latency is 9)

	------------------------------------------------------------------
	-- Control (one-process FSM)
	------------------------------------------------------------------
	-- RAS_WAIT_DESC: take the next span; RAS_SPAN: issue its rows;
	-- RAS_DRAIN: every span issued, wait until every credit is back
	type ras_state_type is (RAS_IDLE, RAS_WAIT_DESC, RAS_SPAN, RAS_DRAIN);
	signal ras_state: ras_state_type := RAS_IDLE;
	-- Frame inputs, latched at start_i
	signal px: unsigned(POS_BITS - 1 downto 0) := (others => '0');
	signal py: unsigned(POS_BITS - 1 downto 0) := (others => '0');
	signal angle: unsigned(ANGLE_BITS - 1 downto 0) := (others => '0');
	signal fx: std_logic_vector(FX_BITS - 1 downto 0) := (others => '0');
	signal buf: std_logic := '0';
	-- Current span
	signal col: unsigned(8 downto 0) := (others => '0');
	signal y1: unsigned(7 downto 0) := (others => '0');
	signal wall: std_logic := '0'; -- Textured span
	signal ceil: std_logic := '0'; -- Ceiling span
	signal last: std_logic := '0'; -- Last span of the column
	signal e: unsigned(6 downto 0) := (others => '0'); -- Eye distance of a floor or ceiling span
	signal slot: unsigned(3 downto 0) := (others => '0'); -- Wall ROM slot (render.wall_texture_index)
	signal tcol: unsigned(5 downto 0) := (others => '0');
	signal tex_v: unsigned(31 downto 0) := (others => '0'); -- Texture row accumulator, Q16.16
	signal tex_step: unsigned(23 downto 0) := (others => '0');
	signal wlight: unsigned(3 downto 0) := (others => '0');
	signal rx: signed(17 downto 0) := (others => '0');
	signal ry: signed(17 downto 0) := (others => '0');
	signal y: unsigned(7 downto 0) := (others => '0'); -- Next row to issue
	signal row_base: unsigned(16 downto 0) := (others => '0'); -- y * 320
	signal cols: natural range 0 to SCREEN_W := 0; -- Columns fully issued
	signal credit: natural range 0 to CREDITS := CREDITS;
	signal done: std_logic := '0';

	-- Fields of the waiting descriptor
	signal desc_tex: unsigned(3 downto 0); -- Texture id
	signal desc_tex_m1: unsigned(3 downto 0); -- id - 1
	signal desc_y0: unsigned(7 downto 0);
	signal anim_slot: unsigned(3 downto 0); -- Slime slot of this animation frame
	signal desc_slot: unsigned(3 downto 0);

	-- Issue (S0)
	signal issue: std_logic;
	signal pop: std_logic;
	signal trow: unsigned(5 downto 0);
	-- Slots 0..7 in wall_rom, 8..10 in anim_rom (one 11-slot ROM took 16 BRAM36);
	-- anim1 picks the ROM at S1
	signal wall_addr: std_logic_vector(14 downto 0);
	signal anim_addr: std_logic_vector(13 downto 0);
	signal wall_q, anim_q: std_logic_vector(7 downto 0);
	signal anim1: std_logic := '0';
	signal rinv_q: unsigned(26 downto 0) := (others => '0'); -- RINV(y), S1

	-- Pipeline registers (no reset on the datapath, only on the valid bits)
	signal v1, v2, v3, v4, v5, v6, v7, v8, v9, v10: std_logic := '0';
	signal wall1, wall2, wall3, wall4, wall5, wall6, wall7, wall8, wall9: std_logic;
	signal ceil1, ceil2, ceil3, ceil4, ceil5, ceil6, ceil7: std_logic;
	signal addr1, addr2, addr3, addr4, addr5, addr6, addr7, addr8, addr9, addr10: unsigned(16 downto 0);
	-- Sky: SKYX(col) and the sky row at S1, then the ROM address carried to S9
	signal y17: unsigned(12 downto 0); -- y * 17 (S0)
	signal skyx1: signed(10 downto 0);
	signal skyv1: unsigned(5 downto 0);
	signal sky_u1: signed(11 downto 0); -- angle + SKYX (S1)
	signal skya2, skya3, skya4, skya5, skya6, skya7, skya8, skya9: std_logic_vector(13 downto 0);
	signal sky8, sky9, sky10: std_logic; -- The pixel is sky
	signal sky_q: std_logic_vector(7 downto 0);
	-- Tile light and light type at S8, then the final light and flat texel at S9
	signal tl8: unsigned(3 downto 0);
	signal ty8: unsigned(1 downto 0);
	signal dt8: unsigned(3 downto 0);
	signal lmod8: signed(5 downto 0); -- Light offset of the tile's light type
	signal lsum8: signed(5 downto 0); -- Tile light + offset ...
	signal lclamp8: signed(5 downto 0); -- ... clamped to 0..15 ...
	signal ldist8: signed(5 downto 0); -- ... minus the distance term
	signal fl9: unsigned(3 downto 0);
	signal ft9: std_logic_vector(7 downto 0);
	signal wl9: unsigned(3 downto 0);
	signal wt9: std_logic_vector(7 downto 0);
	signal e1: unsigned(6 downto 0);
	signal rx1, ry1, rx2, ry2, rx3, ry3: signed(17 downto 0);
	signal wl1, wl2, wl3, wl4, wl5, wl6, wl7, wl8: unsigned(3 downto 0); -- Wall light
	signal wt2, wt3, wt4, wt5, wt6, wt7, wt8: std_logic_vector(7 downto 0); -- Wall texel
	signal prod2: unsigned(33 downto 0); -- E * RINV(y)
	signal rd3: unsigned(23 downto 0); -- rowDist, Q8.16
	signal dt4, dt5, dt6, dt7: unsigned(3 downto 0); -- min(15, rd >> 18)
	signal m_rd: signed(24 downto 0);
	signal m_rx, m_ry: signed(17 downto 0);
	signal prod_x, prod_y: signed(42 downto 0);
	signal wx6, wy6: unsigned(POS_BITS - 1 downto 0);
	signal u7, vv7: unsigned(5 downto 0);
	signal flat_sel: std_logic_vector(1 downto 0);
	signal flat_addr: std_logic_vector(13 downto 0);
	signal flat_q: std_logic_vector(7 downto 0);
	signal light_addr: std_logic_vector(11 downto 0);
	signal light_q: std_logic_vector(7 downto 0);

	-- Output FIFO
	signal fifo_in: std_logic_vector(PIXW_BITS - 1 downto 0);
	signal fifo_valid: std_logic;
begin
	------------------------------------------------------------------
	-- Control
	------------------------------------------------------------------
	issue <= '1' when ((ras_state = RAS_SPAN) and (credit /= 0)) else '0';
	pop <= fifo_valid and pix_ready_i;

	-- Descriptor fields; slime (texture 6) cycles through slots 5, 8, 9, 10,
	-- every other texture uses slot (id - 1) mod 8
	desc_tex <= unsigned(desc_i(DESC_TEX_HI downto DESC_TEX_LO));
	desc_tex_m1 <= desc_tex - 1;
	desc_y0 <= unsigned(desc_i(DESC_Y0_HI downto DESC_Y0_LO));
	with fx(FX_ANIM_HI downto FX_ANIM_LO) select
		anim_slot <= to_unsigned(5, 4) when "00",
			to_unsigned(8, 4) when "01",
			to_unsigned(9, 4) when "10",
			to_unsigned(10, 4) when others;
	desc_slot <= anim_slot when (desc_tex = 6) else '0' & desc_tex_m1(2 downto 0);

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			ras_state <= RAS_IDLE;
			px <= (others => '0');
			py <= (others => '0');
			angle <= (others => '0');
			fx <= (others => '0');
			buf <= '0';
			col <= (others => '0');
			y1 <= (others => '0');
			wall <= '0';
			ceil <= '0';
			last <= '0';
			e <= (others => '0');
			slot <= (others => '0');
			tcol <= (others => '0');
			tex_v <= (others => '0');
			tex_step <= (others => '0');
			wlight <= (others => '0');
			rx <= (others => '0');
			ry <= (others => '0');
			y <= (others => '0');
			row_base <= (others => '0');
			cols <= 0;
			credit <= CREDITS;
			done <= '0';
		elsif rising_edge(clk_i) then
			done <= '0';
			-- Credits: one reserved per issue, one returned per accepted pixel
			-- (RAS_IDLE overrides this with a full count at start_i)
			if ((issue = '1') and (pop = '0')) then
				credit <= credit - 1;
			elsif ((issue = '0') and (pop = '1')) then
				credit <= credit + 1;
			end if;

			case ras_state is
				when RAS_IDLE =>
					if (start_i = '1') then
						px <= unsigned(pos_x_i);
						py <= unsigned(pos_y_i);
						angle <= unsigned(angle_i);
						fx <= fx_i;
						buf <= buf_i;
						cols <= 0;
						credit <= CREDITS;
						ras_state <= RAS_WAIT_DESC;
					end if;

				when RAS_WAIT_DESC =>
					if (desc_valid_i = '1') then
						col <= unsigned(desc_i(DESC_COL_HI downto DESC_COL_LO));
						y1 <= unsigned(desc_i(DESC_Y1_HI downto DESC_Y1_LO));
						if (desc_i(DESC_KIND_HI downto DESC_KIND_LO) = KIND_WALL) then
							wall <= '1';
							ceil <= '0';
						elsif (desc_i(DESC_KIND_HI downto DESC_KIND_LO) = KIND_CEIL) then
							wall <= '0';
							ceil <= '1';
						else
							wall <= '0';
							ceil <= '0';
						end if;
						last <= desc_i(DESC_LAST);
						e <= unsigned(desc_i(DESC_E_HI downto DESC_E_LO));
						slot <= desc_slot;
						tcol <= unsigned(desc_i(DESC_TCOL_HI downto DESC_TCOL_LO));
						tex_v <= resize(unsigned(desc_i(DESC_V0_HI downto DESC_V0_LO)), 32);
						tex_step <= unsigned(desc_i(DESC_STEP_HI downto DESC_STEP_LO));
						wlight <= unsigned(desc_i(DESC_LIGHT_HI downto DESC_LIGHT_LO));
						rx <= signed(desc_i(DESC_RX_HI downto DESC_RX_LO));
						ry <= signed(desc_i(DESC_RY_HI downto DESC_RY_LO));
						y <= desc_y0;
						-- y0 * 320 = (y0 << 8) + (y0 << 6)
						row_base <= shift_left(resize(desc_y0, 17), 8) + shift_left(resize(desc_y0, 17), 6);
						ras_state <= RAS_SPAN;
					end if;

				when RAS_SPAN =>
					if (issue = '1') then
						if (wall = '1') then
							tex_v <= tex_v + tex_step;
						end if;
						if (y = y1) then
							-- Span done: the next one, or the drain after column 319
							if ((last = '1') and (cols = SCREEN_W - 1)) then
								ras_state <= RAS_DRAIN;
							else
								ras_state <= RAS_WAIT_DESC;
							end if;
							if (last = '1') then
								cols <= cols + 1;
							end if;
						else
							y <= y + 1;
							row_base <= row_base + SCREEN_W;
						end if;
					end if;

				when RAS_DRAIN =>
					-- Every credit back: no pixel left in the pipeline or the FIFO
					if (credit = CREDITS) then
						done <= '1';
						ras_state <= RAS_IDLE;
					end if;

				when others =>
					null;
			end case;
		end if;
	end process;

	desc_ready_o <= '1' when (ras_state = RAS_WAIT_DESC) else '0';
	busy_o <= '0' when (ras_state = RAS_IDLE) else '1';
	done_o <= done;

	------------------------------------------------------------------
	-- S0: wall ROM address, texture row = min(v >> 16, 63); RINV ROM
	------------------------------------------------------------------
	-- Any bit above 21 set means v >> 16 >= 64: clamp the row to 63
	trow <= (others => '1') when (tex_v(31 downto 22) /= 0) else tex_v(21 downto 16);
	wall_addr <= std_logic_vector(unsigned'(slot(2 downto 0) & tcol & trow));
	-- Animation ROM (12,288 entries) only for slots 8..10; others read address 0, unused
	anim_addr <= std_logic_vector(unsigned'(slot(1 downto 0) & tcol & trow)) when (slot(3) = '1') else
		(others => '0');

	walls: wall_rom
		port map (
			clk_i => clk_i,
			addr_i => wall_addr,
			data_o => wall_q
		);

	frames: anim_rom
		port map (
			clk_i => clk_i,
			addr_i => anim_addr,
			data_o => anim_q
		);

	-- S0 -> S1: RINV(y); SKYX(col) and the sky row min(63, (y * 17) >> 5)
	y17 <= shift_left(resize(y, 13), 4) + resize(y, 13); -- y * 17 = (y << 4) + y

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			rinv_q <= to_unsigned(RINV_TABLE(to_integer(y)), 27);
			anim1 <= slot(3);
			skyx1 <= to_signed(SKYX_TABLE(to_integer(col)), 11);
			if (y17(12 downto 5) > 63) then
				skyv1 <= (others => '1');
			else
				skyv1 <= y17(10 downto 5);
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Pipeline S1 .. S10
	------------------------------------------------------------------
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			v1 <= '0';
			v2 <= '0';
			v3 <= '0';
			v4 <= '0';
			v5 <= '0';
			v6 <= '0';
			v7 <= '0';
			v8 <= '0';
			v9 <= '0';
			v10 <= '0';
		elsif rising_edge(clk_i) then
			v1 <= issue;
			v2 <= v1;
			v3 <= v2;
			v4 <= v3;
			v5 <= v4;
			v6 <= v5;
			v7 <= v6;
			v8 <= v7;
			v9 <= v8;
			v10 <= v9;
		end if;
	end process;

	-- S1: sky column u = ((angle + SKYX) >> 1) mod 256 = bits 8:1 of this sum
	sky_u1 <= signed(resize(angle, 12)) + resize(skyx1, 12);

	-- S8: light = clamp(tile light + lmod(type), 0, 15) - distance term;
	-- fx holds a signed 5-bit offset per light type
	with ty8 select
		lmod8 <= resize(signed(fx(4 downto 0)), 6) when "00",
			resize(signed(fx(9 downto 5)), 6) when "01",
			resize(signed(fx(14 downto 10)), 6) when "10",
			resize(signed(fx(19 downto 15)), 6) when others;
	lsum8 <= signed(resize(tl8, 6)) + lmod8;
	lclamp8 <= to_signed(0, 6) when (lsum8 < 0) else
		to_signed(15, 6) when (lsum8 > 15) else
		lsum8;
	ldist8 <= lclamp8 - signed(resize(dt8, 6));

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			-- S0 -> S1
			wall1 <= wall;
			ceil1 <= ceil;
			e1 <= e;
			addr1 <= row_base + col;
			rx1 <= rx;
			ry1 <= ry;
			wl1 <= wlight;

			-- S1 -> S2: wall texel and RINV(y) have arrived; E * RINV; sky column
			wall2 <= wall1;
			ceil2 <= ceil1;
			addr2 <= addr1;
			rx2 <= rx1;
			ry2 <= ry1;
			wl2 <= wl1;
			if (anim1 = '1') then
				wt2 <= anim_q;
			else
				wt2 <= wall_q;
			end if;
			prod2 <= e1 * rinv_q;
			skya2 <= std_logic_vector(sky_u1(8 downto 1)) & std_logic_vector(skyv1);

			-- S2 -> S3: rd = min(DD_MAX, product >> 8); overflow when bits 33:32 /= 0
			wall3 <= wall2;
			ceil3 <= ceil2;
			addr3 <= addr2;
			rx3 <= rx2;
			ry3 <= ry2;
			wl3 <= wl2;
			wt3 <= wt2;
			skya3 <= skya2;
			if (prod2(33 downto 32) /= 0) then
				rd3 <= to_unsigned(DD_MAX, 24);
			else
				rd3 <= prod2(31 downto 8);
			end if;

			-- S3 -> S4: multiplier operands; distance light term
			wall4 <= wall3;
			ceil4 <= ceil3;
			addr4 <= addr3;
			wl4 <= wl3;
			wt4 <= wt3;
			skya4 <= skya3;
			-- min(15, rd >> 18): bits 23:22 set means rd >> 18 >= 16
			if (rd3(23 downto 22) /= 0) then
				dt4 <= to_unsigned(15, 4);
			else
				dt4 <= rd3(21 downto 18);
			end if;
			m_rd <= signed('0' & rd3);
			m_rx <= rx3;
			m_ry <= ry3;

			-- S4 -> S5: products
			wall5 <= wall4;
			ceil5 <= ceil4;
			addr5 <= addr4;
			wl5 <= wl4;
			wt5 <= wt4;
			dt5 <= dt4;
			skya5 <= skya4;
			prod_x <= m_rd * m_rx;
			prod_y <= m_rd * m_ry;

			-- S5 -> S6: world point = pos + product bits 37:16 (mod 2^22, as the model)
			wall6 <= wall5;
			ceil6 <= ceil5;
			addr6 <= addr5;
			wl6 <= wl5;
			wt6 <= wt5;
			dt6 <= dt5;
			skya6 <= skya5;
			wx6 <= px + unsigned(prod_x(37 downto 16));
			wy6 <= py + unsigned(prod_y(37 downto 16));

			-- S6 -> S7: map address is on map_addr_o during S6
			wall7 <= wall6;
			ceil7 <= ceil6;
			addr7 <= addr6;
			wl7 <= wl6;
			wt7 <= wt6;
			dt7 <= dt6;
			skya7 <= skya6;
			u7 <= wx6(15 downto 10);
			vv7 <= wy6(15 downto 10);

			-- S7 -> S8: register the tile fields only (BRAM output is unregistered)
			wall8 <= wall7;
			addr8 <= addr7;
			wl8 <= wl7;
			wt8 <= wt7;
			dt8 <= dt7;
			skya8 <= skya7;
			tl8 <= unsigned(map_data_i(11 downto 8)); -- Tile light
			ty8 <= unsigned(map_data_i(13 downto 12)); -- Light type
			-- Sky: a ceiling pixel over an open tile (wall_tex 0) with bit 23 set
			if ((ceil7 = '1') and (map_data_i(3 downto 0) = "0000") and (map_data_i(23) = '1')) then
				sky8 <= '1';
			else
				sky8 <= '0';
			end if;

			-- S8 -> S9: flat texel has arrived; final light = ldist8 clamped at 0
			wall9 <= wall8;
			addr9 <= addr8;
			wl9 <= wl8;
			wt9 <= wt8;
			ft9 <= flat_q;
			sky9 <= sky8;
			skya9 <= skya8;
			if (ldist8 < 0) then
				fl9 <= (others => '0');
			else
				fl9 <= unsigned(ldist8(3 downto 0));
			end if;

			-- S9 -> S10: palette index (light ROM) or sky texel (sky ROM) arrives
			addr10 <= addr9;
			sky10 <= sky9;
		end if;
	end process;

	-- Tile index = integer parts of the world point (Q6.16 bits 21:16), y * 64 + x
	map_addr_o <= std_logic_vector(unsigned'(wy6(21 downto 16) & wx6(21 downto 16)));

	-- S7: floor_tex, or ceil_tex; flat 0 on a ramp (special 7), whose ceil_tex is
	-- the ramp direction
	flat_sel <= map_data_i(5 downto 4) when (ceil7 = '0') else
		"00" when (map_data_i(16 downto 14) = "111") else
		map_data_i(7 downto 6);
	flat_addr <= flat_sel & std_logic_vector(unsigned'(vv7 & u7));

	flats: flat_rom
		port map (
			clk_i => clk_i,
			addr_i => flat_addr,
			data_o => flat_q
		);

	-- S9: light table address, wall or floor/ceiling; sky ROM address
	light_addr <= std_logic_vector(wl9) & wt9 when (wall9 = '1') else
		std_logic_vector(fl9) & ft9;

	lights: light_rom
		port map (
			clk_i => clk_i,
			addr_i => light_addr,
			data_o => light_q
		);

	skies: sky_rom
		port map (
			clk_i => clk_i,
			addr_i => skya9,
			data_o => sky_q
		);

	------------------------------------------------------------------
	-- S10: output FIFO (a slot was reserved at issue, so it has room)
	------------------------------------------------------------------
	-- Pixel word: buffer, then address y * 320 + x, then palette index
	fifo_in <= buf & std_logic_vector(addr10) & sky_q when (sky10 = '1') else
		buf & std_logic_vector(addr10) & light_q;

	out_fifo: sync_fifo
		generic map (
			WIDTH => PIXW_BITS,
			DEPTH_BITS => FIFO_BITS
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			in_valid_i => v10,
			in_ready_o => open,
			in_data_i => fifo_in,
			out_valid_o => fifo_valid,
			out_ready_i => pix_ready_i,
			out_data_o => pix_data_o,
			level_o => open
		);

	pix_valid_o <= fifo_valid;
end arch;

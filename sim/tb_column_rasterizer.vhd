--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Column Rasterizer Testbench
-- Module Name:    tb_column_rasterizer
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for the stage-4 column_rasterizer
--                 against the golden model (tools/model/render.py,
--                 raster_spans). For each of the 27 poses of
--                 sim/golden/ray4_poses.txt (9 flat level-1 poses, 10 on
--                 level 3 with heights and ramps, 4 on the directed test
--                 map, 4 with the stage-4 effects: sky, light types,
--                 animated slime) it drives the pose's camera, angle and
--                 effects register (fx) and feeds the golden span
--                 descriptors of sim/golden/ray4_spans.txt (format in
--                 tools/model/golden4.py; LAST on the last span of each
--                 column) with random gaps, draws from a behavioral tile map
--                 RAM holding the pose's map (sim/golden/ray4_maps.txt,
--                 1-clock read latency), applies random back-pressure on
--                 the pixel port (READY_PCT percent of clocks ready), and
--                 compares every pixel with sim/golden/frame4_<k>.txt.
--                 Checks: every pixel address written exactly once (a pixel
--                 never written fails, like a framebuffer prefilled with a
--                 wrong value), every pixel equal to the model, the buffer
--                 bit, one done_o per frame, idle afterwards. Prints the
--                 clocks per frame.
--                 RUN_VARIANTS: READY_PCT=60 READY_PCT=100
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, std.textio, tb_pkg, column_rasterizer and
--                 its ROMs, sync_fifo, render_types_pkg, game_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.math_real.all;
use std.textio.all;
use work.tb_pkg.all;
use work.game_pkg.all;
use work.render_types_pkg.all;

entity tb_column_rasterizer is
	generic(
		GOLDEN_DIR: string := "../../sim/golden/"; -- Relative to the run directory
		READY_PCT: natural := 60 -- Pixel port ready probability, percent
	);
end tb_column_rasterizer;

architecture arch of tb_column_rasterizer is
	component column_rasterizer is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			pos_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			pos_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			fx_i: in std_logic_vector(FX_BITS - 1 downto 0);
			buf_i: in std_logic;
			desc_valid_i: in std_logic;
			desc_ready_o: out std_logic;
			desc_i: in std_logic_vector(DESC_BITS - 1 downto 0);
			map_addr_o: out std_logic_vector(11 downto 0);
			map_data_i: in std_logic_vector(23 downto 0);
			pix_valid_o: out std_logic;
			pix_ready_i: in std_logic;
			pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic
		);
	end component;

	constant PERIOD: time := 10 ns;
	constant POSES: natural := 27; -- Lines of ray4_poses.txt (checked at the end)
	constant PIXELS: natural := 320 * 240;

	-- Pixels captured for the current frame (-1 = not written)
	type image_store_t is protected
		procedure clear;
		procedure put(addr: natural; value: natural);
		impure function get(addr: natural) return integer;
		impure function twice return natural;
	end protected image_store_t;
	type image_store_t is protected body
		type image_t is array (0 to PIXELS - 1) of integer;
		variable img: image_t := (others => -1);
		variable dup: natural := 0;
		procedure clear is
		begin
			img := (others => -1);
			dup := 0;
		end procedure;
		procedure put(addr: natural; value: natural) is
		begin
			if (img(addr) /= -1) then
				dup := dup + 1;
			end if;
			img(addr) := value;
		end procedure;
		impure function get(addr: natural) return integer is
		begin
			return img(addr);
		end function;
		impure function twice return natural is
		begin
			return dup;
		end function;
	end protected body image_store_t;

	-- The tile maps of ray4_maps.txt (level 1 and level 3)
	type tiles_t is array (0 to 4095) of std_logic_vector(23 downto 0);
	type maps_t is protected
		procedure put(m: natural; i: natural; t: std_logic_vector(23 downto 0));
		impure function get(m: natural; i: natural) return std_logic_vector;
	end protected maps_t;
	type maps_t is protected body
		type all_t is array (0 to 15) of tiles_t; -- Indexed by map level (1, 3, 9 = test map)
		variable maps: all_t := (others => (others => (others => '0')));
		procedure put(m: natural; i: natural; t: std_logic_vector(23 downto 0)) is
		begin
			maps(m)(i) := t;
		end procedure;
		impure function get(m: natural; i: natural) return std_logic_vector is
		begin
			return maps(m)(i);
		end function;
	end protected body maps_t;

	shared variable chk: checker_t;
	shared variable store: image_store_t;
	shared variable maps: maps_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal start: std_logic := '0';
	signal pos_x, pos_y: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal angle: std_logic_vector(ANGLE_BITS - 1 downto 0) := (others => '0');
	signal fx: std_logic_vector(FX_BITS - 1 downto 0) := (others => '0');
	signal buf: std_logic := '0';
	signal desc_valid: std_logic := '0';
	signal desc_ready: std_logic;
	signal desc: std_logic_vector(DESC_BITS - 1 downto 0) := (others => '0');
	signal map_addr: std_logic_vector(11 downto 0);
	signal map_data: std_logic_vector(23 downto 0) := (others => '0');
	signal tiles: tiles_t := (others => (others => '0'));
	signal pix_valid: std_logic;
	signal pix_ready: std_logic := '0';
	signal pix_data: std_logic_vector(PIXW_BITS - 1 downto 0);
	signal busy, done: std_logic;
	signal dones: natural := 0;
	signal bad_buf: natural := 0;

	function hexval(c: character) return natural is
	begin
		if ((c >= '0') and (c <= '9')) then
			return character'pos(c) - character'pos('0');
		else
			return character'pos(c) - character'pos('A') + 10;
		end if;
	end function;
begin
	dut: column_rasterizer
		port map (
			clk_i => clk,
			rst_i => rst,
			start_i => start,
			pos_x_i => pos_x,
			pos_y_i => pos_y,
			angle_i => angle,
			fx_i => fx,
			buf_i => buf,
			desc_valid_i => desc_valid,
			desc_ready_o => desc_ready,
			desc_i => desc,
			map_addr_o => map_addr,
			map_data_i => map_data,
			pix_valid_o => pix_valid,
			pix_ready_i => pix_ready,
			pix_data_o => pix_data,
			busy_o => busy,
			done_o => done
		);

	-- Tile map of the current pose, read one clock after the address
	process(clk)
	begin
		if rising_edge(clk) then
			map_data <= tiles(to_integer(unsigned(map_addr)));
		end if;
	end process;

	process
	begin
		if (finished) then
			wait;
		end if;
		clk <= '0';
		wait for PERIOD / 2;
		clk <= '1';
		wait for PERIOD / 2;
	end process;

	process
	begin
		rst <= '1';
		wait for 10.5 * PERIOD;
		rst <= '0';
		wait;
	end process;

	-- Random back-pressure on the pixel port
	process
		variable s1, s2: positive := 17;
		variable x: real;
	begin
		wait until rising_edge(clk);
		uniform(s1, s2, x);
		if (x * 100.0 < real(READY_PCT)) then
			pix_ready <= '1';
		else
			pix_ready <= '0';
		end if;
	end process;

	-- Capture pixel writes and done pulses
	process(clk)
	begin
		if rising_edge(clk) then
			if ((pix_valid = '1') and (pix_ready = '1')) then
				store.put(to_integer(unsigned(pix_data(PIXW_ADDR_HI downto PIXW_ADDR_LO))),
					to_integer(unsigned(pix_data(PIXW_DATA_HI downto PIXW_DATA_LO))));
				if (pix_data(PIXW_BUF) /= buf) then
					bad_buf <= bad_buf + 1;
				end if;
			end if;
			if (done = '1') then
				dones <= dones + 1;
			end if;
		end if;
	end process;

	-- Stimulus and checks
	process
		file maps_f: text open read_mode is GOLDEN_DIR & "ray4_maps.txt";
		file poses_f: text open read_mode is GOLDEN_DIR & "ray4_poses.txt";
		file spans_f: text open read_mode is GOLDEN_DIR & "ray4_spans.txt";
		file frame_f: text;
		variable l: line;
		variable c: character;
		variable s6: string(1 to 6);
		variable n, m, hv, nspans, nclips, col, rx, ry: integer;
		variable f: integer_vector(0 to 9);
		variable d: std_logic_vector(DESC_BITS - 1 downto 0);
		variable t: tiles_t;
		variable s1, s2: positive := 5;
		variable x: real;
		variable t0: time;
		variable c1, c2: character;
		variable wrong, missing, a, got: integer;
		variable fxv: std_logic_vector(FX_BITS - 1 downto 0);
	begin
		-- Maps: "M <level>" then one line of 4096 hex words
		while not endfile(maps_f) loop
			readline(maps_f, l);
			read(l, c);
			read(l, m);
			readline(maps_f, l);
			for i in 0 to 4095 loop
				read(l, s6);
				hv := 0;
				for j in 1 to 6 loop
					hv := hv * 16 + hexval(s6(j));
				end loop;
				maps.put(m, i, std_logic_vector(to_unsigned(hv, 24)));
				if (i /= 4095) then
					read(l, c);
				end if;
			end loop;
		end loop;
		wait until (rst = '0');
		for k in 0 to POSES - 1 loop
			-- Pose: map px py angle eye ndoors (x y open) x 8 lmod0..3 anim (the eye and
			-- the doors only matter to the ray engine)
			readline(poses_f, l);
			read(l, m);
			read(l, n);
			pos_x <= std_logic_vector(to_unsigned(n, POS_BITS));
			read(l, n);
			pos_y <= std_logic_vector(to_unsigned(n, POS_BITS));
			read(l, n);
			angle <= std_logic_vector(to_unsigned(n, ANGLE_BITS));
			for i in 1 to 2 + 24 loop -- Skip eye, ndoors and 8 x (x y open)
				read(l, n);
			end loop;
			for i in 0 to 3 loop
				read(l, n);
				fxv(FX_LMOD_W * i + FX_LMOD_W - 1 downto FX_LMOD_W * i) :=
					std_logic_vector(to_signed(n, FX_LMOD_W));
			end loop;
			read(l, n);
			fxv(FX_ANIM_HI downto FX_ANIM_LO) := std_logic_vector(to_unsigned(n, 2));
			fx <= fxv;
			for i in 0 to 4095 loop
				t(i) := maps.get(m, i);
			end loop;
			tiles <= t;
			buf <= '1' when ((k mod 2) = 1) else '0';
			store.clear;
			wait until rising_edge(clk);
			start <= '1';
			wait until rising_edge(clk);
			start <= '0';
			t0 := now;
			for cc in 0 to 319 loop
				-- C pose col z spans clips rx ry
				readline(spans_f, l);
				read(l, c);
				read(l, n);
				read(l, col);
				read(l, n);
				read(l, nspans);
				read(l, nclips);
				read(l, rx);
				read(l, ry);
				for sp in 1 to nspans loop
					-- S kind y0 y1 e tex_id tex_col v0 tex_step light side
					readline(spans_f, l);
					read(l, c);
					for i in 0 to 9 loop
						read(l, f(i));
					end loop;
					d := (others => '0');
					d(DESC_COL_HI downto DESC_COL_LO) := std_logic_vector(to_unsigned(col, 9));
					d(DESC_KIND_HI downto DESC_KIND_LO) := std_logic_vector(to_unsigned(f(0), 2));
					d(DESC_Y0_HI downto DESC_Y0_LO) := std_logic_vector(to_unsigned(f(1), 8));
					d(DESC_Y1_HI downto DESC_Y1_LO) := std_logic_vector(to_unsigned(f(2), 8));
					d(DESC_E_HI downto DESC_E_LO) := std_logic_vector(to_unsigned(f(3), 7));
					d(DESC_TEX_HI downto DESC_TEX_LO) := std_logic_vector(to_unsigned(f(4), 4));
					d(DESC_TCOL_HI downto DESC_TCOL_LO) := std_logic_vector(to_unsigned(f(5), 6));
					d(DESC_V0_HI downto DESC_V0_LO) := std_logic_vector(to_unsigned(f(6), 23));
					d(DESC_STEP_HI downto DESC_STEP_LO) := std_logic_vector(to_unsigned(f(7), 24));
					d(DESC_LIGHT_HI downto DESC_LIGHT_LO) := std_logic_vector(to_unsigned(f(8), 4));
					d(DESC_SIDE) := '1' when (f(9) = 1) else '0';
					d(DESC_RX_HI downto DESC_RX_LO) := std_logic_vector(to_signed(rx, 18));
					d(DESC_RY_HI downto DESC_RY_LO) := std_logic_vector(to_signed(ry, 18));
					d(DESC_LAST) := '1' when (sp = nspans) else '0';
					-- Random gap before the descriptor is offered
					uniform(s1, s2, x);
					for g in 1 to integer(x * 4.0) loop
						wait until rising_edge(clk);
					end loop;
					desc <= d;
					desc_valid <= '1';
					loop
						wait until rising_edge(clk);
						exit when (desc_ready = '1');
					end loop;
					desc_valid <= '0';
				end loop;
				for cl in 1 to nclips loop
					readline(spans_f, l); -- L lines: not the rasterizer's
				end loop;
			end loop;
			wait until (done = '1') for 20 ms;
			wait until rising_edge(clk);
			wait for 1 ns; -- Let the capture process count the done pulse
			tb_print("pose " & integer'image(k) & ": " & integer'image((now - t0) / PERIOD) &
				" clocks (ready " & integer'image(READY_PCT) & "%)");
			-- Compare with the golden frame
			wrong := 0;
			missing := 0;
			file_open(frame_f, GOLDEN_DIR & "frame4_" & integer'image(k) & ".txt", read_mode);
			for y in 0 to 239 loop
				-- One line per row: 320 pixels as two hex digits each, no separators
				readline(frame_f, l);
				for xx in 0 to 319 loop
					read(l, c1);
					read(l, c2);
					a := y * 320 + xx;
					got := store.get(a);
					if (got = -1) then
						missing := missing + 1;
					elsif (got /= hexval(c1) * 16 + hexval(c2)) then
						wrong := wrong + 1;
						if (wrong <= 5) then
							report "pose " & integer'image(k) & " pixel (" & integer'image(xx) & "," &
								integer'image(y) & ") = " & integer'image(got) & " want " &
								integer'image(hexval(c1) * 16 + hexval(c2)) severity error;
						end if;
					end if;
				end loop;
			end loop;
			file_close(frame_f);
			chk.check(wrong = 0, "pose " & integer'image(k) & ": " & integer'image(wrong) &
				" wrong pixels");
			chk.check(missing = 0, "pose " & integer'image(k) & ": " & integer'image(missing) &
				" pixels never written");
			chk.check(store.twice = 0, "pose " & integer'image(k) & ": " &
				integer'image(store.twice) & " pixels written twice");
			chk.check(dones = k + 1, "one done per frame, got " & integer'image(dones));
			chk.check(busy = '0', "idle after done");
		end loop;
		-- A pose added to the golden file must not go untested
		chk.check(endfile(poses_f), "ray4_poses.txt has more poses than POSES");
		chk.check(bad_buf = 0, "pixels with the wrong buffer bit: " & integer'image(bad_buf));
		finished <= true;
		tb_finish("tb_column_rasterizer", chk.checks, chk.errors);
		wait;
	end process;
end arch;

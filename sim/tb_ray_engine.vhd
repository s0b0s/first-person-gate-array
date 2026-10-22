--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Ray Engine Testbench
-- Module Name:    tb_ray_engine
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for the stage-4 ray engine against
--                 the golden model (tools/model/render.py via golden4.py):
--                 sim/golden/ray4_poses.txt gives 27 poses (the 9 flat
--                 level-1 poses of stage 1, then 10 on level 3: stairs, a
--                 ramp, a platform, a lower ceiling, a pit, a dais, standing
--                 on a ramp, ducked in a pit, nose on a riser, down a ramp,
--                 then 4 on the directed test map: a -y ramp from below and
--                 above, a 24 step, a ramp chain that overflows the clip list,
--                 then 4 with light effects: level 1's sky with flicker
--                 offsets, the level-3 arena during a strobe, the flickering
--                 hall, the glowing room during a muzzle flash; each pose
--                 line ends with the effects register: lmod of light types
--                 0..3 and anim, driven on fx_i),
--                 ray4_maps.txt the tile maps and ray4_spans.txt every
--                 span, clip entry and z of every column.
--                 The map RAM has the 1-clock read latency of the tile map
--                 BRAM; desc_ready is high READY_PCT percent of the clocks.
--                 Checks: every span in order (column, kind, rows, ray and
--                 LAST; textured spans also texture, column, v0, tex_step,
--                 light, side; floor and ceiling spans E), the span count
--                 per column, every z-buffer, clip-count and clip-entry
--                 write, and one done_o per frame. Prints the clocks per
--                 pose. Each pose's expectations are loaded by pose number
--                 before it runs, so one failing pose cannot shift the next.
--                 RUN_VARIANTS: READY_PCT=40 READY_PCT=100
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, std.textio, tb_pkg, ray_engine, divider,
--                 render_pkg, render_types_pkg
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
use work.render_pkg.all;
use work.render_types_pkg.all;

entity tb_ray_engine is
	generic(
		GOLDEN_DIR: string := "../../sim/golden/"; -- Relative to the run directory
		READY_PCT: natural := 40 -- Descriptor port ready probability, percent
	);
end tb_ray_engine;

architecture arch of tb_ray_engine is
	component ray_engine is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			pos_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			pos_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			eye_i: in std_logic_vector(EYE_BITS - 1 downto 0);
			doors_i: in std_logic_vector(DOORS_BITS - 1 downto 0);
			fx_i: in std_logic_vector(FX_BITS - 1 downto 0);
			map_addr_o: out std_logic_vector(11 downto 0);
			map_data_i: in std_logic_vector(23 downto 0);
			desc_valid_o: out std_logic;
			desc_ready_i: in std_logic;
			desc_o: out std_logic_vector(DESC_BITS - 1 downto 0);
			zbuf_we_o: out std_logic;
			zbuf_addr_o: out std_logic_vector(8 downto 0);
			zbuf_data_o: out std_logic_vector(15 downto 0);
			clip_we_o: out std_logic;
			clip_addr_o: out std_logic_vector(12 downto 0);
			clip_data_o: out std_logic_vector(CLIP_BITS - 1 downto 0);
			ccount_we_o: out std_logic;
			ccount_addr_o: out std_logic_vector(8 downto 0);
			ccount_data_o: out std_logic_vector(4 downto 0);
			seen_we_o: out std_logic;
			seen_addr_o: out std_logic_vector(11 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic
		);
	end component;

	constant PERIOD: time := 10 ns;
	constant POSES: natural := 27; -- Lines of ray4_poses.txt (checked at the end)
	constant MAX_SPANS: natural := 128; -- Spans per column held for checking

	type tiles_t is array (0 to 4095) of std_logic_vector(23 downto 0);
	type zs_t is array (0 to SCREEN_W - 1) of integer;
	type clips_t is array (0 to SCREEN_W * 16 - 1) of integer;
	type span_t is array (0 to 9) of integer; -- kind y0 y1 e tex tcol v0 step light side
	type spans_t is array (0 to SCREEN_W * MAX_SPANS - 1) of span_t; -- One pose
	shared variable chk: checker_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal start: std_logic := '0';
	signal pos_x, pos_y: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal angle: std_logic_vector(ANGLE_BITS - 1 downto 0) := (others => '0');
	signal eye: std_logic_vector(EYE_BITS - 1 downto 0) := (others => '0');
	signal doors: std_logic_vector(DOORS_BITS - 1 downto 0) := (others => '0');
	signal fx: std_logic_vector(FX_BITS - 1 downto 0) := (others => '0');
	signal map1, map3, map9: tiles_t := (others => (others => '0')); -- Level 1, 3, test map
	signal map_sel: natural := 1;
	signal map_addr: std_logic_vector(11 downto 0);
	signal map_data: std_logic_vector(23 downto 0) := (others => '0');
	signal desc_valid: std_logic;
	signal desc_ready: std_logic := '0';
	signal desc: std_logic_vector(DESC_BITS - 1 downto 0);
	signal zbuf_we, clip_we, ccount_we: std_logic;
	signal zbuf_addr, ccount_addr: std_logic_vector(8 downto 0);
	signal zbuf_data: std_logic_vector(15 downto 0);
	signal clip_addr: std_logic_vector(12 downto 0);
	signal clip_data: std_logic_vector(CLIP_BITS - 1 downto 0);
	signal ccount_data: std_logic_vector(4 downto 0);
	signal busy, done: std_logic;
	-- Captured writes
	signal zgot, cgot: zs_t := (others => -1);
	signal clipz, cliprows: clips_t := (others => -1); -- z; top + 256 * bottom
	signal zwrites, cwrites, dones: natural := 0;

	function u(v: std_logic_vector) return integer is
	begin
		return to_integer(unsigned(v));
	end function;

	function s(v: std_logic_vector) return integer is
	begin
		return to_integer(signed(v));
	end function;

	function hexval(c: character) return natural is
	begin
		if ((c >= '0') and (c <= '9')) then
			return character'pos(c) - character'pos('0');
		else
			return character'pos(c) - character'pos('A') + 10;
		end if;
	end function;
begin
	dut: ray_engine
		port map (
			clk_i => clk,
			rst_i => rst,
			start_i => start,
			pos_x_i => pos_x,
			pos_y_i => pos_y,
			angle_i => angle,
			eye_i => eye,
			doors_i => doors,
			fx_i => fx,
			map_addr_o => map_addr,
			map_data_i => map_data,
			desc_valid_o => desc_valid,
			desc_ready_i => desc_ready,
			desc_o => desc,
			zbuf_we_o => zbuf_we,
			zbuf_addr_o => zbuf_addr,
			zbuf_data_o => zbuf_data,
			clip_we_o => clip_we,
			clip_addr_o => clip_addr,
			clip_data_o => clip_data,
			ccount_we_o => ccount_we,
			ccount_addr_o => ccount_addr,
			ccount_data_o => ccount_data,
			seen_we_o => open,
			seen_addr_o => open,
			busy_o => busy,
			done_o => done
		);

	-- Tile map with the BRAM's one-clock read latency
	process(clk)
	begin
		if rising_edge(clk) then
			if (map_sel = 9) then
				map_data <= map9(to_integer(unsigned(map_addr)));
			elsif (map_sel = 3) then
				map_data <= map3(to_integer(unsigned(map_addr)));
			else
				map_data <= map1(to_integer(unsigned(map_addr)));
			end if;
		end if;
	end process;

	-- z-buffer, clip and clip-count writes
	process(clk)
	begin
		if rising_edge(clk) then
			if (zbuf_we = '1') then
				zgot(u(zbuf_addr)) <= u(zbuf_data);
				zwrites <= zwrites + 1;
			end if;
			if (ccount_we = '1') then
				cgot(u(ccount_addr)) <= u(ccount_data);
				cwrites <= cwrites + 1;
			end if;
			if (clip_we = '1') then
				clipz(u(clip_addr(12 downto 4)) * 16 + u(clip_addr(3 downto 0))) <=
					u(clip_data(CLIP_Z_HI downto CLIP_Z_LO));
				cliprows(u(clip_addr(12 downto 4)) * 16 + u(clip_addr(3 downto 0))) <=
					u(clip_data(CLIP_TOP_HI downto CLIP_TOP_LO)) + 256 * u(clip_data(CLIP_BOT_HI downto CLIP_BOT_LO));
			end if;
			if (done = '1') then
				dones <= dones + 1;
			end if;
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

	-- Random back-pressure on the descriptor port
	process
		variable s1, s2: positive := 9;
		variable x: real;
	begin
		wait until rising_edge(clk);
		uniform(s1, s2, x);
		if (x * 100.0 < real(READY_PCT)) then
			desc_ready <= '1';
		else
			desc_ready <= '0';
		end if;
	end process;

	-- Stimulus and checks. Each pose's expectations are loaded completely (by
	-- pose number) before the pose runs, so a pose that emits too many or too
	-- few spans cannot shift the expectations of the next one.
	process
		file fm, fp, fs: text;
		variable l: line;
		variable c: character;
		variable s6: string(1 to 6);
		variable n, hv: integer;
		variable t: tiles_t;
		type pose_t is array (0 to 5 + 3 * 8 + 5) of integer; -- ..., lmod 0..3, anim
		variable pose: pose_t;
		variable d: std_logic_vector(DOORS_BITS - 1 downto 0);
		variable e: std_logic_vector(DOOR_BITS - 1 downto 0);
		variable zexp, cexp, nsexp, rxexp, ryexp: zs_t;
		variable clipzexp, cliprowsexp: clips_t;
		variable spans: spans_t;
		variable sp: span_t;
		variable idx, col, cycles, frame_bad, total, extra, dones0, zw0, cw0: natural;
		variable cz, ct, cb: integer;
		variable kind: integer;
		variable got_last: boolean;
		-- Golden header line read ahead (it may belong to the next pose)
		variable have_hdr: boolean := false;
		variable h_pose, h_col, h_z, h_ns, h_nc, h_rx, h_ry: integer;

		procedure compare(name: string; value, want: integer) is
		begin
			if (value /= want) then
				frame_bad := frame_bad + 1;
				if (frame_bad <= 8) then
					report "column " & integer'image(col) & " span " & integer'image(idx) & " " & name &
						" = " & integer'image(value) & " want " & integer'image(want) severity error;
				end if;
			end if;
		end procedure;
	begin
		-- Every map in the file (each needs its own store, see map_sel)
		file_open(fm, GOLDEN_DIR & "ray4_maps.txt", read_mode);
		while not endfile(fm) loop
			readline(fm, l);
			read(l, c);
			read(l, n);
			readline(fm, l);
			for i in 0 to 4095 loop
				if (i > 0) then
					read(l, c);
				end if;
				read(l, s6);
				hv := 0;
				for j in 1 to 6 loop
					hv := hv * 16 + hexval(s6(j));
				end loop;
				t(i) := std_logic_vector(to_unsigned(hv, 24));
			end loop;
			assert (n = 1) or (n = 3) or (n = 9) report "ray4_maps.txt: unknown map " &
				integer'image(n) severity failure;
			if (n = 9) then
				map9 <= t;
			elsif (n = 3) then
				map3 <= t;
			else
				map1 <= t;
			end if;
		end loop;
		file_close(fm);
		file_open(fp, GOLDEN_DIR & "ray4_poses.txt", read_mode);
		file_open(fs, GOLDEN_DIR & "ray4_spans.txt", read_mode);
		wait until (rst = '0');
		wait until rising_edge(clk);
		for p in 0 to POSES - 1 loop
			readline(fp, l);
			for i in pose_t'range loop
				read(l, pose(i));
			end loop;
			-- This pose's columns: header "C pose col z spans clips rx ry", then its
			-- S and L lines; columns of earlier poses are skipped, the first header
			-- of a later pose is kept for it
			for x in 0 to SCREEN_W - 1 loop
				nsexp(x) := -1;
			end loop;
			loop
				if (not have_hdr) then
					exit when endfile(fs);
					readline(fs, l);
					read(l, c);
					next when (c /= 'C');
					read(l, h_pose);
					read(l, h_col);
					read(l, h_z);
					read(l, h_ns);
					read(l, h_nc);
					read(l, h_rx);
					read(l, h_ry);
					have_hdr := true;
				end if;
				exit when (h_pose > p);
				have_hdr := false;
				for i in 0 to h_ns - 1 loop
					readline(fs, l);
					read(l, c);
					for f in 0 to 9 loop
						read(l, sp(f));
					end loop;
					if ((h_pose = p) and (i < MAX_SPANS)) then
						spans(h_col * MAX_SPANS + i) := sp;
					end if;
				end loop;
				for i in 0 to h_nc - 1 loop
					readline(fs, l);
					read(l, c);
					read(l, cz);
					read(l, ct);
					read(l, cb);
					if ((h_pose = p) and (i < 16)) then
						clipzexp(h_col * 16 + i) := cz;
						cliprowsexp(h_col * 16 + i) := ct + 256 * cb;
					end if;
				end loop;
				if (h_pose = p) then
					assert h_ns <= MAX_SPANS report "raise MAX_SPANS" severity failure;
					nsexp(h_col) := h_ns;
					cexp(h_col) := h_nc;
					zexp(h_col) := h_z;
					rxexp(h_col) := h_rx;
					ryexp(h_col) := h_ry;
				end if;
			end loop;
			for x in 0 to SCREEN_W - 1 loop
				assert nsexp(x) > 0 report "pose " & integer'image(p) & ": no golden column " &
					integer'image(x) severity failure;
			end loop;

			map_sel <= pose(0);
			pos_x <= std_logic_vector(to_unsigned(pose(1), POS_BITS));
			pos_y <= std_logic_vector(to_unsigned(pose(2), POS_BITS));
			angle <= std_logic_vector(to_unsigned(pose(3), ANGLE_BITS));
			eye <= std_logic_vector(to_unsigned(pose(4), EYE_BITS));
			d := (others => '0');
			-- Door j is pose fields 6 + 3j .. 8 + 3j (x, y, open), packed open & y & x
			for j in 0 to 7 loop
				e := std_logic_vector(to_unsigned(pose(8 + 3 * j), 7)) &
					std_logic_vector(to_unsigned(pose(7 + 3 * j), 6)) &
					std_logic_vector(to_unsigned(pose(6 + 3 * j), 6));
				d(DOOR_BITS * j + DOOR_BITS - 1 downto DOOR_BITS * j) := e;
			end loop;
			doors <= d;
			-- Effects register: light type k's offset (signed) at 5k + 4 .. 5k, anim at 21:20
			for j in 0 to 3 loop
				fx(FX_LMOD_W * j + FX_LMOD_W - 1 downto FX_LMOD_W * j) <=
					std_logic_vector(to_signed(pose(30 + j), FX_LMOD_W));
			end loop;
			fx(FX_ANIM_HI downto FX_ANIM_LO) <= std_logic_vector(to_unsigned(pose(34), 2));
			dones0 := dones;
			zw0 := zwrites;
			cw0 := cwrites;
			wait until rising_edge(clk);
			start <= '1';
			wait until rising_edge(clk);
			start <= '0';
			col := 0;
			idx := 0;
			total := 0;
			extra := 0;
			cycles := 1;
			frame_bad := 0;
			loop
				wait until rising_edge(clk);
				cycles := cycles + 1;
				if ((desc_valid = '1') and (desc_ready = '1')) then
					-- This column's spans all seen: the descriptor belongs to the next column
					if ((col < SCREEN_W) and (idx = nsexp(col))) then
						col := col + 1;
						idx := 0;
					end if;
					if (col >= SCREEN_W) then
						-- More spans than the model's 320 columns
						extra := extra + 1;
						frame_bad := frame_bad + 1;
					else
						sp := spans(col * MAX_SPANS + idx);
						kind := sp(0);
						compare("col", u(desc(DESC_COL_HI downto DESC_COL_LO)), col);
						compare("kind", u(desc(DESC_KIND_HI downto DESC_KIND_LO)), kind);
						compare("y0", u(desc(DESC_Y0_HI downto DESC_Y0_LO)), sp(1));
						compare("y1", u(desc(DESC_Y1_HI downto DESC_Y1_LO)), sp(2));
						compare("rx", s(desc(DESC_RX_HI downto DESC_RX_LO)), rxexp(col));
						compare("ry", s(desc(DESC_RY_HI downto DESC_RY_LO)), ryexp(col));
						if (kind = 2) then
							compare("tex_id", u(desc(DESC_TEX_HI downto DESC_TEX_LO)), sp(4));
							compare("tex_col", u(desc(DESC_TCOL_HI downto DESC_TCOL_LO)), sp(5));
							compare("v0", u(desc(DESC_V0_HI downto DESC_V0_LO)), sp(6));
							compare("tex_step", u(desc(DESC_STEP_HI downto DESC_STEP_LO)), sp(7));
							compare("light", u(desc(DESC_LIGHT_HI downto DESC_LIGHT_LO)), sp(8));
							if (desc(DESC_SIDE) = '1') then
								compare("side", 1, sp(9));
							else
								compare("side", 0, sp(9));
							end if;
						else
							compare("e", u(desc(DESC_E_HI downto DESC_E_LO)), sp(3));
						end if;
						got_last := desc(DESC_LAST) = '1';
						if (got_last /= (idx = nsexp(col) - 1)) then
							compare("last", 0, 1);
						end if;
						idx := idx + 1;
					end if;
					total := total + 1;
				end if;
				exit when (done = '1') or (cycles > 3_000_000);
			end loop;
			wait until rising_edge(clk);
			wait until rising_edge(clk);
			chk.check((col = SCREEN_W - 1) and (idx = nsexp(SCREEN_W - 1)) and (extra = 0), "pose " &
				integer'image(p) & ": all columns and spans out (" & integer'image(col + 1) & " columns, " &
				integer'image(total) & " spans, " & integer'image(extra) & " extra)");
			chk.check(dones = dones0 + 1, "pose " & integer'image(p) & ": one done pulse");
			chk.check(zwrites = zw0 + SCREEN_W, "pose " & integer'image(p) & ": z-buffer writes");
			chk.check(cwrites = cw0 + SCREEN_W, "pose " & integer'image(p) & ": clip-count writes");
			for x in 0 to SCREEN_W - 1 loop
				col := x;
				idx := 0;
				compare("z", zgot(x), zexp(x));
				compare("clip count", cgot(x), cexp(x));
				for i in 0 to cexp(x) - 1 loop
					idx := i;
					compare("clip z", clipz(x * 16 + i), clipzexp(x * 16 + i));
					compare("clip top + 256 * bottom", cliprows(x * 16 + i), cliprowsexp(x * 16 + i));
				end loop;
			end loop;
			chk.check(frame_bad = 0, "pose " & integer'image(p) & ": " & integer'image(frame_bad) &
				" mismatches");
			tb_print("pose " & integer'image(p) & ": " & integer'image(cycles) & " clocks, " &
				integer'image(total) & " spans");
		end loop;
		-- A pose added to the golden file must not go untested
		chk.check(endfile(fp), "ray4_poses.txt has more poses than POSES");
		file_close(fp);
		file_close(fs);
		finished <= true;
		tb_finish("tb_ray_engine", chk.checks, chk.errors);
		wait;
	end process;
end arch;

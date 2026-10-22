--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Game Core Testbench
-- Module Name:    tb_game_core
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for game_core against the golden
--                 traces of tools/model/game.py, 1,500 frames each:
--                 TRACE = 2: sim/golden/game2_trace.txt, the stage-2/3
--                 autopilot session (title, briefing, level 1 with fights,
--                 pickups, doors, a death and restart);
--                 TRACE = 4: sim/golden/game4_trace.txt, the stage-4
--                 heights session on level 3 (stairs, a ramp, a raised hall
--                 with a lower ceiling, a step up, falls, fights, a death
--                 and restart). In it level 3 plays as level 1, so the
--                 loader model supplies build/level3.bin when the core asks
--                 for level 1.
--                 TRACE = 5: sim/golden/game4d_trace.txt, 451 scripted frames
--                 on the directed test map (build/level9.bin): steps of 16
--                 and 24 (exactly the climb limit), falls, a ramp rising
--                 toward -y, the 40-unit headroom limit.
--                 TRACE = 6: sim/golden/game5a_trace.txt, 164 scripted frames
--                 on the directed alert map (build/level10.bin): a shot wakes
--                 only the Grunt around the corner (not the one behind a
--                 closed door, not the ambusher); after the door opens, a
--                 second shot wakes the far Grunt.
--                 RUN_VARIANTS: TRACE=2 TRACE=4 TRACE=5 TRACE=6
--                 Models around the core:
--                 - tile map, 4096 x 24 bits, one clock of read latency;
--                   written by the testbench loader and by the core
--                 - loader: on load_req_o it reads build/level<n>.bin
--                   (tools/model/level.py, Level.binary(): 12,288 tile bytes,
--                   start x u32, start y u32, angle u16, actor count u16,
--                   8-byte actor records), writes the map and all 32 actor
--                   slots (unused ones zero) with some delay, then pulses
--                   load_done_i
--                 - span and wall z memories (1-clock reads) holding the
--                   renderer output of the PREVIOUS frame (the trace's I
--                   line: spans, then the wall z of the 7 shotgun columns;
--                   other columns read 65535)
--                 Each frame: frame_start, the snapshot 2 clocks later,
--                 wait for render_start, then compare all 91 state words
--                 (S), the CRC (R), the sprite table (P), the sound
--                 commands in order (N), the HUD word and the screen
--                 tint (H: 20 HUD fields, then the tint), the effects
--                 register fx_o (X: light offsets of the four light types,
--                 animation frame), and the
--                 renderer registers against the state words (the eye
--                 register is min(127, z + eye) of word 5). Sprite entries
--                 carry the floor height (7th field of P). Prints the
--                 clocks per frame (snapshot to render_start).
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 std.textio, tb_pkg, game_core, game_pkg, render_types_pkg
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
use std.textio.all;
use work.tb_pkg.all;
use work.game_pkg.all;
use work.render_types_pkg.all;

entity tb_game_core is
	generic(
		TRACE: natural := 2; -- 2: game2_trace.txt, 4: game4_trace.txt (level 3 as level 1), 5: game4d_trace.txt, 6: game5a_trace.txt
		GOLDEN_PREFIX: string := "../../sim/golden/game"; -- + "<TRACE>_trace.txt", relative to the run directory
		LEVEL_PREFIX: string := "../../build/level" -- + "<n>.bin"
	);
end tb_game_core;

architecture arch of tb_game_core is
	component game_core is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			load_req_o: out std_logic;
			load_level_o: out std_logic_vector(1 downto 0);
			load_done_i: in std_logic;
			start_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			start_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			start_angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			act_we_i: in std_logic;
			act_addr_i: in std_logic_vector(4 downto 0);
			act_data_i: in std_logic_vector(63 downto 0);
			frame_start_i: in std_logic;
			snapshot_i: in std_logic_vector(SNAP_BITS - 1 downto 0);
			snapshot_valid_i: in std_logic;
			map_addr_o: out std_logic_vector(11 downto 0);
			map_we_o: out std_logic;
			map_wdata_o: out std_logic_vector(23 downto 0);
			map_data_i: in std_logic_vector(23 downto 0);
			span_addr_o: out std_logic_vector(4 downto 0);
			span_data_i: in std_logic_vector(SPAN_BITS - 1 downto 0);
			span_count_i: in std_logic_vector(5 downto 0);
			zwall_addr_o: out std_logic_vector(8 downto 0);
			zwall_data_i: in std_logic_vector(15 downto 0);
			cam_x_o: out std_logic_vector(POS_BITS - 1 downto 0);
			cam_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
			angle_o: out std_logic_vector(ANGLE_BITS - 1 downto 0);
			eye_o: out std_logic_vector(EYE_BITS - 1 downto 0);
			doors_o: out std_logic_vector(DOORS_BITS - 1 downto 0);
			player_x_o: out std_logic_vector(POS_BITS - 1 downto 0);
			player_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
			hud_o: out std_logic_vector(HUD_BITS - 1 downto 0);
			keypos_o: out std_logic_vector(KEYPOS_BITS - 1 downto 0);
			music_o: out std_logic_vector(1 downto 0);
			tint_o: out std_logic_vector(1 downto 0);
			fx_o: out std_logic_vector(FX_BITS - 1 downto 0);
			spr_addr_i: in std_logic_vector(4 downto 0);
			spr_data_o: out std_logic_vector(SPR_BITS - 1 downto 0);
			spr_count_o: out std_logic_vector(5 downto 0);
			render_start_o: out std_logic;
			busy_o: out std_logic;
			snd_valid_o: out std_logic;
			snd_ready_i: in std_logic;
			snd_data_o: out std_logic_vector(SND_BITS - 1 downto 0);
			level_loaded_o: out std_logic;
			state_addr_i: in std_logic_vector(6 downto 0);
			state_data_o: out std_logic_vector(63 downto 0);
			crc_o: out std_logic_vector(31 downto 0)
		);
	end component;

	constant PERIOD: time := 10 ns;
	-- Frames in each trace (the count check catches a truncated file)
	function trace_frames(t: natural) return natural is
	begin
		if (t = 5) then
			return 451; -- tools/model/golden4.py directed_script()
		elsif (t = 6) then
			return 164; -- tools/model/golden5.py alert_script()
		end if;
		return 1500;
	end function;
	constant FRAMES: natural := trace_frames(TRACE);

	-- Trace file: game2_trace.txt, game4_trace.txt, or game4d_trace.txt for TRACE = 5
	function trace_name(t: natural) return string is
	begin
		if (t = 5) then
			return GOLDEN_PREFIX & "4d_trace.txt";
		elsif (t = 6) then
			return GOLDEN_PREFIX & "5a_trace.txt";
		end if;
		return GOLDEN_PREFIX & integer'image(t) & "_trace.txt";
	end function;
	constant TRACE_FILE: string := trace_name(TRACE);

	-- Level file the loader supplies for level n (trace 4 plays level 3 as level 1,
	-- trace 5 plays the directed test map, build/level9.bin, for every level)
	function level_file(n: natural) return natural is
	begin
		if (TRACE = 5) then
			return 9;
		elsif (TRACE = 6) then
			return 10;
		end if;
		if ((TRACE = 4) and (n = 1)) then
			return 3;
		end if;
		return n;
	end function;
	constant MAX_BAD: natural := 3; -- Stop after this many differing frames
	type char_file_t is file of character;
	type tiles_t is array (0 to 4095) of std_logic_vector(23 downto 0);
	type spans_t is array (0 to 31) of std_logic_vector(SPAN_BITS - 1 downto 0);
	type zcols_t is array (0 to 6) of std_logic_vector(15 downto 0);
	type snd_log_t is array (0 to 8191) of std_logic_vector(SND_BITS - 1 downto 0);
	shared variable chk: checker_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	-- Core ports
	signal load_req, load_done: std_logic := '0';
	signal load_level: std_logic_vector(1 downto 0);
	signal start_x, start_y: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal start_angle: std_logic_vector(ANGLE_BITS - 1 downto 0) := (others => '0');
	signal act_we: std_logic := '0';
	signal act_addr: std_logic_vector(4 downto 0) := (others => '0');
	signal act_data: std_logic_vector(63 downto 0) := (others => '0');
	signal frame_start, snapshot_valid: std_logic := '0';
	signal snapshot: std_logic_vector(SNAP_BITS - 1 downto 0) := (others => '0');
	signal map_addr: std_logic_vector(11 downto 0);
	signal map_we: std_logic;
	signal map_wdata: std_logic_vector(23 downto 0);
	signal map_data: std_logic_vector(23 downto 0) := (others => '0');
	signal span_addr: std_logic_vector(4 downto 0);
	signal span_data: std_logic_vector(SPAN_BITS - 1 downto 0) := (others => '0');
	signal span_count: std_logic_vector(5 downto 0) := (others => '0');
	signal zwall_addr: std_logic_vector(8 downto 0);
	signal zwall_data: std_logic_vector(15 downto 0) := (others => '1');
	signal cam_x, cam_y, player_x, player_y: std_logic_vector(POS_BITS - 1 downto 0);
	signal angle: std_logic_vector(ANGLE_BITS - 1 downto 0);
	signal eye: std_logic_vector(EYE_BITS - 1 downto 0);
	signal doors: std_logic_vector(DOORS_BITS - 1 downto 0);
	signal hud: std_logic_vector(HUD_BITS - 1 downto 0);
	signal keypos: std_logic_vector(KEYPOS_BITS - 1 downto 0);
	signal music: std_logic_vector(1 downto 0);
	signal tint: std_logic_vector(1 downto 0);
	signal fx: std_logic_vector(FX_BITS - 1 downto 0);
	signal spr_addr: std_logic_vector(4 downto 0) := (others => '0');
	signal spr_data: std_logic_vector(SPR_BITS - 1 downto 0);
	signal spr_count: std_logic_vector(5 downto 0);
	signal render_start, busy: std_logic;
	signal snd_valid: std_logic;
	signal snd_data: std_logic_vector(SND_BITS - 1 downto 0);
	signal level_loaded: std_logic;
	signal state_addr: std_logic_vector(6 downto 0) := (others => '0');
	signal state_data: std_logic_vector(63 downto 0);
	signal crc: std_logic_vector(31 downto 0);
	-- Models
	signal ld_we: std_logic := '0';
	signal ld_addr: std_logic_vector(11 downto 0) := (others => '0');
	signal ld_data: std_logic_vector(23 downto 0) := (others => '0');
	signal spans: spans_t := (others => (others => '0'));
	signal zcols: zcols_t := (others => (others => '1'));
	signal snd_log: snd_log_t := (others => (others => '0'));
	signal snd_total: natural := 0;
	signal loads: natural := 0;

	-- Next decimal number of a trace line as 64 bits (the actor words do
	-- not fit an integer)
	procedure read_u64(l: inout line; v: out unsigned(63 downto 0)) is
		variable c: character := ' ';
		variable acc: unsigned(67 downto 0) := (others => '0');
	begin
		while (c = ' ') and (l'length > 0) loop
			read(l, c);
		end loop;
		while (c >= '0') and (c <= '9') loop
			acc := resize(acc * 10, 68) + (character'pos(c) - character'pos('0'));
			exit when (l'length = 0);
			read(l, c);
		end loop;
		v := acc(63 downto 0);
	end procedure;

	-- Skip the tag letter at the start of a trace line
	procedure read_tag(l: inout line; tag: character; ok: out boolean) is
		variable c: character;
	begin
		read(l, c);
		ok := (c = tag);
	end procedure;

	function field(v: std_logic_vector; hi: natural; lo: natural) return integer is
	begin
		return to_integer(unsigned(v(hi downto lo)));
	end function;
begin
	dut: game_core
		port map (
			clk_i => clk,
			rst_i => rst,
			load_req_o => load_req,
			load_level_o => load_level,
			load_done_i => load_done,
			start_x_i => start_x,
			start_y_i => start_y,
			start_angle_i => start_angle,
			act_we_i => act_we,
			act_addr_i => act_addr,
			act_data_i => act_data,
			frame_start_i => frame_start,
			snapshot_i => snapshot,
			snapshot_valid_i => snapshot_valid,
			map_addr_o => map_addr,
			map_we_o => map_we,
			map_wdata_o => map_wdata,
			map_data_i => map_data,
			span_addr_o => span_addr,
			span_data_i => span_data,
			span_count_i => span_count,
			zwall_addr_o => zwall_addr,
			zwall_data_i => zwall_data,
			cam_x_o => cam_x,
			cam_y_o => cam_y,
			angle_o => angle,
			eye_o => eye,
			doors_o => doors,
			player_x_o => player_x,
			player_y_o => player_y,
			hud_o => hud,
			keypos_o => keypos,
			music_o => music,
			tint_o => tint,
			fx_o => fx,
			spr_addr_i => spr_addr,
			spr_data_o => spr_data,
			spr_count_o => spr_count,
			render_start_o => render_start,
			busy_o => busy,
			snd_valid_o => snd_valid,
			snd_ready_i => '1',
			snd_data_o => snd_data,
			level_loaded_o => level_loaded,
			state_addr_i => state_addr,
			state_data_o => state_data,
			crc_o => crc
		);

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

	------------------------------------------------------------------
	-- Tile map: loader port and the core's port B, 1-clock read
	------------------------------------------------------------------
	process(clk)
		variable tiles: tiles_t := (others => (others => '0'));
	begin
		if rising_edge(clk) then
			if (ld_we = '1') then
				tiles(to_integer(unsigned(ld_addr))) := ld_data;
			end if;
			if (map_we = '1') then
				tiles(to_integer(unsigned(map_addr))) := map_wdata;
			end if;
			map_data <= tiles(to_integer(unsigned(map_addr)));
		end if;
	end process;

	------------------------------------------------------------------
	-- Last frame's spans and wall z, 1-clock reads
	------------------------------------------------------------------
	process(clk)
		variable col: natural;
	begin
		if rising_edge(clk) then
			span_data <= spans(to_integer(unsigned(span_addr)));
			col := to_integer(unsigned(zwall_addr));
			-- The trace gives wall z only at columns 136, 144 .. 184 (around the
			-- crosshair); every other column reads as far away (all ones)
			zwall_data <= (others => '1');
			for k in 0 to 6 loop
				if (col = 136 + 8 * k) then
					zwall_data <= zcols(k);
				end if;
			end loop;
		end if;
	end process;

	------------------------------------------------------------------
	-- Sound commands, logged in order
	------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if (snd_valid = '1') then
				snd_log(snd_total) <= snd_data;
				snd_total <= snd_total + 1;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Level loader model
	------------------------------------------------------------------
	process
		file f: char_file_t;
		variable status: file_open_status;
		variable c: character;
		variable n, cnt, b0, b1, b2, b3: natural;
		variable rec: std_logic_vector(63 downto 0);
	begin
		wait until rising_edge(clk) and (load_req = '1');
		n := level_file(to_integer(unsigned(load_level)));
		file_open(status, f, LEVEL_PREFIX & integer'image(n) & ".bin", read_mode);
		assert (status = open_ok) report "cannot open " & LEVEL_PREFIX & integer'image(n) & ".bin" severity failure;
		-- 4096 tiles of 3 bytes, least significant byte first
		for t in 0 to 4095 loop
			read(f, c);
			b0 := character'pos(c);
			read(f, c);
			b1 := character'pos(c);
			read(f, c);
			b2 := character'pos(c);
			ld_we <= '1';
			ld_addr <= std_logic_vector(to_unsigned(t, 12));
			ld_data <= std_logic_vector(to_unsigned(b2 * 65536 + b1 * 256 + b0, 24));
			wait until rising_edge(clk);
		end loop;
		ld_we <= '0';
		-- Start pose: x and y u32 (Q6.16), angle u16
		for k in 0 to 1 loop
			read(f, c);
			b0 := character'pos(c);
			read(f, c);
			b1 := character'pos(c);
			read(f, c);
			b2 := character'pos(c);
			read(f, c);
			b3 := character'pos(c);
			if (k = 0) then
				start_x <= std_logic_vector(to_unsigned(b2 * 65536 + b1 * 256 + b0, POS_BITS));
			else
				start_y <= std_logic_vector(to_unsigned(b2 * 65536 + b1 * 256 + b0, POS_BITS));
			end if;
		end loop;
		read(f, c);
		b0 := character'pos(c);
		read(f, c);
		b1 := character'pos(c);
		start_angle <= std_logic_vector(to_unsigned((b1 * 256 + b0) mod 1024, ANGLE_BITS));
		read(f, c);
		b0 := character'pos(c);
		read(f, c);
		b1 := character'pos(c);
		cnt := b1 * 256 + b0;
		-- cnt actor records of 8 bytes (LSB first); the rest of the 32 slots are cleared
		for a in 0 to 31 loop
			rec := (others => '0');
			if (a < cnt) then
				for k in 0 to 7 loop
					read(f, c);
					rec(8 * k + 7 downto 8 * k) := std_logic_vector(to_unsigned(character'pos(c), 8));
				end loop;
			end if;
			act_we <= '1';
			act_addr <= std_logic_vector(to_unsigned(a, 5));
			act_data <= rec;
			wait until rising_edge(clk);
			act_we <= '0';
			wait until rising_edge(clk);
		end loop;
		file_close(f);
		for k in 1 to 20 loop
			wait until rising_edge(clk);
		end loop;
		load_done <= '1';
		loads <= loads + 1;
		wait until rising_edge(clk);
		load_done <= '0';
	end process;

	------------------------------------------------------------------
	-- Frames
	------------------------------------------------------------------
	process
		file trace: text open read_mode is TRACE_FILE;
		variable l, ls, lr, lp, ln, lh, lx, li: line;
		variable ok, tag_ok, frame_ok: boolean;
		variable fnum, n, v1, v2, v3, v4, v5, v6, v7, base, nsp: integer;
		variable snap: std_logic_vector(SNAP_BITS - 1 downto 0);
		variable want, got: unsigned(63 downto 0);
		variable words: unsigned(91 * 64 - 1 downto 0);
		variable want_crc: std_logic_vector(31 downto 0);
		variable snd_before, loads_before, total_play, n_play: natural := 0;
		variable cycles, worst, worst_frame, total, worst_play, frames_done, bad: natural := 0;
		variable e: std_logic_vector(SND_BITS - 1 downto 0);
		variable hud_want: integer;
		type hud_field_t is array (0 to 19) of natural;
		constant HUD_LO: hud_field_t := (HUD_FLOW_LO, HUD_LEVEL_LO, HUD_HEALTH_LO, HUD_ARMOR_LO,
			HUD_AMMO_LO, HUD_WEAPON_LO, HUD_KEYS_LO, HUD_WFRAME_LO, HUD_BOB_LO, HUD_MSG_LO,
			HUD_KILLS_LO, HUD_TKILLS_LO, HUD_ITEMS_LO, HUD_TITEMS_LO, HUD_SECRETS_LO,
			HUD_TSECRETS_LO, HUD_TMIN_LO, HUD_TSEC_LO, HUD_AUTOMAP, HUD_DEBUG);
		constant HUD_HI: hud_field_t := (HUD_FLOW_HI, HUD_LEVEL_HI, HUD_HEALTH_HI, HUD_ARMOR_HI,
			HUD_AMMO_HI, HUD_WEAPON_HI, HUD_KEYS_HI, HUD_WFRAME_HI, HUD_BOB_HI, HUD_MSG_HI,
			HUD_KILLS_HI, HUD_TKILLS_HI, HUD_ITEMS_HI, HUD_TITEMS_HI, HUD_SECRETS_HI,
			HUD_TSECRETS_HI, HUD_TMIN_HI, HUD_TSEC_HI, HUD_AUTOMAP, HUD_DEBUG);
		variable flow, lvl: integer;
	begin
		wait until (rst = '0');
		-- The core loads level 1 after reset (Game.__init__)
		wait until rising_edge(clk) and (level_loaded = '1');
		for k in 1 to 5 loop
			wait until rising_edge(clk);
		end loop;
		while not endfile(trace) loop
			readline(trace, l);
			read_tag(l, 'F', tag_ok);
			read(l, fnum);
			hread(l, snap);
			readline(trace, ls);
			readline(trace, lr);
			readline(trace, lp);
			readline(trace, ln);
			readline(trace, lh);
			readline(trace, lx);
			readline(trace, li);
			frame_ok := true;
			-- One frame: frame start, snapshot 2 clocks later
			snd_before := snd_total;
			loads_before := loads;
			frame_start <= '1';
			wait until rising_edge(clk);
			frame_start <= '0';
			wait until rising_edge(clk);
			snapshot <= snap;
			snapshot_valid <= '1';
			wait until rising_edge(clk);
			snapshot_valid <= '0';
			cycles := 0;
			loop
				wait until rising_edge(clk);
				cycles := cycles + 1;
				exit when (render_start = '1') or (cycles > 2000000);
			end loop;
			chk.check(render_start = '1', "frame " & integer'image(fnum) & ": no render_start");
			total := total + cycles;
			if (cycles > worst) then
				worst := cycles;
				worst_frame := fnum;
			end if;
			-- Let the sound commands go out
			for k in 1 to 8 loop
				wait until rising_edge(clk);
			end loop;

			-- S: the 91 state words
			read_tag(ls, 'S', tag_ok);
			for k in 0 to STATE_WORDS - 1 loop
				read_u64(ls, want);
				state_addr <= std_logic_vector(to_unsigned(k, 7));
				-- One edge to apply the address, one for the registered read
				wait until rising_edge(clk);
				wait until rising_edge(clk);
				got := unsigned(state_data);
				words(64 * k + 63 downto 64 * k) := want;
				if (got /= want) then
					if (frame_ok) then
						tb_print("frame " & integer'image(fnum) & " state word " & integer'image(k) &
							": got " & to_hex(got) & " want " & to_hex(want));
					end if;
					frame_ok := false;
				end if;
			end loop;
			flow := to_integer(words(63 downto 0));
			lvl := to_integer(words(127 downto 64));
			if (loads = loads_before) then
				-- Frames without a level load
				if (cycles > worst_play) then
					worst_play := cycles;
				end if;
				if (flow = 2) then
					total_play := total_play + cycles;
					n_play := n_play + 1;
				end if;
			end if;

			-- R: checksum
			read_tag(lr, 'R', tag_ok);
			hread(lr, want_crc);
			if (crc /= want_crc) then
				tb_print("frame " & integer'image(fnum) & " crc: got " & to_hex(crc) & " want " & to_hex(want_crc));
				frame_ok := false;
			end if;

			-- P: sprite table
			read_tag(lp, 'P', tag_ok);
			read(lp, n);
			if (to_integer(unsigned(spr_count)) /= n) then
				tb_print("frame " & integer'image(fnum) & " sprites: got " &
					integer'image(to_integer(unsigned(spr_count))) & " want " & integer'image(n));
				frame_ok := false;
			end if;
			for k in 0 to n - 1 loop
				read(lp, v1);
				read(lp, v2);
				read(lp, v3);
				read(lp, v4);
				read(lp, v5);
				read(lp, v6);
				read(lp, v7);
				spr_addr <= std_logic_vector(to_unsigned(k, 5));
				wait until rising_edge(clk);
				wait until rising_edge(clk);
				ok := (field(spr_data, SPR_IDX_HI, SPR_IDX_LO) = v1) and
					(field(spr_data, SPR_X_HI, SPR_X_LO) = v2) and
					(field(spr_data, SPR_Y_HI, SPR_Y_LO) = v3) and
					(field(spr_data, SPR_FRAME_HI, SPR_FRAME_LO) = v4) and
					(field(spr_data, SPR_LIGHT_HI, SPR_LIGHT_LO) = v5) and
					(field(spr_data, SPR_TARGET, SPR_BRIGHT) = v6) and
					(field(spr_data, SPR_FLOOR_HI, SPR_FLOOR_LO) = v7) and
					(unsigned(spr_data(63 downto SPR_FLOOR_HI + 1)) = 0);
				if (not ok) then
					tb_print("frame " & integer'image(fnum) & " sprite " & integer'image(k) & ": got " &
						to_hex(spr_data) & " want " & integer'image(v1) & " " & integer'image(v2) & " " &
						integer'image(v3) & " " & integer'image(v4) & " " & integer'image(v5) & " " &
						integer'image(v6) & " " & integer'image(v7));
					frame_ok := false;
				end if;
			end loop;

			-- N: sound commands (id, volume, pan, priority) in order
			read_tag(ln, 'N', tag_ok);
			read(ln, n);
			if (snd_total - snd_before /= n) then
				tb_print("frame " & integer'image(fnum) & " sounds: got " &
					integer'image(snd_total - snd_before) & " want " & integer'image(n));
				frame_ok := false;
			end if;
			for k in 0 to n - 1 loop
				read(ln, v1);
				read(ln, v2);
				read(ln, v3);
				read(ln, v4);
				e := snd_log(snd_before + k);
				ok := (field(e, SND_ID_HI, SND_ID_LO) = v1) and (field(e, SND_VOL_HI, SND_VOL_LO) = v2) and
					(to_integer(signed(e(SND_PAN_HI downto SND_PAN_LO))) = v3) and
					(field(e, SND_PRI_HI, SND_PRI_LO) = v4);
				if (not ok) then
					tb_print("frame " & integer'image(fnum) & " sound " & integer'image(k) & ": got id " &
						integer'image(field(e, SND_ID_HI, SND_ID_LO)) & " vol " &
						integer'image(field(e, SND_VOL_HI, SND_VOL_LO)) & " pan " &
						integer'image(to_integer(signed(e(SND_PAN_HI downto SND_PAN_LO)))) & " pri " &
						integer'image(field(e, SND_PRI_HI, SND_PRI_LO)) & "; want " & integer'image(v1) &
						" " & integer'image(v2) & " " & integer'image(v3) & " " & integer'image(v4));
					frame_ok := false;
				end if;
			end loop;

			-- H: HUD fields in golden2.HUD_KEYS order
			read_tag(lh, 'H', tag_ok);
			for k in 0 to 19 loop
				read(lh, hud_want);
				if (field(hud, HUD_HI(k), HUD_LO(k)) /= hud_want) then
					tb_print("frame " & integer'image(fnum) & " hud field " & integer'image(k) & ": got " &
						integer'image(field(hud, HUD_HI(k), HUD_LO(k))) & " want " & integer'image(hud_want));
					frame_ok := false;
				end if;
			end loop;

			-- Screen tint: one more value after the HUD fields
			read(lh, hud_want);
			if (to_integer(unsigned(tint)) /= hud_want) then
				tb_print("frame " & integer'image(fnum) & " tint: got " &
					integer'image(to_integer(unsigned(tint))) & " want " & integer'image(hud_want));
				frame_ok := false;
			end if;

			-- X: effects register, light offsets of light types 0..3 (5-bit signed) and the
			-- animation frame
			read_tag(lx, 'X', tag_ok);
			frame_ok := frame_ok and tag_ok;
			for k in 0 to 3 loop
				read(lx, hud_want);
				if (to_integer(signed(fx(FX_LMOD_W * k + FX_LMOD_W - 1 downto FX_LMOD_W * k))) /= hud_want) then
					tb_print("frame " & integer'image(fnum) & " light offset " & integer'image(k) & ": got " &
						integer'image(to_integer(signed(fx(FX_LMOD_W * k + FX_LMOD_W - 1 downto FX_LMOD_W * k)))) &
						" want " & integer'image(hud_want));
					frame_ok := false;
				end if;
			end loop;
			read(lx, hud_want);
			if (to_integer(unsigned(fx(FX_ANIM_HI downto FX_ANIM_LO))) /= hud_want) then
				tb_print("frame " & integer'image(fnum) & " anim: got " &
					integer'image(to_integer(unsigned(fx(FX_ANIM_HI downto FX_ANIM_LO)))) & " want " &
					integer'image(hud_want));
				frame_ok := false;
			end if;

			-- Renderer registers against the state words (tools/model/game.py state_words):
			-- word 5 packs eye (bits 6..0) and floor height z (bits 15..8); the renderer's eye
			-- is their sum
			ok := (unsigned(player_x) = words(64 * 2 + POS_BITS - 1 downto 64 * 2)) and
				(unsigned(player_y) = words(64 * 3 + POS_BITS - 1 downto 64 * 3)) and
				(unsigned(angle) = words(64 * 4 + ANGLE_BITS - 1 downto 64 * 4)) and
				(unsigned(eye) = minimum(127, to_integer(words(64 * 5 + 15 downto 64 * 5 + 8)) +
				to_integer(words(64 * 5 + 6 downto 64 * 5))));
			for d in 0 to 7 loop
				-- Door d: words x, y, open, state, timer after the 19 scalars; state 0 must
				-- give an all-zero door entry
				base := 64 * (19 + 5 * d);
				if (words(base + 64 * 3 + 63 downto base + 64 * 3) = 0) then
					if (unsigned(doors(DOOR_BITS * d + DOOR_BITS - 1 downto DOOR_BITS * d)) /= 0) then
						ok := false;
					end if;
				elsif (unsigned(doors(DOOR_BITS * d + DOOR_X_HI downto DOOR_BITS * d + DOOR_X_LO)) /= words(base + 5 downto base)) or
					(unsigned(doors(DOOR_BITS * d + DOOR_Y_HI downto DOOR_BITS * d + DOOR_Y_LO)) /= words(base + 64 + 5 downto base + 64)) or
					(unsigned(doors(DOOR_BITS * d + DOOR_OPEN_HI downto DOOR_BITS * d + DOOR_OPEN_LO)) /= words(base + 128 + 6 downto base + 128)) then
					ok := false;
				end if;
			end loop;
			if ((flow = 2) or (flow = 3) or (flow = 4)) then
				ok := ok and (to_integer(unsigned(music)) = lvl);
			else
				ok := ok and (unsigned(music) = 0);
			end if;
			if (not ok) then
				tb_print("frame " & integer'image(fnum) & ": renderer registers differ from the state words");
				frame_ok := false;
			end if;
			chk.check(busy = '0', "idle after render_start");

			-- I: this frame's render output = next frame's hitscan input
			read_tag(li, 'I', tag_ok);
			read(li, nsp);
			for k in 0 to nsp - 1 loop
				read(li, v1);
				read(li, v2);
				read(li, v3);
				read(li, v4);
				-- Span: actor index, first column, last column, z (SPAN_* fields, LSB first)
				spans(k) <= std_logic_vector(to_unsigned(0, SPAN_BITS - 39)) &
					std_logic_vector(to_unsigned(v4, 16)) & std_logic_vector(to_unsigned(v3, 9)) &
					std_logic_vector(to_unsigned(v2, 9)) & std_logic_vector(to_unsigned(v1, 5));
			end loop;
			span_count <= std_logic_vector(to_unsigned(nsp, 6));
			for k in 0 to 6 loop
				read(li, v1);
				zcols(k) <= std_logic_vector(to_unsigned(v1, 16));
			end loop;

			chk.check(frame_ok, "frame " & integer'image(fnum) & " matches the model");
			frames_done := frames_done + 1;
			if (not frame_ok) then
				bad := bad + 1;
				exit when (bad >= MAX_BAD);
			end if;
			for k in 1 to 5 loop
				wait until rising_edge(clk);
			end loop;
		end loop;
		tb_print("frames " & integer'image(frames_done) & ", bad " & integer'image(bad) &
			", clocks per frame: average " & integer'image(total / frames_done) & ", worst " &
			integer'image(worst) & " (frame " & integer'image(worst_frame) & "), level loads " &
			integer'image(loads) & "; without a load: worst " & integer'image(worst_play) &
			", PLAYING average " & integer'image(total_play / n_play));
		chk.check(frames_done = FRAMES, "frames in the trace: " & integer'image(frames_done));
		finished <= true;
		tb_finish("tb_game_core", chk.checks, chk.errors);
		wait;
	end process;
end arch;

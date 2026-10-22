--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Frame Renderer Testbench
-- Module Name:    tb_frame_renderer
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for frame_renderer (walls, then
--                 sprites, then overlay) against whole frames of the model
--                 (tools/model/frame.py via build_assets.py:
--                 sim/golden/frame_cases.txt): a briefing screen, the first
--                 two playing frames after the level 1 load (back to back,
--                 so the minimap's seen set grows), a frame with sprites
--                 and an opening door, a debug-overlay frame, and (stage 4)
--                 two frames of the level-3 heights session (stairs, the
--                 ramp hall), where sprites stand on raised floors and the
--                 sprite engine clips against render_top's clip lists.
--                 Per case it loads the tile map and sprite table into
--                 behavioral RAMs (1-clock reads), packs the camera, door
--                 table, HUD word, key positions and debug counters, and
--                 fills the framebuffer with (expected xor 5A), so every
--                 pixel the renderer fails to write shows as a mismatch.
--                 Cases with clear = 1 pulse seen_clear_i first (as after a
--                 level load); start_i comes on the same clock (even cases)
--                 or 100 clocks later, during the clear (odd cases), to
--                 cover both ways a start waits for the clear.
--                 Art reads go to a behavioral arbiter port (random grants,
--                 read data SRAM_LATENCY clocks after the grant) serving
--                 build/art.bin at ART_BASE; the pixel port is ready
--                 READY_PCT percent of the clocks.
--                 Checks per case: whole image equal, buffer bit of every
--                 write, one done_o, busy_o low after it, and (3D frames)
--                 the hitscan span list equal to the model's.
--                 Prints the busy clocks (seen clear included) and
--                 cycles_o (render time only) per case.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, std.textio, tb_pkg, frame_renderer and
--                 everything under it, render_types_pkg, game_pkg, hw_pkg,
--                 build/art.bin
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
use work.hw_pkg.all;
use work.game_pkg.all;
use work.render_types_pkg.all;

entity tb_frame_renderer is
	generic(
		GOLDEN_FILE: string := "../../sim/golden/frame_cases.txt"; -- Relative to the run directory
		ART_FILE: string := "../../build/art.bin";
		READY_PCT: natural := 80; -- Pixel port ready probability, percent
		GNT_PCT: natural := 50 -- SRAM grant probability per clock, percent
	);
end tb_frame_renderer;

architecture arch of tb_frame_renderer is
	component frame_renderer is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			cam_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			cam_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			eye_i: in std_logic_vector(EYE_BITS - 1 downto 0);
			doors_i: in std_logic_vector(DOORS_BITS - 1 downto 0);
			fx_i: in std_logic_vector(FX_BITS - 1 downto 0);
			player_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			player_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			hud_i: in std_logic_vector(HUD_BITS - 1 downto 0);
			keypos_i: in std_logic_vector(KEYPOS_BITS - 1 downto 0);
			debug_i: in std_logic_vector(4 * 24 - 1 downto 0);
			buf_i: in std_logic;
			spr_addr_o: out std_logic_vector(4 downto 0);
			spr_data_i: in std_logic_vector(SPR_BITS - 1 downto 0);
			spr_count_i: in std_logic_vector(5 downto 0);
			gz_addr_i: in std_logic_vector(8 downto 0);
			gz_data_o: out std_logic_vector(15 downto 0);
			span_raddr_i: in std_logic_vector(4 downto 0);
			span_rdata_o: out std_logic_vector(SPAN_BITS - 1 downto 0);
			span_count_o: out std_logic_vector(5 downto 0);
			seen_clear_i: in std_logic;
			map_a_addr_o: out std_logic_vector(11 downto 0);
			map_a_data_i: in std_logic_vector(23 downto 0);
			map_b_addr_o: out std_logic_vector(11 downto 0);
			map_b_data_i: in std_logic_vector(23 downto 0);
			m_req_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0);
			pix_valid_o: out std_logic;
			pix_ready_i: in std_logic;
			pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic;
			cycles_o: out std_logic_vector(23 downto 0);
			sprite_pixels_o: out std_logic_vector(15 downto 0)
		);
	end component;

	constant PERIOD: time := 10 ns;
	constant N_CASES: natural := 7;
	constant PIXELS: natural := 320 * 240;
	constant ART_MAX: natural := 262144; -- Art window of the SRAM model, bytes
	constant SRAM_LATENCY: natural := 4; -- Clocks from grant to rvalid

	-- Framebuffer and expected image
	type image_store_t is protected
		procedure put(addr: natural; value: natural);
		impure function get(addr: natural) return natural;
	end protected image_store_t;
	type image_store_t is protected body
		type image_t is array (0 to PIXELS - 1) of natural range 0 to 255;
		variable img: image_t := (others => 0);
		procedure put(addr: natural; value: natural) is
		begin
			img(addr) := value;
		end procedure;
		impure function get(addr: natural) return natural is
		begin
			return img(addr);
		end function;
	end protected body image_store_t;

	shared variable chk: checker_t;
	shared variable fb: image_store_t;
	shared variable exp: image_store_t;

	type tiles_t is array (0 to 4095) of std_logic_vector(23 downto 0);
	type spr_ram_t is array (0 to 31) of std_logic_vector(SPR_BITS - 1 downto 0);
	type char_file_t is file of character;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal start, seen_clear: std_logic := '0';
	signal buf: std_logic := '0';
	signal cam_x, cam_y, player_x, player_y: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal angle: std_logic_vector(ANGLE_BITS - 1 downto 0) := (others => '0');
	signal eye: std_logic_vector(EYE_BITS - 1 downto 0) := (others => '0');
	signal doors: std_logic_vector(DOORS_BITS - 1 downto 0) := (others => '0');
	signal fx: std_logic_vector(FX_BITS - 1 downto 0) := (others => '0');
	signal hud: std_logic_vector(HUD_BITS - 1 downto 0) := (others => '0');
	signal keypos: std_logic_vector(KEYPOS_BITS - 1 downto 0) := (others => '0');
	signal debug: std_logic_vector(4 * 24 - 1 downto 0) := (others => '0');
	signal tiles: tiles_t := (others => (others => '0'));
	signal sprs: spr_ram_t := (others => (others => '0'));
	signal spr_count: std_logic_vector(5 downto 0) := (others => '0');
	signal spr_addr: std_logic_vector(4 downto 0);
	signal spr_data: std_logic_vector(SPR_BITS - 1 downto 0) := (others => '0');
	signal span_raddr: std_logic_vector(4 downto 0) := (others => '0');
	signal span_rdata: std_logic_vector(SPAN_BITS - 1 downto 0);
	signal span_count: std_logic_vector(5 downto 0);
	signal map_a_addr, map_b_addr: std_logic_vector(11 downto 0);
	signal map_a_data, map_b_data: std_logic_vector(23 downto 0) := (others => '0');
	signal m_req: std_logic;
	signal m_addr: std_logic_vector(18 downto 0);
	signal m_gnt: std_logic;
	signal gnt_ok: std_logic := '0';
	signal m_rvalid: std_logic := '0';
	signal m_rdata: std_logic_vector(7 downto 0) := (others => '0');
	signal pix_valid: std_logic;
	signal pix_ready: std_logic := '0';
	signal pix_data: std_logic_vector(PIXW_BITS - 1 downto 0);
	signal busy, done: std_logic;
	signal cycles: std_logic_vector(23 downto 0);
	signal dones: natural := 0;
	signal bad_buf: natural := 0;
	signal bad_addr: natural := 0;

	function hexval(c: character) return natural is
	begin
		if ((c >= '0') and (c <= '9')) then
			return character'pos(c) - character'pos('0');
		else
			return character'pos(c) - character'pos('A') + 10;
		end if;
	end function;

	function u(v: integer; n: natural) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned(v, n));
	end function;
begin
	dut: frame_renderer
		port map (
			clk_i => clk,
			rst_i => rst,
			start_i => start,
			cam_x_i => cam_x,
			cam_y_i => cam_y,
			angle_i => angle,
			eye_i => eye,
			doors_i => doors,
			fx_i => fx,
			player_x_i => player_x,
			player_y_i => player_y,
			hud_i => hud,
			keypos_i => keypos,
			debug_i => debug,
			buf_i => buf,
			spr_addr_o => spr_addr,
			spr_data_i => spr_data,
			spr_count_i => spr_count,
			gz_addr_i => (others => '0'),
			gz_data_o => open,
			span_raddr_i => span_raddr,
			span_rdata_o => span_rdata,
			span_count_o => span_count,
			seen_clear_i => seen_clear,
			map_a_addr_o => map_a_addr,
			map_a_data_i => map_a_data,
			map_b_addr_o => map_b_addr,
			map_b_data_i => map_b_data,
			m_req_o => m_req,
			m_addr_o => m_addr,
			m_gnt_i => m_gnt,
			m_rvalid_i => m_rvalid,
			m_rdata_i => m_rdata,
			pix_valid_o => pix_valid,
			pix_ready_i => pix_ready,
			pix_data_o => pix_data,
			busy_o => busy,
			done_o => done,
			cycles_o => cycles,
			sprite_pixels_o => open
		);

	-- Tile map (two read ports) and sprite table, read one clock after the address
	process(clk)
	begin
		if rising_edge(clk) then
			map_a_data <= tiles(to_integer(unsigned(map_a_addr)));
			map_b_data <= tiles(to_integer(unsigned(map_b_addr)));
			spr_data <= sprs(to_integer(unsigned(spr_addr)));
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

	-- Random back-pressure on the pixel port and random SRAM grants
	process
		variable s1, s2: positive := 41;
		variable x: real;
	begin
		wait until rising_edge(clk);
		uniform(s1, s2, x);
		if (x * 100.0 < real(READY_PCT)) then
			pix_ready <= '1';
		else
			pix_ready <= '0';
		end if;
		uniform(s1, s2, x);
		if (x * 100.0 < real(GNT_PCT)) then
			gnt_ok <= '1';
		else
			gnt_ok <= '0';
		end if;
	end process;

	-- SRAM master port: the grant comes combinationally (like sram_arbiter),
	-- read data SRAM_LATENCY clocks later, from art.bin at ART_BASE (the
	-- file is read inside the process: xsim leaves an architecture-level
	-- constant filled from a file at zero)
	m_gnt <= m_req and gnt_ok;

	process
		type art_t is array (0 to ART_MAX - 1) of natural range 0 to 255;
		type pipe_t is array (1 to SRAM_LATENCY) of integer;
		file f: char_file_t;
		variable c: character;
		variable art: art_t := (others => 0);
		variable n: natural := 0;
		variable pipe: pipe_t := (others => -1); -- Address in flight, -1 = none
		variable a: integer;
	begin
		file_open(f, ART_FILE, read_mode);
		while ((not endfile(f)) and (n < ART_MAX)) loop
			read(f, c);
			art(n) := character'pos(c);
			n := n + 1;
		end loop;
		file_close(f);
		tb_print("art.bin: " & integer'image(n) & " bytes");
		loop
			wait until rising_edge(clk);
			a := pipe(SRAM_LATENCY);
			if (a >= 0) then
				m_rvalid <= '1';
				m_rdata <= std_logic_vector(to_unsigned(art(a), 8));
			else
				m_rvalid <= '0';
				m_rdata <= (others => 'X');
			end if;
			for k in SRAM_LATENCY downto 2 loop
				pipe(k) := pipe(k - 1);
			end loop;
			pipe(1) := -1;
			if (m_gnt = '1') then
				a := to_integer(unsigned(m_addr)) - ART_BASE;
				if ((a < 0) or (a >= n)) then
					bad_addr <= bad_addr + 1;
					a := 0;
				end if;
				pipe(1) := a;
			end if;
		end loop;
	end process;

	-- Apply pixel writes to the framebuffer, count done pulses
	process(clk)
	begin
		if rising_edge(clk) then
			if ((pix_valid = '1') and (pix_ready = '1')) then
				fb.put(to_integer(unsigned(pix_data(PIXW_ADDR_HI downto PIXW_ADDR_LO))),
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

	process
		file gf: text;
		variable l: line;
		variable c: character;
		variable name: string(1 to 12);
		variable s6: string(1 to 6);
		variable s640: string(1 to 640);
		variable hv, n, clear, flow: integer;
		variable v1, v2, v3, v4, v5, v6, v7: integer;
		type hvals_t is array (0 to 19) of integer;
		variable h: hvals_t;
		variable hw: std_logic_vector(HUD_BITS - 1 downto 0);
		variable kp: std_logic_vector(KEYPOS_BITS - 1 downto 0);
		variable dv: std_logic_vector(4 * 24 - 1 downto 0);
		variable dw: std_logic_vector(DOORS_BITS - 1 downto 0);
		variable fxw: std_logic_vector(FX_BITS - 1 downto 0);
		variable e: std_logic_vector(SPR_BITS - 1 downto 0);
		variable t: tiles_t;
		variable st: spr_ram_t;
		variable clocks: natural;
		variable mism, want, got: natural;
		variable dones0: natural;
		variable sp: integer_vector(0 to 3);
	begin
		file_open(gf, GOLDEN_FILE, read_mode);
		wait until (rst = '0');
		wait until rising_edge(clk);
		for k in 0 to N_CASES - 1 loop
			-- C k name clear
			readline(gf, l);
			read(l, c);
			read(l, hv);
			read(l, c);
			name := (others => ' ');
			for i in name'range loop
				read(l, c);
				exit when (c = ' ');
				name(i) := c;
			end loop;
			read(l, clear);
			-- K camera x, y, angle, eye
			readline(gf, l);
			read(l, c);
			read(l, v1);
			read(l, v2);
			read(l, v3);
			read(l, v4);
			cam_x <= u(v1, POS_BITS);
			cam_y <= u(v2, POS_BITS);
			angle <= u(v3, ANGLE_BITS);
			eye <= u(v4, EYE_BITS);
			-- L player x, y, angle (the angle equals the camera's)
			readline(gf, l);
			read(l, c);
			read(l, v1);
			read(l, v2);
			read(l, v3);
			player_x <= u(v1, POS_BITS);
			player_y <= u(v2, POS_BITS);
			-- X effects: light offsets of the four light types (signed), animation frame
			readline(gf, l);
			read(l, c);
			for i in 0 to 3 loop
				read(l, v4);
				fxw(FX_LMOD_W * i + FX_LMOD_W - 1 downto FX_LMOD_W * i) := std_logic_vector(to_signed(v4, FX_LMOD_W));
			end loop;
			read(l, v4);
			fxw(FX_ANIM_HI downto FX_ANIM_LO) := u(v4, 2);
			fx <= fxw;
			-- O door table: n, then x y open per active door
			readline(gf, l);
			read(l, c);
			read(l, n);
			dw := (others => '0');
			for i in 0 to n - 1 loop
				read(l, v1);
				read(l, v2);
				read(l, v3);
				dw(i * DOOR_BITS + DOOR_X_HI downto i * DOOR_BITS + DOOR_X_LO) := u(v1, 6);
				dw(i * DOOR_BITS + DOOR_Y_HI downto i * DOOR_BITS + DOOR_Y_LO) := u(v2, 6);
				dw(i * DOOR_BITS + DOOR_OPEN_HI downto i * DOOR_BITS + DOOR_OPEN_LO) := u(v3, 7);
			end loop;
			doors <= dw;
			-- P sprite table: n, then index x y frame light flags (bit 0 bright, bit 1 target)
			-- floor (stage 4: floor height under the sprite)
			readline(gf, l);
			read(l, c);
			read(l, n);
			st := (others => (others => '0'));
			for i in 0 to n - 1 loop
				read(l, v1);
				read(l, v2);
				read(l, v3);
				read(l, v4);
				read(l, v5);
				read(l, v6);
				read(l, v7);
				e := (others => '0');
				e(SPR_IDX_HI downto SPR_IDX_LO) := u(v1, 5);
				e(SPR_X_HI downto SPR_X_LO) := u(v2, 16);
				e(SPR_Y_HI downto SPR_Y_LO) := u(v3, 16);
				e(SPR_FRAME_HI downto SPR_FRAME_LO) := u(v4, 8);
				e(SPR_LIGHT_HI downto SPR_LIGHT_LO) := u(v5, 4);
				e(SPR_BRIGHT) := '1' when ((v6 mod 2) = 1) else '0';
				e(SPR_TARGET) := '1' when (((v6 / 2) mod 2) = 1) else '0';
				e(SPR_FLOOR_HI downto SPR_FLOOR_LO) := u(v7, 7);
				st(i) := e;
			end loop;
			sprs <= st;
			spr_count <= u(n, 6);
			-- H HUD values in the order of HUD_KEYS (tools/model/golden2.py)
			readline(gf, l);
			read(l, c);
			for i in 0 to 19 loop
				read(l, hv);
				h(i) := hv;
			end loop;
			flow := h(0);
			hw := (others => '0');
			hw(HUD_FLOW_HI downto HUD_FLOW_LO) := u(h(0), 3);
			hw(HUD_LEVEL_HI downto HUD_LEVEL_LO) := u(h(1), 2);
			hw(HUD_HEALTH_HI downto HUD_HEALTH_LO) := u(h(2), 8);
			hw(HUD_ARMOR_HI downto HUD_ARMOR_LO) := u(h(3), 8);
			hw(HUD_AMMO_HI downto HUD_AMMO_LO) := u(h(4), 8);
			hw(HUD_WEAPON_HI downto HUD_WEAPON_LO) := u(h(5), 2);
			hw(HUD_KEYS_HI downto HUD_KEYS_LO) := u(h(6), 2);
			hw(HUD_WFRAME_HI downto HUD_WFRAME_LO) := u(h(7), 8);
			hw(HUD_BOB_HI downto HUD_BOB_LO) := u(h(8), 3);
			hw(HUD_MSG_HI downto HUD_MSG_LO) := u(h(9), 4);
			hw(HUD_KILLS_HI downto HUD_KILLS_LO) := u(h(10), 6);
			hw(HUD_TKILLS_HI downto HUD_TKILLS_LO) := u(h(11), 6);
			hw(HUD_ITEMS_HI downto HUD_ITEMS_LO) := u(h(12), 6);
			hw(HUD_TITEMS_HI downto HUD_TITEMS_LO) := u(h(13), 6);
			hw(HUD_SECRETS_HI downto HUD_SECRETS_LO) := u(h(14), 4);
			hw(HUD_TSECRETS_HI downto HUD_TSECRETS_LO) := u(h(15), 4);
			hw(HUD_TMIN_HI downto HUD_TMIN_LO) := u(h(16), 7);
			hw(HUD_TSEC_HI downto HUD_TSEC_LO) := u(h(17), 6);
			if (h(18) /= 0) then
				hw(HUD_AUTOMAP) := '1';
			end if;
			if (h(19) /= 0) then
				hw(HUD_DEBUG) := '1';
			end if;
			hud <= hw;
			-- A keys on the floor: kind (6 blue, 7 red), tile x, tile y
			readline(gf, l);
			read(l, c);
			read(l, n);
			kp := (others => '0');
			for i in 0 to n - 1 loop
				read(l, v1);
				read(l, v2);
				read(l, v3);
				-- Each key field: present bit, then tile x (6 bits), then tile y (6 bits)
				if (v1 = 6) then
					kp(KEYPOS_BLUE) := '1';
					kp(KEYPOS_BLUE + 6 downto KEYPOS_BLUE + 1) := u(v2, 6);
					kp(KEYPOS_BLUE + 12 downto KEYPOS_BLUE + 7) := u(v3, 6);
				else
					kp(KEYPOS_RED) := '1';
					kp(KEYPOS_RED + 6 downto KEYPOS_RED + 1) := u(v2, 6);
					kp(KEYPOS_RED + 12 downto KEYPOS_RED + 7) := u(v3, 6);
				end if;
			end loop;
			keypos <= kp;
			-- D 4 debug counters
			readline(gf, l);
			read(l, c);
			for i in 0 to 3 loop
				read(l, hv);
				dv(24 * i + 23 downto 24 * i) := u(hv, 24);
			end loop;
			debug <= dv;
			-- M 4096 tile words, 6 hex digits each
			readline(gf, l);
			read(l, c);
			for i in 0 to 4095 loop
				read(l, c);
				read(l, s6);
				hv := 0;
				for j in 1 to 6 loop
					hv := hv * 16 + hexval(s6(j));
				end loop;
				t(i) := u(hv, 24);
			end loop;
			tiles <= t;
			-- E expected image; the framebuffer starts as its complement pattern
			readline(gf, l);
			for y in 0 to 239 loop
				readline(gf, l);
				read(l, s640);
				for x in 0 to 319 loop
					want := hexval(s640(2 * x + 1)) * 16 + hexval(s640(2 * x + 2));
					exp.put(y * 320 + x, want);
					fb.put(y * 320 + x, to_integer(unsigned(u(want, 8) xor x"5A")));
				end loop;
			end loop;
			if ((k mod 2) = 1) then
				buf <= '1';
			else
				buf <= '0';
			end if;
			wait until rising_edge(clk);
			wait until rising_edge(clk);

			-- Start the frame (after a seen clear when the case asks for one)
			dones0 := dones;
			clocks := 0;
			if (clear = 1) then
				-- Even cases start on the clear's clock, odd ones 100 clocks after it
				seen_clear <= '1';
				if ((k mod 2) = 0) then
					start <= '1';
				end if;
				wait until rising_edge(clk);
				seen_clear <= '0';
				start <= '0';
				if ((k mod 2) = 1) then
					for i in 1 to 100 loop
						wait until rising_edge(clk);
					end loop;
					start <= '1';
					wait until rising_edge(clk);
					start <= '0';
				end if;
			else
				start <= '1';
				wait until rising_edge(clk);
				start <= '0';
			end if;
			while (done /= '1') loop
				wait until rising_edge(clk);
				if (busy = '1') then
					clocks := clocks + 1;
				end if;
			end loop;
			for i in 1 to 4 loop
				wait until rising_edge(clk);
			end loop;
			chk.check(busy = '0', "case " & integer'image(k) & ": busy after done");
			chk.check(dones = dones0 + 1, "case " & integer'image(k) & ": one done pulse");
			tb_print("case " & integer'image(k) & " " & name & ": " & integer'image(clocks) &
				" busy clocks, cycles_o " & integer'image(to_integer(unsigned(cycles))));

			-- Whole image
			mism := 0;
			for i in 0 to PIXELS - 1 loop
				want := exp.get(i);
				got := fb.get(i);
				if (want /= got) then
					if (mism < 8) then
						tb_print("case " & integer'image(k) & " pixel (" & integer'image(i mod 320) &
							", " & integer'image(i / 320) & "): got " & integer'image(got) &
							", expected " & integer'image(want));
					end if;
					mism := mism + 1;
				end if;
			end loop;
			chk.check(mism = 0, "case " & integer'image(k) & ": " & integer'image(mism) &
				" pixels differ");

			-- Q hitscan spans (3D frames only: text screens leave the last list)
			readline(gf, l);
			read(l, c);
			read(l, n);
			if ((flow /= 0) and (flow /= 1) and (flow /= 5) and (flow /= 6)) then
				chk.check(to_integer(unsigned(span_count)) = n, "case " & integer'image(k) &
					": span count " & integer'image(to_integer(unsigned(span_count))) & " want " &
					integer'image(n));
				for j in 0 to n - 1 loop
					for f in 0 to 3 loop
						read(l, sp(f));
					end loop;
					span_raddr <= u(j, 5);
					wait until rising_edge(clk);
					wait until rising_edge(clk);
					chk.check((to_integer(unsigned(span_rdata(SPAN_IDX_HI downto SPAN_IDX_LO))) = sp(0)) and
						(to_integer(unsigned(span_rdata(SPAN_X0_HI downto SPAN_X0_LO))) = sp(1)) and
						(to_integer(unsigned(span_rdata(SPAN_X1_HI downto SPAN_X1_LO))) = sp(2)) and
						(to_integer(unsigned(span_rdata(SPAN_Z_HI downto SPAN_Z_LO))) = sp(3)),
						"case " & integer'image(k) & " span " & integer'image(j) & " = " &
						to_hex(span_rdata));
				end loop;
			end if;
		end loop;
		file_close(gf);
		chk.check(bad_buf = 0, "buffer bit of pixel writes");
		chk.check(bad_addr = 0, "SRAM reads outside the art");
		finished <= true;
		tb_finish("tb_frame_renderer", chk.checks, chk.errors);
		wait;
	end process;
end arch;

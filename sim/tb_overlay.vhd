--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    2D Overlay Testbench
-- Module Name:    tb_overlay
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for overlay against the golden
--                 model (tools/model/overlay.py). For each case of
--                 sim/golden/overlay_cases.txt (title, briefing, playing,
--                 message, automap, paused, dead, debug, keys, three
--                 key-marker cases, score, ending) it loads the tile map and seen bits into
--                 behavioral RAMs (1-clock read), packs the HUD word, key
--                 positions and debug counters, fills a framebuffer with
--                 the base image B, runs the overlay once, applies every
--                 pixel write, and compares the whole framebuffer with the
--                 expected image E.
--                 The weapon art comes from a behavioral SRAM master port
--                 that answers from build/art.bin at ART_BASE, with random
--                 grant delays and a fixed read latency; the pixel port is
--                 ready a random READY_PCT percent of the clocks.
--                 Checks per case: image equal, buffer bit of every write,
--                 exactly one done_o. Prints the clocks per case.
--                 Run from build/sim_overlay (paths are relative to it).
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, std.textio, tb_pkg, overlay, overlay_bcd,
--                 font_rom, hw_pkg, game_pkg, render_types_pkg
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

entity tb_overlay is
	generic(
		GOLDEN_FILE: string := "../../sim/golden/overlay_cases.txt"; -- Relative to the run directory
		ART_FILE: string := "../../build/art.bin";
		READY_PCT: natural := 70; -- Pixel port ready probability, percent
		GNT_PCT: natural := 40 -- SRAM grant probability per clock, percent
	);
end tb_overlay;

architecture arch of tb_overlay is
	component overlay is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			buf_i: in std_logic;
			hud_i: in std_logic_vector(HUD_BITS - 1 downto 0);
			player_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			player_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			keypos_i: in std_logic_vector(KEYPOS_BITS - 1 downto 0);
			debug_i: in std_logic_vector(4 * 24 - 1 downto 0);
			map_addr_o: out std_logic_vector(11 downto 0);
			map_data_i: in std_logic_vector(23 downto 0);
			seen_addr_o: out std_logic_vector(11 downto 0);
			seen_data_i: in std_logic;
			m_req_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0);
			pix_valid_o: out std_logic;
			pix_ready_i: in std_logic;
			pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic
		);
	end component;

	constant PERIOD: time := 10 ns;
	constant PIXELS: natural := 320 * 240;
	constant ART_MAX: natural := 262144; -- Art window of the SRAM model, bytes
	constant SRAM_LATENCY: natural := 3; -- Clocks from grant to rvalid

	-- Framebuffer
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

	type tiles_t is array (0 to 4095) of std_logic_vector(23 downto 0);
	type seen_t is array (0 to 4095) of std_logic;
	type char_file_t is file of character;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal start: std_logic := '0';
	signal buf: std_logic := '0';
	signal hud: std_logic_vector(HUD_BITS - 1 downto 0) := (others => '0');
	signal player_x, player_y: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal angle: std_logic_vector(ANGLE_BITS - 1 downto 0) := (others => '0');
	signal keypos: std_logic_vector(KEYPOS_BITS - 1 downto 0) := (others => '0');
	signal debug: std_logic_vector(4 * 24 - 1 downto 0) := (others => '0');
	signal tiles: tiles_t := (others => (others => '0'));
	signal seen: seen_t := (others => '0');
	signal map_addr, seen_addr: std_logic_vector(11 downto 0);
	signal map_data: std_logic_vector(23 downto 0) := (others => '0');
	signal seen_data: std_logic := '0';
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

	-- Read 240 lines of 640 hex digits into the framebuffer
	procedure read_image(file f: text) is
		variable l: line;
		variable s: string(1 to 640);
	begin
		for y in 0 to 239 loop
			readline(f, l);
			read(l, s);
			for x in 0 to 319 loop
				fb.put(y * 320 + x, hexval(s(2 * x + 1)) * 16 + hexval(s(2 * x + 2)));
			end loop;
		end loop;
	end procedure;
begin
	dut: overlay
		port map (
			clk_i => clk,
			rst_i => rst,
			start_i => start,
			buf_i => buf,
			hud_i => hud,
			player_x_i => player_x,
			player_y_i => player_y,
			angle_i => angle,
			keypos_i => keypos,
			debug_i => debug,
			map_addr_o => map_addr,
			map_data_i => map_data,
			seen_addr_o => seen_addr,
			seen_data_i => seen_data,
			m_req_o => m_req,
			m_addr_o => m_addr,
			m_gnt_i => m_gnt,
			m_rvalid_i => m_rvalid,
			m_rdata_i => m_rdata,
			pix_valid_o => pix_valid,
			pix_ready_i => pix_ready,
			pix_data_o => pix_data,
			busy_o => busy,
			done_o => done
		);

	-- Tile map and seen bits, read one clock after the address
	process(clk)
	begin
		if rising_edge(clk) then
			map_data <= tiles(to_integer(unsigned(map_addr)));
			seen_data <= seen(to_integer(unsigned(seen_addr)));
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
		variable s1, s2: positive := 23;
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
	-- read data SRAM_LATENCY clocks later, from art.bin at ART_BASE
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
		variable s6: string(1 to 6);
		variable s64: string(1 to 64);
		variable s640: string(1 to 640);
		variable hv: integer;
		type hvals_t is array (0 to 19) of integer;
		variable h: hvals_t;
		variable hw: std_logic_vector(HUD_BITS - 1 downto 0);
		variable kp: std_logic_vector(KEYPOS_BITS - 1 downto 0);
		variable dv: std_logic_vector(4 * 24 - 1 downto 0);
		variable nkeys, kind, kx, ky: integer;
		variable t: tiles_t;
		variable sn: seen_t;
		variable px, py, ang: integer;
		variable cycles: natural;
		variable mism, want, got: natural;
		variable dones0: natural;
		variable k: natural := 0; -- Case number
	begin
		file_open(gf, GOLDEN_FILE, read_mode);
		wait until (rst = '0');
		wait until rising_edge(clk);
		-- Every case in the file (a fixed count would silently skip new cases)
		while (not endfile(gf)) loop
			-- C k name
			readline(gf, l);
			if (l'length = 0) then
				exit;
			end if;
			-- H: HUD values in the order of HUD_KEYS (tools/model/golden2.py)
			readline(gf, l);
			read(l, c);
			for i in 0 to 19 loop
				read(l, hv);
				h(i) := hv;
			end loop;
			hw := (others => '0');
			hw(HUD_FLOW_HI downto HUD_FLOW_LO) := std_logic_vector(to_unsigned(h(0), 3));
			hw(HUD_LEVEL_HI downto HUD_LEVEL_LO) := std_logic_vector(to_unsigned(h(1), 2));
			hw(HUD_HEALTH_HI downto HUD_HEALTH_LO) := std_logic_vector(to_unsigned(h(2), 8));
			hw(HUD_ARMOR_HI downto HUD_ARMOR_LO) := std_logic_vector(to_unsigned(h(3), 8));
			hw(HUD_AMMO_HI downto HUD_AMMO_LO) := std_logic_vector(to_unsigned(h(4), 8));
			hw(HUD_WEAPON_HI downto HUD_WEAPON_LO) := std_logic_vector(to_unsigned(h(5), 2));
			hw(HUD_KEYS_HI downto HUD_KEYS_LO) := std_logic_vector(to_unsigned(h(6), 2));
			hw(HUD_WFRAME_HI downto HUD_WFRAME_LO) := std_logic_vector(to_unsigned(h(7), 8));
			hw(HUD_BOB_HI downto HUD_BOB_LO) := std_logic_vector(to_unsigned(h(8), 3));
			hw(HUD_MSG_HI downto HUD_MSG_LO) := std_logic_vector(to_unsigned(h(9), 4));
			hw(HUD_KILLS_HI downto HUD_KILLS_LO) := std_logic_vector(to_unsigned(h(10), 6));
			hw(HUD_TKILLS_HI downto HUD_TKILLS_LO) := std_logic_vector(to_unsigned(h(11), 6));
			hw(HUD_ITEMS_HI downto HUD_ITEMS_LO) := std_logic_vector(to_unsigned(h(12), 6));
			hw(HUD_TITEMS_HI downto HUD_TITEMS_LO) := std_logic_vector(to_unsigned(h(13), 6));
			hw(HUD_SECRETS_HI downto HUD_SECRETS_LO) := std_logic_vector(to_unsigned(h(14), 4));
			hw(HUD_TSECRETS_HI downto HUD_TSECRETS_LO) := std_logic_vector(to_unsigned(h(15), 4));
			hw(HUD_TMIN_HI downto HUD_TMIN_LO) := std_logic_vector(to_unsigned(h(16), 7));
			hw(HUD_TSEC_HI downto HUD_TSEC_LO) := std_logic_vector(to_unsigned(h(17), 6));
			if (h(18) /= 0) then
				hw(HUD_AUTOMAP) := '1';
			end if;
			if (h(19) /= 0) then
				hw(HUD_DEBUG) := '1';
			end if;
			-- K player x, y, angle
			readline(gf, l);
			read(l, c);
			read(l, px);
			read(l, py);
			read(l, ang);
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
				t(i) := std_logic_vector(to_unsigned(hv, 24));
			end loop;
			-- V then 64 rows of seen bits
			readline(gf, l);
			for y in 0 to 63 loop
				readline(gf, l);
				read(l, s64);
				for x in 0 to 63 loop
					if (s64(x + 1) = '1') then
						sn(y * 64 + x) := '1';
					else
						sn(y * 64 + x) := '0';
					end if;
				end loop;
			end loop;
			-- A keys on the floor: kind (6 blue, 7 red), tile x, tile y
			readline(gf, l);
			read(l, c);
			read(l, nkeys);
			kp := (others => '0');
			for i in 1 to nkeys loop
				read(l, kind);
				read(l, kx);
				read(l, ky);
				-- Each key field: present bit, then tile x (6 bits), then tile y (6 bits)
				if (kind = 6) then
					kp(KEYPOS_BLUE) := '1';
					kp(KEYPOS_BLUE + 6 downto KEYPOS_BLUE + 1) := std_logic_vector(to_unsigned(kx, 6));
					kp(KEYPOS_BLUE + 12 downto KEYPOS_BLUE + 7) := std_logic_vector(to_unsigned(ky, 6));
				else
					kp(KEYPOS_RED) := '1';
					kp(KEYPOS_RED + 6 downto KEYPOS_RED + 1) := std_logic_vector(to_unsigned(kx, 6));
					kp(KEYPOS_RED + 12 downto KEYPOS_RED + 7) := std_logic_vector(to_unsigned(ky, 6));
				end if;
			end loop;
			-- D 4 debug counters
			readline(gf, l);
			read(l, c);
			for i in 0 to 3 loop
				read(l, hv);
				dv(24 * i + 23 downto 24 * i) := std_logic_vector(to_unsigned(hv, 24));
			end loop;
			-- B base image into the framebuffer
			readline(gf, l);
			read_image(gf);

			hud <= hw;
			player_x <= std_logic_vector(to_unsigned(px, POS_BITS));
			player_y <= std_logic_vector(to_unsigned(py, POS_BITS));
			angle <= std_logic_vector(to_unsigned(ang, ANGLE_BITS));
			keypos <= kp;
			debug <= dv;
			tiles <= t;
			seen <= sn;
			if ((k mod 2) = 1) then
				buf <= '1';
			else
				buf <= '0';
			end if;
			wait until rising_edge(clk);
			wait until rising_edge(clk);

			-- Run the overlay once
			dones0 := dones;
			start <= '1';
			wait until rising_edge(clk);
			start <= '0';
			cycles := 1;
			while (done /= '1') loop
				wait until rising_edge(clk);
				cycles := cycles + 1;
			end loop;
			for i in 1 to 4 loop
				wait until rising_edge(clk);
			end loop;
			chk.check(busy = '0', "case " & integer'image(k) & ": busy after done");
			chk.check(dones = dones0 + 1, "case " & integer'image(k) & ": one done pulse");

			-- E expected image: compare with the framebuffer
			readline(gf, l);
			mism := 0;
			for y in 0 to 239 loop
				readline(gf, l);
				read(l, s640);
				for x in 0 to 319 loop
					want := hexval(s640(2 * x + 1)) * 16 + hexval(s640(2 * x + 2));
					got := fb.get(y * 320 + x);
					if (want /= got) then
						if (mism < 8) then
							tb_print("case " & integer'image(k) & " pixel (" & integer'image(x) &
								", " & integer'image(y) & "): got " & integer'image(got) &
								", expected " & integer'image(want));
						end if;
						mism := mism + 1;
					end if;
				end loop;
			end loop;
			chk.check(mism = 0, "case " & integer'image(k) & ": " & integer'image(mism) &
				" pixels differ");
			tb_print("case " & integer'image(k) & ": " & integer'image(cycles) & " clocks, " &
				integer'image(mism) & " pixels differ");
			k := k + 1;
		end loop;
		chk.check(k = 14, integer'image(k) & " cases run");
		file_close(gf);
		chk.check(bad_buf = 0, "buffer bit of pixel writes");
		chk.check(bad_addr = 0, "SRAM reads outside the art");
		finished <= true;
		tb_finish("tb_overlay", chk.checks, chk.errors);
		wait;
	end process;
end arch;

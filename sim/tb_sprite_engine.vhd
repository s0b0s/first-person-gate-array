--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Sprite Engine Testbench
-- Module Name:    tb_sprite_engine
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for sprite_engine against the
--                 golden model (tools/model/sprites.py). For each case in
--                 sim/golden/sprite_cases.txt (session frames) and then
--                 sim/golden/sprite_stress.txt (tools/model/sprite_stress.py:
--                 full table, near limit, equal depths, screen edges, no
--                 sprites) and sim/golden/sprite4_cases.txt (stage 4: level-3
--                 frames and hand-placed scenes where sprites stand on raised
--                 floors and are clipped by height edges) it loads the
--                 camera, the sprite table (7 fields, with the floor
--                 height), the wall z-buffer and the clip lists (count and
--                 entries per column) into behavioral RAMs (1-clock reads),
--                 serves texel reads from build/art.bin through a
--                 behavioral arbiter port (random grants, read data 4
--                 clocks after the grant), applies random back-pressure on
--                 the pixel port (READY_PCT percent of clocks ready) and
--                 checks:
--                 - the base image with the pixel writes applied equals
--                   the expected image, and every write has the right
--                   buffer bit;
--                 - pixels_o equals the number of pixel writes (saturated);
--                 - the span list equals the golden one, and the span
--                   count of the previous frame stays readable until done;
--                 - one done_o per frame, busy_o low afterwards.
--                 Prints the clocks per case.
--                 RUN_VARIANTS: READY_PCT=60 READY_PCT=100
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, std.textio, tb_pkg, sprite_engine,
--                 sprite_fifo, divider, light_rom, render_types_pkg,
--                 game_pkg, hw_pkg, build/art.bin
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

entity tb_sprite_engine is
	generic(
		GOLDEN_FILE: string := "../../sim/golden/sprite_cases.txt"; -- Relative to the run directory
		STRESS_FILE: string := "../../sim/golden/sprite_stress.txt";
		HEIGHTS_FILE: string := "../../sim/golden/sprite4_cases.txt";
		ART_FILE: string := "../../build/art.bin";
		READY_PCT: natural := 60; -- Pixel port ready probability, percent
		GNT_PCT: natural := 50 -- Read grant probability, percent
	);
end tb_sprite_engine;

architecture arch of tb_sprite_engine is
	component sprite_engine is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			cam_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			cam_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			eye_i: in std_logic_vector(EYE_BITS - 1 downto 0);
			buf_i: in std_logic;
			spr_addr_o: out std_logic_vector(4 downto 0);
			spr_data_i: in std_logic_vector(SPR_BITS - 1 downto 0);
			spr_count_i: in std_logic_vector(5 downto 0);
			zwall_addr_o: out std_logic_vector(8 downto 0);
			zwall_data_i: in std_logic_vector(15 downto 0);
			clip_addr_o: out std_logic_vector(12 downto 0);
			clip_data_i: in std_logic_vector(CLIP_BITS - 1 downto 0);
			ccount_addr_o: out std_logic_vector(8 downto 0);
			ccount_data_i: in std_logic_vector(4 downto 0);
			m_req_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0);
			pix_valid_o: out std_logic;
			pix_ready_i: in std_logic;
			pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
			span_raddr_i: in std_logic_vector(4 downto 0);
			span_rdata_o: out std_logic_vector(SPAN_BITS - 1 downto 0);
			span_count_o: out std_logic_vector(5 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic;
			pixels_o: out std_logic_vector(15 downto 0)
		);
	end component;

	constant PERIOD: time := 10 ns;
	constant PIXEL_COUNT: natural := 320 * 240;
	constant ART_BYTES: natural := 197_632;
	constant LATENCY: natural := 4; -- Clocks from the grant edge to rvalid

	type char_file_t is file of character;
	type bytes_t is array (natural range <>) of integer;

	impure function read_file(name: string; max: natural) return bytes_t is
		file f: char_file_t;
		variable c: character;
		variable b: bytes_t(0 to max - 1) := (others => -1);
		variable n: natural := 0;
	begin
		file_open(f, name, read_mode);
		while (not endfile(f)) and (n < max) loop
			read(f, c);
			b(n) := character'pos(c);
			n := n + 1;
		end loop;
		file_close(f);
		return b;
	end function;

	-- Pixels written in the current frame (-1 = not written)
	type image_store_t is protected
		procedure clear;
		procedure put(addr: natural; value: natural);
		impure function get(addr: natural) return integer;
		impure function writes return natural;
	end protected image_store_t;
	type image_store_t is protected body
		type image_t is array (0 to PIXEL_COUNT - 1) of integer;
		variable img: image_t := (others => -1);
		variable n: natural := 0;
		procedure clear is
		begin
			img := (others => -1);
			n := 0;
		end procedure;
		procedure put(addr: natural; value: natural) is
		begin
			img(addr) := value;
			n := n + 1;
		end procedure;
		impure function get(addr: natural) return integer is
		begin
			return img(addr);
		end function;
		impure function writes return natural is
		begin
			return n;
		end function;
	end protected body image_store_t;

	shared variable chk: checker_t;
	shared variable store: image_store_t;

	type spr_ram_t is array (0 to 31) of std_logic_vector(SPR_BITS - 1 downto 0);
	type z_ram_t is array (0 to 511) of std_logic_vector(15 downto 0);
	type clip_ram_t is array (0 to 8191) of std_logic_vector(CLIP_BITS - 1 downto 0);
	type count_ram_t is array (0 to 511) of natural range 0 to 16;
	type pipe_t is array (1 to LATENCY) of integer; -- Art offset, -1 = no read

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal start: std_logic := '0';
	signal cam_x, cam_y: std_logic_vector(POS_BITS - 1 downto 0) := (others => '0');
	signal angle: std_logic_vector(ANGLE_BITS - 1 downto 0) := (others => '0');
	signal eye: std_logic_vector(EYE_BITS - 1 downto 0) := (others => '0');
	signal buf: std_logic := '0';
	signal spr_addr: std_logic_vector(4 downto 0);
	signal spr_data: std_logic_vector(SPR_BITS - 1 downto 0) := (others => '0');
	signal spr_count: std_logic_vector(5 downto 0) := (others => '0');
	signal spr_ram: spr_ram_t := (others => (others => '0'));
	signal zwall_addr: std_logic_vector(8 downto 0);
	signal zwall_data: std_logic_vector(15 downto 0) := (others => '0');
	signal z_ram: z_ram_t := (others => (others => '0'));
	signal clip_addr: std_logic_vector(12 downto 0);
	signal clip_data: std_logic_vector(CLIP_BITS - 1 downto 0) := (others => '0');
	signal clip_ram: clip_ram_t := (others => (others => '0'));
	signal ccount_addr: std_logic_vector(8 downto 0);
	signal ccount_data: std_logic_vector(4 downto 0) := (others => '0');
	signal count_ram: count_ram_t := (others => 0);
	signal m_req, m_gnt: std_logic;
	signal m_addr: std_logic_vector(18 downto 0);
	signal m_rvalid: std_logic := '0';
	signal m_rdata: std_logic_vector(7 downto 0) := (others => '0');
	signal allow: std_logic := '0';
	signal pix_valid: std_logic;
	signal pix_ready: std_logic := '0';
	signal pix_data: std_logic_vector(PIXW_BITS - 1 downto 0);
	signal span_raddr: std_logic_vector(4 downto 0) := (others => '0');
	signal span_rdata: std_logic_vector(SPAN_BITS - 1 downto 0);
	signal span_count: std_logic_vector(5 downto 0);
	signal busy, done: std_logic;
	signal pixels: std_logic_vector(15 downto 0);
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
begin
	dut: sprite_engine
		port map (
			clk_i => clk,
			rst_i => rst,
			start_i => start,
			cam_x_i => cam_x,
			cam_y_i => cam_y,
			angle_i => angle,
			eye_i => eye,
			buf_i => buf,
			spr_addr_o => spr_addr,
			spr_data_i => spr_data,
			spr_count_i => spr_count,
			zwall_addr_o => zwall_addr,
			zwall_data_i => zwall_data,
			clip_addr_o => clip_addr,
			clip_data_i => clip_data,
			ccount_addr_o => ccount_addr,
			ccount_data_i => ccount_data,
			m_req_o => m_req,
			m_addr_o => m_addr,
			m_gnt_i => m_gnt,
			m_rvalid_i => m_rvalid,
			m_rdata_i => m_rdata,
			pix_valid_o => pix_valid,
			pix_ready_i => pix_ready,
			pix_data_o => pix_data,
			span_raddr_i => span_raddr,
			span_rdata_o => span_rdata,
			span_count_o => span_count,
			busy_o => busy,
			done_o => done,
			pixels_o => pixels
		);

	-- Sprite table, wall z-buffer and clip lists: read one clock after the address
	process(clk)
	begin
		if rising_edge(clk) then
			spr_data <= spr_ram(to_integer(unsigned(spr_addr)));
			zwall_data <= z_ram(to_integer(unsigned(zwall_addr)));
			clip_data <= clip_ram(to_integer(unsigned(clip_addr)));
			ccount_data <= std_logic_vector(to_unsigned(count_ram(to_integer(unsigned(ccount_addr))), 5));
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

	-- Arbiter port: grant (same cycle as the request) when allowed; the
	-- byte comes back LATENCY clocks later, reads in order
	m_gnt <= m_req and allow;

	process(clk)
		variable s1, s2: positive := 23;
		variable x: real;
		variable pipe: pipe_t := (others => -1);
		variable a: integer;
		variable art: bytes_t(0 to ART_BYTES - 1);
		variable loaded: boolean := false;
	begin
		if (not loaded) then
			art := read_file(ART_FILE, ART_BYTES);
			loaded := true;
		end if;
		if rising_edge(clk) then
			uniform(s1, s2, x);
			if (x * 100.0 < real(GNT_PCT)) then
				allow <= '1';
			else
				allow <= '0';
			end if;
			-- Oldest stage comes out now
			if (pipe(LATENCY) >= 0) then
				m_rvalid <= '1';
				m_rdata <= std_logic_vector(to_unsigned(art(pipe(LATENCY)), 8));
			else
				m_rvalid <= '0';
				m_rdata <= (others => 'X');
			end if;
			for i in LATENCY downto 2 loop
				pipe(i) := pipe(i - 1);
			end loop;
			pipe(1) := -1;
			if (m_gnt = '1') then
				a := to_integer(unsigned(m_addr)) - ART_BASE;
				if ((a < 0) or (a >= ART_BYTES)) then
					bad_addr <= bad_addr + 1;
					a := 0;
				end if;
				pipe(1) := a;
			end if;
		end if;
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
		file cases_f: text;
		variable k: natural := 0;
		variable l: line;
		variable tag: character;
		variable n, idx, sx, sy, frame, light, flags, floor, a, got, want: integer;
		variable col, cz, ctop, cbot: integer;
		variable cnt: count_ram_t;
		variable cram: clip_ram_t;
		variable e: std_logic_vector(SPR_BITS - 1 downto 0);
		variable base_img: bytes_t(0 to PIXEL_COUNT - 1);
		variable c1, c2: character;
		variable wrong: natural;
		variable prev_spans: natural := 0;
		variable t0: time;
		variable want_span: integer_vector(0 to 3);
	begin
		wait until (rst = '0');
		wait until rising_edge(clk);
		for fi in 0 to 2 loop
			if (fi = 0) then
				file_open(cases_f, GOLDEN_FILE, read_mode);
			elsif (fi = 1) then
				file_open(cases_f, STRESS_FILE, read_mode);
			else
				file_open(cases_f, HEIGHTS_FILE, read_mode);
			end if;
			while (not endfile(cases_f)) loop
				-- C k
				readline(cases_f, l);
				read(l, tag);
				read(l, n);
				chk.check(tag = 'C', "case header " & integer'image(k));
				-- K cam_x cam_y angle eye
				readline(cases_f, l);
				read(l, tag);
				read(l, n);
				cam_x <= std_logic_vector(to_unsigned(n, POS_BITS));
				read(l, n);
				cam_y <= std_logic_vector(to_unsigned(n, POS_BITS));
				read(l, n);
				angle <= std_logic_vector(to_unsigned(n, ANGLE_BITS));
				read(l, n);
				eye <= std_logic_vector(to_unsigned(n, EYE_BITS));
				buf <= '1' when ((k mod 2) = 1) else '0';
				-- P n, then n x (idx x y frame light flags floor)
				readline(cases_f, l);
				read(l, tag);
				read(l, n);
				spr_count <= std_logic_vector(to_unsigned(n, 6));
				for j in 0 to n - 1 loop
					read(l, idx);
					read(l, sx);
					read(l, sy);
					read(l, frame);
					read(l, light);
					read(l, flags);
					read(l, floor);
					e := (others => '0');
					e(SPR_IDX_HI downto SPR_IDX_LO) := std_logic_vector(to_unsigned(idx, 5));
					e(SPR_X_HI downto SPR_X_LO) := std_logic_vector(to_unsigned(sx, 16));
					e(SPR_Y_HI downto SPR_Y_LO) := std_logic_vector(to_unsigned(sy, 16));
					e(SPR_FRAME_HI downto SPR_FRAME_LO) := std_logic_vector(to_unsigned(frame, 8));
					e(SPR_LIGHT_HI downto SPR_LIGHT_LO) := std_logic_vector(to_unsigned(light, 4));
					e(SPR_BRIGHT) := '1' when ((flags mod 2) = 1) else '0';
					e(SPR_TARGET) := '1' when (((flags / 2) mod 2) = 1) else '0';
					e(SPR_FLOOR_HI downto SPR_FLOOR_LO) := std_logic_vector(to_unsigned(floor, 7));
					spr_ram(j) <= e;
				end loop;
				-- Z, 320 wall z values
				readline(cases_f, l);
				read(l, tag);
				for x in 0 to 319 loop
					read(l, n);
					z_ram(x) <= std_logic_vector(to_unsigned(n, 16));
				end loop;
				-- L lines (clip lists, stage-4 file only): L col n (z top bot) x n;
				-- every other column has no entries. Then B and the base image.
				cnt := (others => 0);
				loop
					readline(cases_f, l);
					read(l, tag);
					exit when (tag /= 'L');
					read(l, col);
					read(l, n);
					cnt(col) := n;
					-- Clip RAM: 16 entries per column, each bottom & top & z (8 + 8 + 16 bits)
					for j in 0 to n - 1 loop
						read(l, cz);
						read(l, ctop);
						read(l, cbot);
						cram(col * 16 + j) := std_logic_vector(to_unsigned(cbot, 8)) &
							std_logic_vector(to_unsigned(ctop, 8)) & std_logic_vector(to_unsigned(cz, 16));
					end loop;
				end loop;
				chk.check(tag = 'B', "case " & integer'image(k) & ": base image header");
				count_ram <= cnt;
				clip_ram <= cram;
				for y in 0 to 239 loop
					readline(cases_f, l);
					for x in 0 to 319 loop
						read(l, c1);
						read(l, c2);
						base_img(y * 320 + x) := hexval(c1) * 16 + hexval(c2);
					end loop;
				end loop;
				store.clear;

				-- Run the frame
				wait until rising_edge(clk);
				start <= '1';
				wait until rising_edge(clk);
				start <= '0';
				t0 := now;
				wait until rising_edge(clk);
				chk.check(busy = '1', "case " & integer'image(k) & ": busy after start");
				-- Spans of the previous frame stay readable while this one runs
				chk.check(to_integer(unsigned(span_count)) = prev_spans, "case " & integer'image(k) &
					": previous span count during the frame");
				wait until (done = '1') for 10 ms;
				chk.check(done = '1', "case " & integer'image(k) & ": done in time");
				tb_print("case " & integer'image(k) & ": " & integer'image((now - t0) / PERIOD) &
					" clocks, " & integer'image(store.writes) & " pixels (ready " &
					integer'image(READY_PCT) & "%, grant " & integer'image(GNT_PCT) & "%)");
				wait until rising_edge(clk);
				wait for 1 ns; -- Let the capture process count the done pulse

				-- E, then 240 lines of the expected image
				readline(cases_f, l);
				wrong := 0;
				for y in 0 to 239 loop
					readline(cases_f, l);
					for x in 0 to 319 loop
						read(l, c1);
						read(l, c2);
						want := hexval(c1) * 16 + hexval(c2);
						a := y * 320 + x;
						got := store.get(a);
						if (got = -1) then -- Not written: the base image shows through
							got := base_img(a);
						end if;
						if (got /= want) then
							wrong := wrong + 1;
							if (wrong <= 5) then
								report "case " & integer'image(k) & " pixel (" & integer'image(x) & "," &
									integer'image(y) & ") = " & integer'image(got) & " want " &
									integer'image(want) severity error;
							end if;
						end if;
					end loop;
				end loop;
				chk.check(wrong = 0, "case " & integer'image(k) & ": " & integer'image(wrong) &
					" wrong pixels");
				chk.check(to_integer(unsigned(pixels)) = minimum(store.writes, 65535), "case " & integer'image(k) &
					": pixels_o " & integer'image(to_integer(unsigned(pixels))) & " vs writes " &
					integer'image(store.writes));
				chk.check(dones = k + 1, "one done per frame, got " & integer'image(dones));
				chk.check(busy = '0', "case " & integer'image(k) & ": idle after done");

				-- Q n, then n x (idx x0 x1 z)
				readline(cases_f, l);
				read(l, tag);
				read(l, n);
				chk.check(to_integer(unsigned(span_count)) = n, "case " & integer'image(k) &
					": span count " & integer'image(to_integer(unsigned(span_count))) & " want " &
					integer'image(n));
				for j in 0 to n - 1 loop
					for f in 0 to 3 loop
						read(l, want_span(f));
					end loop;
					span_raddr <= std_logic_vector(to_unsigned(j, 5));
					wait until rising_edge(clk);
					wait for 1 ns;
					chk.check((to_integer(unsigned(span_rdata(SPAN_IDX_HI downto SPAN_IDX_LO))) =
						want_span(0)) and
						(to_integer(unsigned(span_rdata(SPAN_X0_HI downto SPAN_X0_LO))) = want_span(1)) and
						(to_integer(unsigned(span_rdata(SPAN_X1_HI downto SPAN_X1_LO))) = want_span(2)) and
						(to_integer(unsigned(span_rdata(SPAN_Z_HI downto SPAN_Z_LO))) = want_span(3)),
						"case " & integer'image(k) & " span " & integer'image(j) & " = " &
						to_hex(span_rdata));
				end loop;
				prev_spans := n;
				k := k + 1;
			end loop;
			file_close(cases_f);
		end loop;
		chk.check(bad_buf = 0, "pixels with the wrong buffer bit: " & integer'image(bad_buf));
		chk.check(bad_addr = 0, "reads outside the art: " & integer'image(bad_addr));
		finished <= true;
		tb_finish("tb_sprite_engine", chk.checks, chk.errors);
		wait;
	end process;
end arch;

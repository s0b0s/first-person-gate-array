--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Asset Loader Testbench
-- Module Name:    tb_asset_loader
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for asset_loader with the real
--                 flash_reader and the SPI flash model, preloaded with
--                 build/gamedata.bin at FLASH_DATA_BASE. A behavioral SRAM
--                 master port grants art writes after random delays (0 to
--                 7 clocks) and stores them.
--                 Checks:
--                 - art job: every byte of build/art.bin lands at
--                   ART_BASE + i, each address once, nothing outside
--                 - level jobs 1, 2, 3: all 4096 map writes and all 32
--                   actor slots (records from build/level<n>.bin, zeros
--                   past the level's count) and the start pose
--                 - a directory without the wanted id, and a bad magic,
--                   give error_o, no writes and no done_o
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, tb_pkg, asset_loader, flash_reader,
--                 spi_flash_model
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
use work.tb_pkg.all;
use work.hw_pkg.all;
use work.render_types_pkg.all;
use work.spi_flash_model_pkg.all;

entity tb_asset_loader is
	generic(
		IMAGE_FILE: string := "../../build/gamedata.bin"; -- Relative to the run directory
		ART_FILE: string := "../../build/art.bin";
		LEVEL_PREFIX: string := "../../build/level" -- + n + ".bin"
	);
end tb_asset_loader;

architecture arch of tb_asset_loader is
	component asset_loader is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			art_start_i: in std_logic;
			level_start_i: in std_logic;
			level_i: in std_logic_vector(1 downto 0);
			req_valid_o: out std_logic;
			req_ready_i: in std_logic;
			req_id_o: out std_logic;
			req_addr_o: out std_logic_vector(23 downto 0);
			req_len_o: out std_logic_vector(23 downto 0);
			data_valid_i: in std_logic;
			data_ready_o: out std_logic;
			data_i: in std_logic_vector(7 downto 0);
			data_last_i: in std_logic;
			map_we_o: out std_logic;
			map_addr_o: out std_logic_vector(11 downto 0);
			map_data_o: out std_logic_vector(23 downto 0);
			act_we_o: out std_logic;
			act_addr_o: out std_logic_vector(4 downto 0);
			act_data_o: out std_logic_vector(63 downto 0);
			start_x_o: out std_logic_vector(POS_BITS - 1 downto 0);
			start_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
			start_angle_o: out std_logic_vector(ANGLE_BITS - 1 downto 0);
			m_req_o: out std_logic;
			m_we_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_wdata_o: out std_logic_vector(7 downto 0);
			m_gnt_i: in std_logic;
			busy_o: out std_logic;
			done_o: out std_logic;
			error_o: out std_logic
		);
	end component;
	component flash_reader is
		generic(
			SCK_DIV: positive := 4
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			req_valid_i: in std_logic;
			req_ready_o: out std_logic;
			req_id_i: in std_logic;
			req_addr_i: in std_logic_vector(23 downto 0);
			req_len_i: in std_logic_vector(23 downto 0);
			data_valid_o: out std_logic;
			data_ready_i: in std_logic;
			data_o: out std_logic_vector(7 downto 0);
			data_last_o: out std_logic;
			busy_o: out std_logic;
			cs_n_o: out std_logic;
			sck_o: out std_logic;
			mosi_o: out std_logic;
			miso_i: in std_logic
		);
	end component;
	component spi_flash_model is
		generic(
			JEDEC_ID: std_logic_vector(23 downto 0) := x"C22016";
			T_V: time := 8 ns;
			T_SCK_MIN: time := 20 ns;
			T_CSS: time := 5 ns;
			T_CSH: time := 30 ns;
			T_DS: time := 2 ns
		);
		port(
			cs_n_i: in std_logic;
			sck_i: in std_logic;
			mosi_i: in std_logic;
			miso_o: out std_logic;
			reads_o: out natural;
			errors_o: out natural
		);
	end component;

	constant PERIOD: time := 10 ns;
	constant ART_BYTES: natural := 197_632;
	type char_file_t is file of character;
	type bytes_t is array (natural range <>) of integer;
	type tiles_t is array (0 to 4095) of std_logic_vector(23 downto 0);
	type records_t is array (0 to 31) of std_logic_vector(63 downto 0);
	shared variable chk: checker_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal art_start, level_start: std_logic := '0';
	signal level: std_logic_vector(1 downto 0) := "01";
	signal req_valid, req_ready, req_id: std_logic;
	signal req_addr, req_len: std_logic_vector(23 downto 0);
	signal data_valid, data_ready, data_last: std_logic;
	signal data: std_logic_vector(7 downto 0);
	signal map_we, act_we: std_logic;
	signal map_addr: std_logic_vector(11 downto 0);
	signal map_data: std_logic_vector(23 downto 0);
	signal act_addr: std_logic_vector(4 downto 0);
	signal act_data: std_logic_vector(63 downto 0);
	signal start_x, start_y: std_logic_vector(POS_BITS - 1 downto 0);
	signal start_angle: std_logic_vector(ANGLE_BITS - 1 downto 0);
	signal m_req, m_we, m_gnt: std_logic := '0';
	signal m_addr: std_logic_vector(18 downto 0);
	signal m_wdata: std_logic_vector(7 downto 0);
	signal busy, done, error: std_logic;
	signal cs_n, sck, mosi, miso: std_logic;
	signal flash_reads, flash_errors: natural;

	-- Write monitors (cleared before each job)
	signal clear_monitor: boolean := false;
	signal map_writes, act_writes, sram_writes, dones: natural := 0;
	shared variable got_tiles: tiles_t;
	shared variable got_recs: records_t;
	shared variable art_got: bytes_t(0 to ART_BYTES - 1);

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
begin
	dut: asset_loader
		port map (
			clk_i => clk,
			rst_i => rst,
			art_start_i => art_start,
			level_start_i => level_start,
			level_i => level,
			req_valid_o => req_valid,
			req_ready_i => req_ready,
			req_id_o => req_id,
			req_addr_o => req_addr,
			req_len_o => req_len,
			data_valid_i => data_valid,
			data_ready_o => data_ready,
			data_i => data,
			data_last_i => data_last,
			map_we_o => map_we,
			map_addr_o => map_addr,
			map_data_o => map_data,
			act_we_o => act_we,
			act_addr_o => act_addr,
			act_data_o => act_data,
			start_x_o => start_x,
			start_y_o => start_y,
			start_angle_o => start_angle,
			m_req_o => m_req,
			m_we_o => m_we,
			m_addr_o => m_addr,
			m_wdata_o => m_wdata,
			m_gnt_i => m_gnt,
			busy_o => busy,
			done_o => done,
			error_o => error
		);

	reader: flash_reader
		port map (
			clk_i => clk,
			rst_i => rst,
			req_valid_i => req_valid,
			req_ready_o => req_ready,
			req_id_i => req_id,
			req_addr_i => req_addr,
			req_len_i => req_len,
			data_valid_o => data_valid,
			data_ready_i => data_ready,
			data_o => data,
			data_last_o => data_last,
			busy_o => open,
			cs_n_o => cs_n,
			sck_o => sck,
			mosi_o => mosi,
			miso_i => miso
		);

	flash: spi_flash_model
		port map (
			cs_n_i => cs_n,
			sck_i => sck,
			mosi_i => mosi,
			miso_o => miso,
			reads_o => flash_reads,
			errors_o => flash_errors
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

	-- Behavioral SRAM master port: grant after a random 0..7 clock delay
	process(clk)
		variable s1, s2: positive := 17;
		variable r: real;
		variable wait_left: integer := -1;
		variable a: integer;
	begin
		if rising_edge(clk) then
			if ((m_gnt = '1') and (m_req = '1')) then
				chk.check(m_we = '1', "SRAM reads are never issued");
				a := to_integer(unsigned(m_addr)) - ART_BASE;
				if ((a < 0) or (a >= ART_BYTES)) then
					chk.check(false, "SRAM write outside the art area at " & to_hex(m_addr));
				else
					chk.check(art_got(a) = -1, "SRAM byte written twice at " & to_hex(m_addr));
					art_got(a) := to_integer(unsigned(m_wdata));
				end if;
				sram_writes <= sram_writes + 1;
			end if;
			m_gnt <= '0';
			if ((m_req = '1') and (m_gnt = '0')) then
				if (wait_left < 0) then
					uniform(s1, s2, r);
					wait_left := integer(trunc(r * 8.0));
				end if;
				if (wait_left = 0) then
					m_gnt <= '1';
					wait_left := -1;
				else
					wait_left := wait_left - 1;
				end if;
			end if;
			if (clear_monitor) then
				sram_writes <= 0;
			end if;
		end if;
	end process;

	-- Map and actor write monitors, done counter
	process(clk)
	begin
		if rising_edge(clk) then
			if (clear_monitor) then
				map_writes <= 0;
				act_writes <= 0;
				dones <= 0;
				for i in 0 to 4095 loop
					got_tiles(i) := (others => 'U');
				end loop;
				for i in 0 to 31 loop
					got_recs(i) := (others => 'U');
				end loop;
			else
				if (map_we = '1') then
					got_tiles(to_integer(unsigned(map_addr))) := map_data;
					map_writes <= map_writes + 1;
				end if;
				if (act_we = '1') then
					got_recs(to_integer(unsigned(act_addr))) := act_data;
					act_writes <= act_writes + 1;
				end if;
				if (done = '1') then
					dones <= dones + 1;
				end if;
			end if;
		end if;
	end process;

	process
		variable img: bytes_t(0 to 2 ** 21 - 1);
		variable art: bytes_t(0 to ART_BYTES - 1);
		variable lv: bytes_t(0 to 16383);
		variable n, count, bad, a: natural;
		variable w: std_logic_vector(63 downto 0);
		variable save: integer;

		procedure run_job(is_art: boolean; lvl: natural) is
			variable cycles: natural := 0;
		begin
			clear_monitor <= true;
			wait until rising_edge(clk);
			clear_monitor <= false;
			level <= std_logic_vector(to_unsigned(lvl, 2));
			if (is_art) then
				art_start <= '1';
			else
				level_start <= '1';
			end if;
			wait until rising_edge(clk);
			art_start <= '0';
			level_start <= '0';
			wait until rising_edge(clk);
			loop
				wait until rising_edge(clk);
				cycles := cycles + 1;
				exit when (busy = '0') or (cycles > 10_000_000);
			end loop;
			wait until rising_edge(clk);
			wait until rising_edge(clk);
		end procedure;

		-- Unsigned of nbytes bytes at b(i), least significant byte first
		function u(b: bytes_t; i: natural; nbytes: natural) return natural is
			variable v: natural := 0;
		begin
			for k in nbytes - 1 downto 0 loop
				v := v * 256 + b(i + k);
			end loop;
			return v;
		end function;
	begin
		-- Game data image into the flash model
		img := read_file(IMAGE_FILE, img'length);
		n := 0;
		while (img(n) >= 0) loop
			flash_mem.write(FLASH_DATA_BASE + n, img(n));
			n := n + 1;
		end loop;
		chk.check(n > 1_000_000, "game data image read: " & integer'image(n) & " bytes");
		art := read_file(ART_FILE, ART_BYTES);
		for i in art'range loop
			art_got(i) := -1;
		end loop;
		wait until (rst = '0');
		wait until rising_edge(clk);

		-- Art copy
		run_job(true, 0);
		chk.check(error = '0', "art: no error");
		chk.check(dones = 1, "art: one done pulse");
		chk.check(sram_writes = ART_BYTES, "art: SRAM writes " & integer'image(sram_writes));
		bad := 0;
		for i in art'range loop
			if (art_got(i) /= art(i)) then
				bad := bad + 1;
			end if;
		end loop;
		chk.check(bad = 0, "art bytes wrong: " & integer'image(bad));

		-- Levels 1, 2, 3
		for lvl in 1 to 3 loop
			lv := read_file(LEVEL_PREFIX & integer'image(lvl) & ".bin", lv'length);
			run_job(false, lvl);
			chk.check(error = '0', "level " & integer'image(lvl) & ": no error");
			chk.check(dones = 1, "level " & integer'image(lvl) & ": one done pulse");
			chk.check(map_writes = 4096, "level " & integer'image(lvl) & ": map writes " &
				integer'image(map_writes));
			chk.check(act_writes = 32, "level " & integer'image(lvl) & ": actor writes " &
				integer'image(act_writes));
			bad := 0;
			for t in 0 to 4095 loop
				if (to_integer(unsigned(got_tiles(t))) /= u(lv, 3 * t, 3)) then
					bad := bad + 1;
				end if;
			end loop;
			chk.check(bad = 0, "level " & integer'image(lvl) & ": wrong tiles " & integer'image(bad));
			-- Level file after the 4096 3-byte tiles: x and y (4 bytes each) at 12288 and 12292,
			-- angle (2) at 12296, actor count (2) at 12298, 8-byte actor records from 12300
			chk.check(to_integer(unsigned(start_x)) = u(lv, 12288, 3), "level " &
				integer'image(lvl) & ": start x");
			chk.check(to_integer(unsigned(start_y)) = u(lv, 12292, 3), "level " &
				integer'image(lvl) & ": start y");
			chk.check(to_integer(unsigned(start_angle)) = u(lv, 12296, 2), "level " &
				integer'image(lvl) & ": start angle");
			count := u(lv, 12298, 2);
			bad := 0;
			for k in 0 to 31 loop
				w := (others => '0');
				if (k < count) then
					for j in 0 to 7 loop
						w(8 * j + 7 downto 8 * j) := std_logic_vector(to_unsigned(lv(12300 + 8 * k + j), 8));
					end loop;
				end if;
				if (got_recs(k) /= w) then
					bad := bad + 1;
				end if;
			end loop;
			chk.check(bad = 0, "level " & integer'image(lvl) & ": wrong actor slots " &
				integer'image(bad) & " (" & integer'image(count) & " actors)");
		end loop;

		-- Level 3's directory entry renamed to id 7: not found
		-- Directory from byte 12, entries of 12 bytes (id, offset, length); low byte of id
		a := FLASH_DATA_BASE + 12 + 12 * 3;
		save := flash_mem.read(a);
		chk.check(save = 3, "directory entry 3 is level 3");
		flash_mem.write(a, 7);
		run_job(false, 3);
		chk.check(error = '1', "missing item: error");
		chk.check((map_writes = 0) and (act_writes = 0) and (dones = 0), "missing item: no writes, no done");
		flash_mem.write(a, save);

		-- Bad magic
		flash_mem.write(FLASH_DATA_BASE + 3, 16#00#); -- The 'O' (4F) of the magic "SHOOTER0"
		run_job(true, 0);
		chk.check(error = '1', "bad magic: error");
		chk.check((sram_writes = 0) and (dones = 0), "bad magic: no writes, no done");
		flash_mem.write(FLASH_DATA_BASE + 3, 16#4F#);

		-- And a good load afterwards
		run_job(false, 2);
		chk.check((error = '0') and (dones = 1) and (map_writes = 4096), "level 2 after errors");

		chk.check(flash_errors = 0, "flash model errors " & integer'image(flash_errors));
		finished <= true;
		tb_finish("tb_asset_loader", chk.checks, chk.errors);
		wait;
	end process;
end arch;

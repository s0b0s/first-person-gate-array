--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Level Loader Testbench
-- Module Name:    tb_level_loader
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for level_loader with the real
--                 flash_reader and sim/models/spi_flash_model.vhd. The
--                 flash is preloaded through the model's back door with
--                 build/gamedata.bin (tools/flash_image/make_gamedata.py)
--                 at FLASH_DATA_BASE. Tests:
--                 1. Load level id 1: all 4096 map writes, each address
--                    once, equal level 1 (map_init_pkg); start pose
--                    x = 9.5, y = 8.5 (Q6.16), angle 0; done pulses.
--                 2. Load a missing id (7): error_o, no done, no writes.
--                 3. Bad magic (first byte changed): error_o.
--                 4. Load id 1 again after the errors: works.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std, tb_pkg,
--                 level_loader, flash_reader, spi_flash_model, hw_pkg,
--                 map_init_pkg, render_types_pkg
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
use work.tb_pkg.all;
use work.hw_pkg.all;
use work.render_types_pkg.all;
use work.map_init_pkg.all;
use work.spi_flash_model_pkg.all;

entity tb_level_loader is
	generic(
		IMAGE_FILE: string := "../../build/gamedata.bin" -- Relative to the run directory
	);
end tb_level_loader;

architecture arch of tb_level_loader is
	component level_loader is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			level_id_i: in std_logic_vector(7 downto 0);
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
			start_x_o: out std_logic_vector(POS_BITS - 1 downto 0);
			start_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
			start_angle_o: out std_logic_vector(ANGLE_BITS - 1 downto 0);
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
	type char_file_t is file of character;
	shared variable chk: checker_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal start: std_logic := '0';
	signal level_id: std_logic_vector(7 downto 0) := x"01";
	signal req_valid, req_ready, req_id: std_logic;
	signal req_addr, req_len: std_logic_vector(23 downto 0);
	signal data_valid, data_ready, data_last: std_logic;
	signal data: std_logic_vector(7 downto 0);
	signal map_we: std_logic;
	signal map_addr: std_logic_vector(11 downto 0);
	signal map_data: std_logic_vector(23 downto 0);
	signal start_x, start_y: std_logic_vector(POS_BITS - 1 downto 0);
	signal start_angle: std_logic_vector(ANGLE_BITS - 1 downto 0);
	signal busy, done, error: std_logic;
	signal cs_n, sck, mosi, miso: std_logic;
	signal flash_reads, flash_errors: natural;
	-- Map write monitor
	signal writes: natural := 0;
	signal wrong: natural := 0;
	signal dupes: natural := 0;
	signal clear_monitor: boolean := false;
	signal dones: natural := 0;
begin
	dut: level_loader
		port map (
			clk_i => clk,
			rst_i => rst,
			start_i => start,
			level_id_i => level_id,
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
			start_x_o => start_x,
			start_y_o => start_y,
			start_angle_o => start_angle,
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

	-- Map write monitor: every write must carry level 1's word, each
	-- address once per load
	process(clk)
		type seen_t is array (0 to 4095) of boolean;
		variable seen: seen_t := (others => false);
		variable a: natural;
	begin
		if rising_edge(clk) then
			if (clear_monitor) then
				seen := (others => false);
				writes <= 0;
				wrong <= 0;
				dupes <= 0;
			elsif (map_we = '1') then
				a := to_integer(unsigned(map_addr));
				writes <= writes + 1;
				if (map_data /= LEVEL1_TILES(a)) then
					wrong <= wrong + 1;
				end if;
				if (seen(a)) then
					dupes <= dupes + 1;
				end if;
				seen(a) := true;
			end if;
		end if;
	end process;

	process
		file f: char_file_t;
		variable c: character;
		variable n: natural := 0;

		procedure load(id: natural; expect_ok: boolean; name: string) is
			variable cycles: natural := 0;
		begin
			clear_monitor <= true;
			wait until rising_edge(clk);
			clear_monitor <= false;
			level_id <= std_logic_vector(to_unsigned(id, 8));
			start <= '1';
			wait until rising_edge(clk);
			start <= '0';
			wait until rising_edge(clk);
			chk.check(busy = '1', name & ": busy after start");
			loop
				wait until rising_edge(clk);
				cycles := cycles + 1;
				exit when (busy = '0') or (cycles > 2_000_000);
			end loop;
			-- done_o pulses in the same cycle busy_o drops; let the
			-- monitors count it
			wait until rising_edge(clk);
			if (expect_ok) then
				chk.check(error = '0', name & ": no error");
				chk.check(writes = 4096, name & ": map writes " & integer'image(writes));
				chk.check(wrong = 0, name & ": wrong tile words " & integer'image(wrong));
				chk.check(dupes = 0, name & ": addresses written twice " & integer'image(dupes));
				-- Level 1 starts at x = 9.5, y = 8.5 tiles (Q6.16)
				chk.check(to_integer(unsigned(start_x)) = 622592, name & ": start x");
				chk.check(to_integer(unsigned(start_y)) = 557056, name & ": start y");
				chk.check(to_integer(unsigned(start_angle)) = 0, name & ": start angle");
			else
				chk.check(error = '1', name & ": error reported");
				chk.check(writes = 0, name & ": no map writes");
			end if;
		end procedure;
	begin
		-- Game data image into the flash model
		file_open(f, IMAGE_FILE, read_mode);
		while not endfile(f) loop
			read(f, c);
			flash_mem.write(FLASH_DATA_BASE + n, character'pos(c));
			n := n + 1;
		end loop;
		file_close(f);
		chk.check(n > 12298, "game data image read: " & integer'image(n) & " bytes");
		wait until (rst = '0');
		wait until rising_edge(clk);

		load(1, true, "level 1");
		load(7, false, "missing id");
		flash_mem.write(FLASH_DATA_BASE, 16#00#); -- Break the 'S' (53) of the magic
		load(1, false, "bad magic");
		flash_mem.write(FLASH_DATA_BASE, 16#53#);
		load(1, true, "level 1 again");

		chk.check(flash_errors = 0, "flash model errors " & integer'image(flash_errors));
		chk.check(dones = 2, "done pulses: " & integer'image(dones));
		finished <= true;
		tb_finish("tb_level_loader", chk.checks, chk.errors);
		wait;
	end process;

	-- done_o pulses exactly once per good load and never on an error
	process(clk)
	begin
		if rising_edge(clk) then
			if (done = '1') then
				dones <= dones + 1;
				chk.check(error = '0', "done with error set");
				chk.check(writes = 4096, "done after all map writes");
			end if;
		end if;
	end process;
end arch;

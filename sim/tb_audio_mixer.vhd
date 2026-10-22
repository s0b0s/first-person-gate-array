--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Audio Mixer Testbench
-- Module Name:    tb_audio_mixer
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for audio_mixer with the real
--                 flash_arbiter, flash_reader and the SPI flash model,
--                 preloaded with build/gamedata.bin at FLASH_DATA_BASE.
--                 sample_req comes every 2,048 clocks, as from i2s_tx.
--                 The mixer runs the case of sim/golden/mixer_case.txt
--                 (written by the Python Mixer model):
--                   M track master    music track and master volume
--                   T t id vol pan pri  a command before model sample t
--                   O left right      model output of sample t (in order)
--                 Alignment: sample_req R_k starts computation k, which is
--                 model sample k. Music is switched on just before R_0, the
--                 commands of sample t are handed over between R_(t-1) and
--                 R_t, and the outputs of computation k are compared at
--                 R_(k+1), for all 6,000 samples.
--                 Meanwhile client 1 of the arbiter (the loader's port)
--                 reads random spans of the flash with random back-pressure
--                 and checks every byte against the flash memory.
--                 Also checked: underflows_o stays 0, no flash model errors.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, std.textio, tb_pkg, audio_mixer,
--                 flash_arbiter, flash_reader, spi_flash_model
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
use work.render_types_pkg.all;
use work.spi_flash_model_pkg.all;

entity tb_audio_mixer is
	generic(
		IMAGE_FILE: string := "../../build/gamedata.bin"; -- Relative to the run directory
		CASE_FILE: string := "../../sim/golden/mixer_case.txt"
	);
end tb_audio_mixer;

architecture arch of tb_audio_mixer is
	component audio_mixer is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			enable_i: in std_logic;
			snd_valid_i: in std_logic;
			snd_ready_o: out std_logic;
			snd_data_i: in std_logic_vector(SND_BITS - 1 downto 0);
			music_i: in std_logic_vector(1 downto 0);
			master_i: in std_logic_vector(5 downto 0);
			sample_req_i: in std_logic;
			left_o: out std_logic_vector(15 downto 0);
			right_o: out std_logic_vector(15 downto 0);
			req_valid_o: out std_logic;
			req_ready_i: in std_logic;
			req_id_o: out std_logic;
			req_addr_o: out std_logic_vector(23 downto 0);
			req_len_o: out std_logic_vector(23 downto 0);
			data_valid_i: in std_logic;
			data_ready_o: out std_logic;
			data_i: in std_logic_vector(7 downto 0);
			data_last_i: in std_logic;
			underflows_o: out std_logic_vector(15 downto 0)
		);
	end component;
	component flash_arbiter is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			c0_req_valid_i: in std_logic;
			c0_req_ready_o: out std_logic;
			c0_req_id_i: in std_logic;
			c0_req_addr_i: in std_logic_vector(23 downto 0);
			c0_req_len_i: in std_logic_vector(23 downto 0);
			c0_data_valid_o: out std_logic;
			c0_data_ready_i: in std_logic;
			c0_data_o: out std_logic_vector(7 downto 0);
			c0_data_last_o: out std_logic;
			c1_req_valid_i: in std_logic;
			c1_req_ready_o: out std_logic;
			c1_req_id_i: in std_logic;
			c1_req_addr_i: in std_logic_vector(23 downto 0);
			c1_req_len_i: in std_logic_vector(23 downto 0);
			c1_data_valid_o: out std_logic;
			c1_data_ready_i: in std_logic;
			c1_data_o: out std_logic_vector(7 downto 0);
			c1_data_last_o: out std_logic;
			req_valid_o: out std_logic;
			req_ready_i: in std_logic;
			req_id_o: out std_logic;
			req_addr_o: out std_logic_vector(23 downto 0);
			req_len_o: out std_logic_vector(23 downto 0);
			data_valid_i: in std_logic;
			data_ready_o: out std_logic;
			data_i: in std_logic_vector(7 downto 0);
			data_last_i: in std_logic
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
	constant IMAGE_MAX: natural := 2 * 1024 * 1024;
	constant SAMPLES: natural := 6000;
	constant MAX_CMDS: natural := 64;
	type char_file_t is file of character;
	type int_array_t is array (natural range <>) of integer;
	shared variable chk: checker_t;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal finished: boolean := false;
	signal stop_c1: boolean := false;
	signal sample_req: std_logic := '0';
	signal snd_valid: std_logic := '0';
	signal snd_ready: std_logic;
	signal snd_data: std_logic_vector(SND_BITS - 1 downto 0) := (others => '0');
	signal music: std_logic_vector(1 downto 0) := "00";
	signal master: std_logic_vector(5 downto 0) := "100000";
	signal left, right: std_logic_vector(15 downto 0);
	signal underflows: std_logic_vector(15 downto 0);
	-- Audio side of the arbiter
	signal a_req_valid, a_req_ready, a_req_id: std_logic;
	signal a_req_addr, a_req_len: std_logic_vector(23 downto 0);
	signal a_data_valid, a_data_ready, a_data_last: std_logic;
	signal a_data: std_logic_vector(7 downto 0);
	-- Client 1 (stands in for the asset loader)
	signal c1_req_valid: std_logic := '0';
	signal c1_req_ready: std_logic;
	signal c1_req_addr, c1_req_len: std_logic_vector(23 downto 0) := (others => '0');
	signal c1_data_valid, c1_data_last: std_logic;
	signal c1_data_ready: std_logic := '0';
	signal c1_data: std_logic_vector(7 downto 0);
	signal c1_reads: natural := 0;
	-- Reader side
	signal req_valid, req_ready, req_id: std_logic;
	signal req_addr, req_len: std_logic_vector(23 downto 0);
	signal data_valid, data_ready, data_last: std_logic;
	signal data: std_logic_vector(7 downto 0);
	signal cs_n, sck, mosi, miso: std_logic;
	signal flash_reads, flash_errors: natural;
begin
	dut: audio_mixer
		port map (
			clk_i => clk,
			rst_i => rst,
			enable_i => '1',
			snd_valid_i => snd_valid,
			snd_ready_o => snd_ready,
			snd_data_i => snd_data,
			music_i => music,
			master_i => master,
			sample_req_i => sample_req,
			left_o => left,
			right_o => right,
			req_valid_o => a_req_valid,
			req_ready_i => a_req_ready,
			req_id_o => a_req_id,
			req_addr_o => a_req_addr,
			req_len_o => a_req_len,
			data_valid_i => a_data_valid,
			data_ready_o => a_data_ready,
			data_i => a_data,
			data_last_i => a_data_last,
			underflows_o => underflows
		);

	arb: flash_arbiter
		port map (
			clk_i => clk,
			rst_i => rst,
			c0_req_valid_i => a_req_valid,
			c0_req_ready_o => a_req_ready,
			c0_req_id_i => a_req_id,
			c0_req_addr_i => a_req_addr,
			c0_req_len_i => a_req_len,
			c0_data_valid_o => a_data_valid,
			c0_data_ready_i => a_data_ready,
			c0_data_o => a_data,
			c0_data_last_o => a_data_last,
			c1_req_valid_i => c1_req_valid,
			c1_req_ready_o => c1_req_ready,
			c1_req_id_i => '0',
			c1_req_addr_i => c1_req_addr,
			c1_req_len_i => c1_req_len,
			c1_data_valid_o => c1_data_valid,
			c1_data_ready_i => c1_data_ready,
			c1_data_o => c1_data,
			c1_data_last_o => c1_data_last,
			req_valid_o => req_valid,
			req_ready_i => req_ready,
			req_id_o => req_id,
			req_addr_o => req_addr,
			req_len_o => req_len,
			data_valid_i => data_valid,
			data_ready_o => data_ready,
			data_i => data,
			data_last_i => data_last
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

	-- sample_req: one clock in every 2,048, like i2s_tx
	process(clk, rst)
		variable count: natural range 0 to 2047 := 0;
	begin
		if (rst = '1') then
			count := 0;
			sample_req <= '0';
		elsif rising_edge(clk) then
			sample_req <= '0';
			if (count = 2047) then
				count := 0;
				sample_req <= '1';
			else
				count := count + 1;
			end if;
		end if;
	end process;

	-- Client 1: random flash reads, every byte checked
	process
		variable s1, s2: positive := 23;
		variable r: real;
		variable addr, len, n, gap: natural;
	begin
		wait until (rst = '0');
		while (not stop_c1) loop
			-- Every 2,000 to 22,000 clocks, 1 to 256 bytes from anywhere in the image,
			-- taken with ready high 75% of the time
			uniform(s1, s2, r);
			gap := 2000 + natural(r * 20000.0);
			for i in 1 to gap loop
				wait until rising_edge(clk);
			end loop;
			uniform(s1, s2, r);
			addr := FLASH_DATA_BASE + natural(r * 1_300_000.0);
			uniform(s1, s2, r);
			len := 1 + natural(r * 255.0);
			c1_req_addr <= std_logic_vector(to_unsigned(addr, 24));
			c1_req_len <= std_logic_vector(to_unsigned(len, 24));
			c1_req_valid <= '1';
			loop
				wait until rising_edge(clk);
				exit when (c1_req_ready = '1');
			end loop;
			c1_req_valid <= '0';
			n := 0;
			loop
				uniform(s1, s2, r);
				if (r < 0.75) then
					c1_data_ready <= '1';
				else
					c1_data_ready <= '0';
				end if;
				wait until rising_edge(clk);
				if ((c1_data_valid = '1') and (c1_data_ready = '1')) then
					chk.check(to_integer(unsigned(c1_data)) = flash_mem.read(addr + n),
						"client 1 byte " & integer'image(n) & " of " & to_hex(to_unsigned(addr, 24)));
					n := n + 1;
					if (c1_data_last = '1') then
						chk.check(n = len, "client 1 length " & integer'image(n));
						exit;
					end if;
				end if;
			end loop;
			c1_data_ready <= '0';
			c1_reads <= c1_reads + 1;
		end loop;
		wait;
	end process;

	process
		file f: char_file_t;
		file case_f: text;
		variable l: line;
		variable c: character;
		variable n, ci: natural;
		variable track, mvol: integer := 0;
		variable cmd_t, cmd_id, cmd_vol, cmd_pan, cmd_pri: int_array_t(0 to MAX_CMDS - 1);
		variable ncmd: natural := 0;
		variable out_l, out_r: int_array_t(0 to SAMPLES - 1);
		variable nout: natural := 0;
		variable bad: natural := 0;
		variable ok: boolean;
	begin
		-- Flash contents
		file_open(f, IMAGE_FILE, read_mode);
		n := 0;
		while ((not endfile(f)) and (n < IMAGE_MAX)) loop
			read(f, c);
			flash_mem.write(FLASH_DATA_BASE + n, character'pos(c));
			n := n + 1;
		end loop;
		file_close(f);
		tb_print("flash image " & integer'image(n) & " bytes");

		-- The golden case, one record per line: "M track master_vol", "T sample id vol pan
		-- priority" (a command issued before that output sample), "O left right"
		file_open(case_f, CASE_FILE, read_mode);
		while (not endfile(case_f)) loop
			readline(case_f, l);
			next when (l'length = 0);
			read(l, c);
			if (c = 'M') then
				read(l, track);
				read(l, mvol);
			elsif (c = 'T') then
				read(l, cmd_t(ncmd));
				read(l, cmd_id(ncmd));
				read(l, cmd_vol(ncmd));
				read(l, cmd_pan(ncmd));
				read(l, cmd_pri(ncmd));
				ncmd := ncmd + 1;
			elsif ((c = 'O') and (nout < SAMPLES)) then
				read(l, out_l(nout));
				read(l, out_r(nout));
				nout := nout + 1;
			end if;
		end loop;
		file_close(case_f);
		chk.check(nout = SAMPLES, "golden outputs " & integer'image(nout));
		tb_print("case: track " & integer'image(track) & ", master " & integer'image(mvol) & ", " &
			integer'image(ncmd) & " commands, " & integer'image(nout) & " outputs");
		master <= std_logic_vector(to_unsigned(mvol, 6));

		-- Directory and heads load in about 0.6 ms
		wait for 3 ms;
		wait until (rising_edge(clk) and (sample_req = '1'));
		chk.check((left = x"0000") and (right = x"0000"), "silent before the case");
		music <= std_logic_vector(to_unsigned(track, 2));

		ci := 0;
		for k in 0 to nout loop
			-- Commands of model sample k, handed over before R_k
			while ((ci < ncmd) and (cmd_t(ci) = k)) loop
				snd_data <= (others => '0');
				snd_data(SND_ID_HI downto SND_ID_LO) <= std_logic_vector(to_unsigned(cmd_id(ci), 5));
				snd_data(SND_VOL_HI downto SND_VOL_LO) <= std_logic_vector(to_unsigned(cmd_vol(ci), 6));
				snd_data(SND_PAN_HI downto SND_PAN_LO) <= std_logic_vector(to_signed(cmd_pan(ci), 6));
				snd_data(SND_PRI_HI downto SND_PRI_LO) <= std_logic_vector(to_unsigned(cmd_pri(ci), 4));
				snd_valid <= '1';
				loop
					wait until rising_edge(clk);
					exit when (snd_ready = '1');
				end loop;
				snd_valid <= '0';
				ci := ci + 1;
			end loop;

			-- R_k: computation k - 1 is on the outputs
			wait until (rising_edge(clk) and (sample_req = '1'));
			if (k >= 1) then
				ok := (to_integer(signed(left)) = out_l(k - 1)) and (to_integer(signed(right)) = out_r(k - 1));
				if ((not ok) and (bad < 10)) then
					tb_print("sample " & integer'image(k - 1) & ": got " & integer'image(to_integer(signed(left))) &
						" " & integer'image(to_integer(signed(right))) & ", expected " &
						integer'image(out_l(k - 1)) & " " & integer'image(out_r(k - 1)));
				end if;
				if (not ok) then
					bad := bad + 1;
				end if;
				chk.check(ok, "output pair");
			end if;
		end loop;
		chk.check(ci = ncmd, "all commands sent");
		tb_print("mismatched samples " & integer'image(bad) & ", client 1 reads " & integer'image(c1_reads) &
			", flash commands " & integer'image(flash_reads));
		chk.check(unsigned(underflows) = 0, "underflows " & integer'image(to_integer(unsigned(underflows))));
		chk.check(c1_reads > 0, "client 1 was served");
		chk.check(flash_errors = 0, "flash model errors " & integer'image(flash_errors));

		stop_c1 <= true;
		finished <= true;
		tb_finish("tb_audio_mixer", chk.checks, chk.errors);
		wait;
	end process;
end arch;

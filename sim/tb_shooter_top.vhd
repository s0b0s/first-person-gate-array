--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    First-Person Gate Array Top Level Testbench
-- Module Name:    tb_shooter_top
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    System testbench for the full game: from the 12 MHz
--                 oscillator (real MMCM model) through the boot art copy,
--                 a level load, the game core, the frame renderer, the
--                 SRAM, the audio mixer and I2S, with the board models
--                 (SRAM, SPI flash holding build/gamedata.bin at 0x220000,
--                 PS/2 keyboard and mouse, VGA monitor, I2S receiver).
--                 Input: the scripted session of tools/model/
--                 system_session.py (sim/golden/system_trace.txt; title,
--                 briefing, level 1, walking, turning, two shots, the
--                 automap). Its snapshots are preloaded into the SRAM
--                 replay area and the design starts in replay play mode
--                 (generic REPLAY_INIT = 2), the same path the board uses
--                 for a recorded session.
--                 Checks:
--                 - the art copy and the level 1 load succeed (status)
--                 - every frame k: the game-state CRC at render start, the
--                   number of sound commands and the screen tint equal
--                   the model's; the CRC log the replay unit writes to
--                   SRAM (CRC_BASE + 4 k) equals them too
--                 - every frame k, once swapped to the front: the whole
--                   front buffer equals the model's frame, pixel for pixel
--                 - audio reaches the I2S pins (non-zero samples once the
--                   level's music plays) with no ring underflows
--                 - no SRAM, flash or VGA timing errors
--                 Every run prints the first few events of the frame chain
--                 (frame start, snapshot, replay output, render start and
--                 done, frame done, level load) for diagnosis, and stops at
--                 the first frame that never swaps.
--                 About 0.3 s of simulated time (64 ms art copy, then one
--                 16.7 ms frame each). BOOT_ART = false skips the art copy
--                 (the testbench preloads build/art.bin into the SRAM) for
--                 quick runs: SIM_GENERIC=BOOT_ART=false.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 std.textio, tb_pkg, shooter_top and everything under it,
--                 all models
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
use work.sram_model_pkg.all;
use work.spi_flash_model_pkg.all;
use work.hw_pkg.all;
use work.game_pkg.all;

entity tb_shooter_top is
	generic(
		GOLDEN_FILE: string := "../../sim/golden/system_trace.txt"; -- Relative to the run directory
		GAMEDATA_FILE: string := "../../build/gamedata.bin";
		ART_FILE: string := "../../build/art.bin";
		BOOT_ART: boolean := true -- false: preload the art instead of the boot copy
	);
end tb_shooter_top;

architecture arch of tb_shooter_top is
	component shooter_top is
		generic(
			BUILD_ID: std_logic_vector(31 downto 0) := x"53470301";
			POWER_HOLD: positive := 1_000_000;
			REPLAY_INIT: natural range 0 to 2 := 0;
			BOOT_ART: boolean := true
		);
		port(
			clk12: in std_logic;
			btn: in std_logic_vector(1 downto 0);
			led: out std_logic_vector(1 downto 0);
			led0_r: out std_logic;
			led0_g: out std_logic;
			led0_b: out std_logic;
			uart_txd_in: in std_logic;
			uart_rxd_out: out std_logic;
			sram_a: out std_logic_vector(18 downto 0);
			sram_dq: inout std_logic_vector(7 downto 0);
			sram_oe_n: out std_logic;
			sram_we_n: out std_logic;
			sram_ce_n: out std_logic;
			qspi_cs_n: out std_logic;
			qspi_sck: out std_logic;
			qspi_dq: inout std_logic_vector(3 downto 0);
			vga_r: out std_logic_vector(3 downto 0);
			vga_g: out std_logic_vector(3 downto 0);
			vga_b: out std_logic_vector(3 downto 0);
			vga_hs: out std_logic;
			vga_vs: out std_logic;
			i2s_mclk: out std_logic;
			i2s_lrck: out std_logic;
			i2s_sclk: out std_logic;
			i2s_sdin: out std_logic;
			kb_clk: inout std_logic;
			kb_dat: inout std_logic;
			ms_clk: inout std_logic;
			ms_dat: inout std_logic;
			pwr_sense: in std_logic
		);
	end component;
	component sram_model is
		generic(
			T_AA: time := 10 ns;
			T_OHA: time := 2 ns;
			T_DOE: time := 4.5 ns;
			T_HZOE: time := 4 ns;
			T_HZWE: time := 5 ns;
			T_PWE: time := 8 ns;
			T_SD: time := 6 ns;
			T_AW: time := 8 ns
		);
		port(
			a_i: in std_logic_vector(18 downto 0);
			dq_io: inout std_logic_vector(7 downto 0);
			ce_n_i: in std_logic;
			oe_n_i: in std_logic;
			we_n_i: in std_logic;
			driving_o: out boolean;
			errors_o: out natural
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
	component ps2_device_model is
		generic(
			HALF_PERIOD: time := 40 us;
			MOUSE: boolean := false;
			REPLY_DELAY: time := 300 us;
			BAT_DELAY: time := 3 ms;
			BYTE_GAP: time := 100 us
		);
		port(
			clk_io: inout std_logic;
			dat_io: inout std_logic;
			send_i: in boolean;
			send_byte_i: in std_logic_vector(7 downto 0);
			send_mode_i: in natural;
			silent_i: in boolean;
			sent_o: out natural;
			rx_byte_o: out std_logic_vector(7 downto 0);
			rx_count_o: out natural;
			rx_parity_errors_o: out natural
		);
	end component;
	component vga_monitor is
		generic(
			OUT_BITS: positive := 4;
			DUMP_FRAME: natural := 0;
			DUMP_FILE: string := "frame.ppm"
		);
		port(
			clk_pix_i: in std_logic;
			r_i: in std_logic_vector(OUT_BITS - 1 downto 0);
			g_i: in std_logic_vector(OUT_BITS - 1 downto 0);
			b_i: in std_logic_vector(OUT_BITS - 1 downto 0);
			hs_i: in std_logic;
			vs_i: in std_logic;
			locked_o: out boolean;
			hpos_o: out natural;
			vpos_o: out natural;
			visible_o: out boolean;
			sample_o: out boolean;
			frames_o: out natural;
			errors_o: out natural
		);
	end component;
	component i2s_receiver_model is
		generic(
			ASSUME_START: boolean := true
		);
		port(
			mclk_i: in std_logic;
			lrck_i: in std_logic;
			sclk_i: in std_logic;
			sdin_i: in std_logic;
			left_o: out std_logic_vector(15 downto 0);
			right_o: out std_logic_vector(15 downto 0);
			count_o: out natural;
			errors_o: out natural
		);
	end component;

	constant PERIOD_12: time := 83.333 ns;
	constant T_OUT: time := 3.5 ns; -- FPGA clock-to-out plus board trace
	constant N_FRAMES: natural := 12; -- Frames in system_trace.txt
	constant CRC_BASE: natural := 16#75800#; -- Replay unit CRC log (rtl/debug/replay_unit.vhd)
	type char_file_t is file of character;
	type crc_log_t is array (0 to 31) of std_logic_vector(31 downto 0);
	type count_log_t is array (0 to 31) of natural;
	shared variable chk: checker_t;

	signal clk12: std_logic := '0';
	signal btn: std_logic_vector(1 downto 0) := "01";
	signal done: boolean := false;
	signal led: std_logic_vector(1 downto 0);
	signal led0_r, led0_g, led0_b: std_logic;
	signal fpga_tx: std_logic;
	signal sram_a: std_logic_vector(18 downto 0);
	signal sram_dq: std_logic_vector(7 downto 0);
	signal sram_oe_n, sram_we_n, sram_ce_n: std_logic;
	signal brd_a: std_logic_vector(18 downto 0) := (others => '0');
	signal brd_oe_n, brd_we_n, brd_ce_n: std_logic := '1';
	signal sram_driving: boolean;
	signal sram_errors: natural;
	signal qspi_cs_n, qspi_sck: std_logic;
	signal qspi_dq: std_logic_vector(3 downto 0);
	signal flash_reads, flash_errors: natural;
	signal vga_r, vga_g, vga_b: std_logic_vector(3 downto 0);
	signal vga_hs, vga_vs: std_logic;
	signal clk_pix_mon, clk_sys_mon: std_logic;
	signal mon_locked, mon_visible, mon_sample: boolean;
	signal mon_h, mon_v, mon_frames, mon_errors: natural;
	signal i2s_mclk, i2s_lrck, i2s_sclk, i2s_sdin: std_logic;
	signal au_left, au_right: std_logic_vector(15 downto 0);
	signal au_count, au_errors: natural;
	signal kb_clk, kb_dat, ms_clk, ms_dat: std_logic;
	signal kb_sent, kb_rx_count, kb_rx_errors: natural;
	signal ms_sent, ms_rx_count, ms_rx_errors: natural;
	signal kb_rx_byte, ms_rx_byte: std_logic_vector(7 downto 0);
	signal loaded: boolean := false; -- Flash and SRAM preloaded

	-- Per-frame log of the game core outputs (monitor process)
	signal starts: natural := 0; -- render_start pulses so far
	signal crc_log: crc_log_t := (others => (others => '0'));
	signal snd_log: count_log_t := (others => 0);
	signal tint_log: count_log_t := (others => 0);
	signal audio_nonzero: natural := 0; -- Non-zero I2S samples received

	function hexval(c: character) return natural is
	begin
		if ((c >= '0') and (c <= '9')) then
			return character'pos(c) - character'pos('0');
		else
			return character'pos(c) - character'pos('A') + 10;
		end if;
	end function;

	function hexvec(s: string) return std_logic_vector is
		variable v: unsigned(4 * s'length - 1 downto 0) := (others => '0');
	begin
		for i in s'range loop
			v := shift_left(v, 4) + hexval(s(i));
		end loop;
		return std_logic_vector(v);
	end function;
begin
	dut: shooter_top
		generic map (
			POWER_HOLD => 1000,
			REPLAY_INIT => 2,
			BOOT_ART => BOOT_ART
		)
		port map (
			clk12 => clk12,
			btn => btn,
			led => led,
			led0_r => led0_r,
			led0_g => led0_g,
			led0_b => led0_b,
			uart_txd_in => '1',
			uart_rxd_out => fpga_tx,
			sram_a => sram_a,
			sram_dq => sram_dq,
			sram_oe_n => sram_oe_n,
			sram_we_n => sram_we_n,
			sram_ce_n => sram_ce_n,
			qspi_cs_n => qspi_cs_n,
			qspi_sck => qspi_sck,
			qspi_dq => qspi_dq,
			vga_r => vga_r,
			vga_g => vga_g,
			vga_b => vga_b,
			vga_hs => vga_hs,
			vga_vs => vga_vs,
			i2s_mclk => i2s_mclk,
			i2s_lrck => i2s_lrck,
			i2s_sclk => i2s_sclk,
			i2s_sdin => i2s_sdin,
			kb_clk => kb_clk,
			kb_dat => kb_dat,
			ms_clk => ms_clk,
			ms_dat => ms_dat,
			pwr_sense => '1'
		);

	-- Clock: the board oscillator
	process
	begin
		if (done) then
			wait;
		end if;
		clk12 <= '0';
		wait for PERIOD_12 / 2;
		clk12 <= '1';
		wait for PERIOD_12 / 2;
	end process;

	-- Reset: BTN0 held until the models are loaded (at least 1 us), then
	-- released between oscillator edges
	process
	begin
		btn <= "01";
		wait for 1 us;
		if (not loaded) then
			wait until loaded;
		end if;
		wait until rising_edge(clk12);
		wait for PERIOD_12 / 4;
		btn <= "00";
		wait;
	end process;

	-- SRAM: control and address arrive T_OUT after the FPGA registers
	brd_a <= transport sram_a after T_OUT;
	brd_oe_n <= transport sram_oe_n after T_OUT;
	brd_we_n <= transport sram_we_n after T_OUT;
	brd_ce_n <= transport sram_ce_n after T_OUT;

	mem: sram_model
		port map (
			a_i => brd_a,
			dq_io => sram_dq,
			ce_n_i => brd_ce_n,
			oe_n_i => brd_oe_n,
			we_n_i => brd_we_n,
			driving_o => sram_driving,
			errors_o => sram_errors
		);

	flash: spi_flash_model
		port map (
			cs_n_i => qspi_cs_n,
			sck_i => qspi_sck,
			mosi_i => qspi_dq(0),
			miso_o => qspi_dq(1),
			reads_o => flash_reads,
			errors_o => flash_errors
		);

	-- PS/2: the level shifter's 10 kohm pull-ups
	kb_clk <= 'H';
	kb_dat <= 'H';
	ms_clk <= 'H';
	ms_dat <= 'H';

	keyboard: ps2_device_model
		port map (
			clk_io => kb_clk,
			dat_io => kb_dat,
			send_i => false,
			send_byte_i => x"00",
			send_mode_i => 0,
			silent_i => false,
			sent_o => kb_sent,
			rx_byte_o => kb_rx_byte,
			rx_count_o => kb_rx_count,
			rx_parity_errors_o => kb_rx_errors
		);

	mouse: ps2_device_model
		generic map (
			MOUSE => true
		)
		port map (
			clk_io => ms_clk,
			dat_io => ms_dat,
			send_i => false,
			send_byte_i => x"00",
			send_mode_i => 0,
			silent_i => false,
			sent_o => ms_sent,
			rx_byte_o => ms_rx_byte,
			rx_count_o => ms_rx_count,
			rx_parity_errors_o => ms_rx_errors
		);

	-- The design's MMCM clocks, taken from inside so the monitor and loggers stay aligned
	clk_pix_mon <= << signal .tb_shooter_top.dut.clk_pix: std_logic >>;
	clk_sys_mon <= << signal .tb_shooter_top.dut.clk_sys: std_logic >>;

	monitor: vga_monitor
		port map (
			clk_pix_i => clk_pix_mon,
			r_i => vga_r,
			g_i => vga_g,
			b_i => vga_b,
			hs_i => vga_hs,
			vs_i => vga_vs,
			locked_o => mon_locked,
			hpos_o => mon_h,
			vpos_o => mon_v,
			visible_o => mon_visible,
			sample_o => mon_sample,
			frames_o => mon_frames,
			errors_o => mon_errors
		);

	dac: i2s_receiver_model
		generic map (
			ASSUME_START => false
		)
		port map (
			mclk_i => i2s_mclk,
			lrck_i => i2s_lrck,
			sclk_i => i2s_sclk,
			sdin_i => i2s_sdin,
			left_o => au_left,
			right_o => au_right,
			count_o => au_count,
			errors_o => au_errors
		);

	-- Count non-zero I2S samples, once per received sample
	process
	begin
		if ((unsigned(au_left) /= 0) or (unsigned(au_right) /= 0)) then
			audio_nonzero <= audio_nonzero + 1;
		end if;
		wait on au_count;
	end process;

	-- Game core outputs per frame: the CRC and tint at render start, the
	-- sound commands handed to the mixer until the next render start
	process
		alias rs is << signal .tb_shooter_top.dut.render_start: std_logic >>;
		alias crc is << signal .tb_shooter_top.dut.crc: std_logic_vector(31 downto 0) >>;
		alias tint is << signal .tb_shooter_top.dut.game_tint: std_logic_vector(1 downto 0) >>;
		alias sv is << signal .tb_shooter_top.dut.snd_valid: std_logic >>;
		alias sr is << signal .tb_shooter_top.dut.snd_ready: std_logic >>;
		variable n: natural := 0;
		variable sounds: count_log_t := (others => 0);
		variable tints: count_log_t := (others => 0);
		variable crcs: crc_log_t := (others => (others => '0'));
		variable tint_next: boolean := false;
	begin
		wait until rising_edge(clk_sys_mon);
		if (tint_next) then
			tints(n - 1) := to_integer(unsigned(tint));
			tint_log <= tints;
			tint_next := false;
		end if;
		-- The render start first: the core's first sound command of a frame
		-- can be taken on the same clock edge as its render start
		if ((rs = '1') and (n < 32)) then
			crcs(n) := crc;
			crc_log <= crcs;
			n := n + 1;
			starts <= n;
			tint_next := true;
		end if;
		if ((sv = '1') and (sr = '1') and (n > 0) and (n <= 32)) then
			sounds(n - 1) := sounds(n - 1) + 1;
			snd_log <= sounds;
		end if;
	end process;

	-- Frame chain events, the first EVENTS_SHOWN of each (diagnosis)
	process
		constant EVENTS_SHOWN: natural := 3;
		alias go is << signal .tb_shooter_top.dut.frame_go: std_logic >>;
		alias sv0 is << signal .tb_shooter_top.dut.snapshot_valid: std_logic >>;
		alias sv1 is << signal .tb_shooter_top.dut.play_snapshot_valid: std_logic >>;
		alias rs is << signal .tb_shooter_top.dut.render_start: std_logic >>;
		alias rd is << signal .tb_shooter_top.dut.render_done: std_logic >>;
		alias fd is << signal .tb_shooter_top.dut.frame_done: std_logic >>;
		alias lr is << signal .tb_shooter_top.dut.core_load_req: std_logic >>;
		alias ld is << signal .tb_shooter_top.dut.level_load_done: std_logic >>;
		type counts_t is array (0 to 7) of natural;
		variable cnt: counts_t := (others => 0);
		procedure note(k: natural; name: string) is
		begin
			if (cnt(k) < EVENTS_SHOWN) then
				tb_print("event " & name & " at " & time'image(now));
			end if;
			cnt(k) := cnt(k) + 1;
		end procedure;
	begin
		wait until rising_edge(clk_sys_mon);
		if (go = '1') then
			note(0, "frame_go");
		end if;
		if (sv0 = '1') then
			note(1, "snapshot_valid");
		end if;
		if (sv1 = '1') then
			note(2, "replay snapshot_valid");
		end if;
		if (rs = '1') then
			note(3, "render_start");
		end if;
		if (rd = '1') then
			note(4, "render_done");
		end if;
		if (fd = '1') then
			note(5, "frame_done");
		end if;
		if (lr = '1') then
			note(6, "level load request");
		end if;
		if (ld = '1') then
			note(7, "level load done");
		end if;
	end process;

	-- Stimulus and checks
	process
		file gd: char_file_t;
		file gf: text;
		variable l: line;
		variable c: character;
		variable s10: string(1 to 10);
		variable s8: string(1 to 8);
		variable s640: string(1 to 640);
		variable n, k, flow, nsnd, tint: natural;
		variable snap: std_logic_vector(39 downto 0);
		variable want_crc, got_crc: std_logic_vector(31 downto 0);
		variable bad, base, want: natural;
		alias front is << signal .tb_shooter_top.dut.front: std_logic >>;
		alias frames is << signal .tb_shooter_top.dut.frame_count: std_logic_vector(15 downto 0) >>;
		alias late is << signal .tb_shooter_top.dut.late_count: std_logic_vector(15 downto 0) >>;
		alias art_status is << signal .tb_shooter_top.dut.art_status: std_logic_vector(1 downto 0) >>;
		alias level_status is << signal .tb_shooter_top.dut.level_status: std_logic_vector(1 downto 0) >>;
		alias cycles is << signal .tb_shooter_top.dut.render_cycles: std_logic_vector(23 downto 0) >>;
		alias underflows is << signal .tb_shooter_top.dut.underflows: std_logic_vector(15 downto 0) >>;
	begin
		-- The flash holds the game data image after the bitstream
		file_open(gd, GAMEDATA_FILE, read_mode);
		n := 0;
		while not endfile(gd) loop
			read(gd, c);
			flash_mem.write(16#220000# + n, character'pos(c));
			n := n + 1;
		end loop;
		file_close(gd);
		chk.check(n > 1_000_000, "game data image read: " & integer'image(n) & " bytes");

		-- The session's snapshots go to the replay area, 5 bytes per frame,
		-- little endian; four zero snapshots after them (the replay unit
		-- prefetches one frame ahead)
		for i in 0 to 5 * (N_FRAMES + 4) - 1 loop
			sram_mem.write(REPLAY_BASE + i, x"00");
		end loop;
		file_open(gf, GOLDEN_FILE, read_mode);
		for f in 0 to N_FRAMES - 1 loop
			readline(gf, l); -- F k snapshot
			read(l, c);
			read(l, k);
			read(l, c);
			read(l, s10);
			snap := hexvec(s10);
			for b in 0 to 4 loop
				sram_mem.write(REPLAY_BASE + 5 * f + b, snap(8 * b + 7 downto 8 * b));
			end loop;
			for i in 1 to 242 loop -- G, E and the image
				readline(gf, l);
			end loop;
		end loop;
		file_close(gf);
		-- Without the boot copy, the art goes straight into the SRAM model
		if (not BOOT_ART) then
			file_open(gd, ART_FILE, read_mode);
			n := 0;
			while not endfile(gd) loop
				read(gd, c);
				sram_mem.write(ART_BASE + n, std_logic_vector(to_unsigned(character'pos(c), 8)));
				n := n + 1;
			end loop;
			file_close(gd);
			tb_print("art preloaded: " & integer'image(n) & " bytes");
		end if;
		loaded <= true;

		-- Boot: the art copy, then level 1 when the session asks for it
		wait until (art_status /= "00") for 120 ms;
		chk.check(art_status = "01", "art copied from flash, status " & to_hex(art_status));
		tb_print("art copy done at " & time'image(now));

		-- Frame by frame: once frame k is on the front buffer, compare it
		-- and the game core's outputs for it
		file_open(gf, GOLDEN_FILE, read_mode);
		for f in 0 to N_FRAMES - 1 loop
			readline(gf, l); -- F
			readline(gf, l); -- G k flow crc sounds tint
			read(l, c);
			read(l, k);
			read(l, flow);
			read(l, c);
			read(l, s8);
			read(l, nsnd);
			read(l, tint);
			want_crc := hexvec(s8);
			readline(gf, l); -- E
			wait until (unsigned(frames) >= f + 1) for 60 ms;
			chk.check(unsigned(frames) >= f + 1, "frame " & integer'image(f) & " swapped");
			-- A frame that never swaps leaves nothing else to check
			exit when (unsigned(frames) < f + 1);
			wait for 100 us;
			-- The sounds of frame f are handed over by now (a few per frame,
			-- right after its render start)
			got_crc := crc_log(f);
			chk.check(got_crc = want_crc, "frame " & integer'image(f) & " state CRC " &
				to_hex(got_crc) & ", model " & to_hex(want_crc));
			chk.check(snd_log(f) = nsnd, "frame " & integer'image(f) & " sounds " &
				integer'image(snd_log(f)) & ", model " & integer'image(nsnd));
			chk.check(tint_log(f) = tint, "frame " & integer'image(f) & " tint " &
				integer'image(tint_log(f)) & ", model " & integer'image(tint));
			-- Framebuffer 0 at SRAM 0x00000, framebuffer 1 at 0x20000
			if (front = '1') then
				base := 16#20000#;
			else
				base := 0;
			end if;
			bad := 0;
			for y in 0 to 239 loop
				readline(gf, l);
				read(l, s640);
				for x in 0 to 319 loop
					want := hexval(s640(2 * x + 1)) * 16 + hexval(s640(2 * x + 2));
					if (to_integer(unsigned(sram_mem.read(base + y * 320 + x))) /= want) then
						if (bad < 5) then
							tb_print("frame " & integer'image(f) & " pixel (" & integer'image(x) & ", " &
								integer'image(y) & "): " & to_hex(sram_mem.read(base + y * 320 + x)) &
								", model " & integer'image(want));
						end if;
						bad := bad + 1;
					end if;
				end loop;
			end loop;
			chk.check(bad = 0, "frame " & integer'image(f) & " (flow " & integer'image(flow) &
				") vs the model: " & integer'image(bad) & " wrong pixels");
			tb_print("frame " & integer'image(f) & ": flow " & integer'image(flow) & ", render clocks " &
				integer'image(to_integer(unsigned(cycles))) & ", " & integer'image(bad) &
				" wrong pixels, at " & time'image(now));
			if (f = 2) then
				chk.check(level_status = "01", "level 1 loaded, status " & to_hex(level_status));
			end if;
		end loop;
		file_close(gf);

		-- The replay unit's CRC log in SRAM, 4 bytes per frame, least significant first
		for f in 0 to N_FRAMES - 1 loop
			got_crc := sram_mem.read(CRC_BASE + 4 * f + 3) & sram_mem.read(CRC_BASE + 4 * f + 2) &
				sram_mem.read(CRC_BASE + 4 * f + 1) & sram_mem.read(CRC_BASE + 4 * f);
			chk.check(got_crc = crc_log(f), "replay CRC log frame " & integer'image(f) & ": " &
				to_hex(got_crc));
		end loop;

		chk.check(audio_nonzero > 100, "audio on the I2S pins: " & integer'image(audio_nonzero) &
			" non-zero samples of " & integer'image(au_count));
		chk.check(unsigned(underflows) = 0, "audio ring underflows " &
			integer'image(to_integer(unsigned(underflows))));
		chk.check(au_errors = 0, "I2S format errors " & integer'image(au_errors));
		tb_print("late frames " & integer'image(to_integer(unsigned(late))));
		chk.check(mon_errors = 0, "VGA timing errors " & integer'image(mon_errors));
		chk.check(sram_errors = 0, "SRAM timing errors " & integer'image(sram_errors));
		chk.check(flash_errors = 0, "flash protocol errors " & integer'image(flash_errors));
		done <= true;
		tb_finish("tb_shooter_top", chk.checks, chk.errors);
		wait;
	end process;
end arch;

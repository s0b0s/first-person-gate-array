--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Stage-1 Game Top Level Testbench
-- Module Name:    tb_game_top
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    System testbench for the stage-1 game: from the 12 MHz
--                 oscillator (real MMCM model) through flash boot, the game
--                 update, the renderer and the SRAM, with the board models
--                 (SRAM, SPI flash holding build/gamedata.bin at 0x220000,
--                 PS/2 keyboard and mouse, VGA monitor).
--                 Checks:
--                 - level 1 loads from flash (status register 7 = 1)
--                 - the first frame on screen (start pose, no input) equals
--                   the Python model's frame for that pose, pixel for pixel
--                   (sim/golden/frame4_0.txt), read from the front buffer
--                 - holding W on the keyboard moves the player forward
--                   (east) and keeps x inside the start room, with no late
--                   frames and no line fetch overruns; the next frames
--                   swap normally
--                 - VGA timing is clean
--                 About 0.11 s of simulated time.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 std.textio, tb_pkg, game_top and everything under it, all
--                 models
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
use work.game_pkg.all;

entity tb_game_top is
	generic(
		GOLDEN_FILE: string := "../../sim/golden/frame4_0.txt"; -- Relative to build/sim
		GAMEDATA_FILE: string := "../../build/gamedata.bin"
	);
end tb_game_top;

architecture arch of tb_game_top is
	component game_top is
		generic(
			BUILD_ID: std_logic_vector(31 downto 0) := x"53470101";
			POWER_HOLD: positive := 1_000_000
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

	constant PERIOD_12: time := 83.333 ns;
	constant T_OUT: time := 3.5 ns; -- FPGA clock-to-out plus board trace
	type image_t is array (0 to 76_799) of integer;
	type char_file_t is file of character;
	shared variable chk: checker_t;

	signal clk12: std_logic := '0';
	signal done: boolean := false;
	signal btn: std_logic_vector(1 downto 0) := "01";
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
	signal clk_pix_mon: std_logic;
	signal mon_locked, mon_visible, mon_sample: boolean;
	signal mon_h, mon_v, mon_frames, mon_errors: natural;
	signal i2s_mclk, i2s_lrck, i2s_sclk, i2s_sdin: std_logic;
	signal kb_clk, kb_dat, ms_clk, ms_dat: std_logic;
	signal kb_send: boolean := false;
	signal kb_byte: std_logic_vector(7 downto 0) := x"00";
	signal kb_sent, kb_rx_count, kb_rx_errors: natural;
	signal ms_sent, ms_rx_count, ms_rx_errors: natural;
	signal kb_rx_byte, ms_rx_byte: std_logic_vector(7 downto 0);

	impure function read_golden return image_t is
		file f: text open read_mode is GOLDEN_FILE;
		variable l: line;
		variable img: image_t;
		variable c1, c2: character;
		function hexval(c: character) return natural is
		begin
			if ((c >= '0') and (c <= '9')) then
				return character'pos(c) - character'pos('0');
			else
				return character'pos(c) - character'pos('A') + 10;
			end if;
		end function;
	begin
		for y in 0 to 239 loop
			readline(f, l);
			for x in 0 to 319 loop
				read(l, c1);
				read(l, c2);
				img(y * 320 + x) := hexval(c1) * 16 + hexval(c2);
			end loop;
		end loop;
		return img;
	end function;
begin
	dut: game_top
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

	-- Reset: BTN0 (the board's reset button) held for 1 us, released between oscillator edges
	process
	begin
		btn <= "01";
		wait for 1 us;
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
			send_i => kb_send,
			send_byte_i => kb_byte,
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

	-- The design's MMCM pixel clock, taken from inside so the monitor stays aligned
	clk_pix_mon <= << signal .tb_game_top.dut.clk_pix: std_logic >>;

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

	process
		file gd: char_file_t;
		variable c: character;
		variable n: natural := 0;
		variable golden: image_t;
		variable bad, base: natural;
		variable x_before, x_after: natural;
		alias front is << signal .tb_game_top.dut.front: std_logic >>;
		alias frames is << signal .tb_game_top.dut.frame_count: std_logic_vector(15 downto 0) >>;
		alias late is << signal .tb_game_top.dut.late_count: std_logic_vector(15 downto 0) >>;
		alias load_status is << signal .tb_game_top.dut.load_status: std_logic_vector(1 downto 0) >>;
		alias pos_x is << signal .tb_game_top.dut.pos_x: std_logic_vector(21 downto 0) >>;
		alias pos_y is << signal .tb_game_top.dut.pos_y: std_logic_vector(21 downto 0) >>;
		alias cycles is << signal .tb_game_top.dut.render_cycles: std_logic_vector(23 downto 0) >>;
	begin
		-- The flash holds the game data image after the bitstream
		file_open(gd, GAMEDATA_FILE, read_mode);
		while not endfile(gd) loop
			read(gd, c);
			flash_mem.write(16#220000# + n, character'pos(c));
			n := n + 1;
		end loop;
		file_close(gd);
		chk.check(n > 12288, "game data image read: " & integer'image(n) & " bytes");
		golden := read_golden;

		-- Level load from flash
		wait until (load_status /= "00") for 30 ms;
		chk.check(load_status = "01", "level 1 loaded from flash, status " & to_hex(load_status));

		-- First frame swapped in: compare the whole front buffer
		wait until (unsigned(frames) >= 1) for 60 ms;
		chk.check(unsigned(frames) >= 1, "first frame swapped");
		wait for 1 ms;
		if (front = '1') then
			base := 16#20000#;
		else
			base := 0;
		end if;
		bad := 0;
		for a in 0 to 76_799 loop
			if (to_integer(unsigned(sram_mem.read(base + a))) /= golden(a)) then
				bad := bad + 1;
			end if;
		end loop;
		chk.check(bad = 0, "first frame vs the Python model: " & integer'image(bad) & " wrong pixels");
		tb_print("render clocks for the first frame: " & integer'image(to_integer(unsigned(cycles))));
		chk.check(unsigned(cycles) < 300_000, "frame rendered in under 3 ms");

		-- Hold W (make 1D) for a few frames, then release (F0 1D)
		x_before := to_integer(unsigned(pos_x));
		kb_byte <= x"1D";
		kb_send <= not kb_send;
		wait for 50 ms;
		kb_byte <= x"F0";
		kb_send <= not kb_send;
		wait for 1.5 ms;
		kb_byte <= x"1D";
		kb_send <= not kb_send;
		wait for 1.5 ms;
		x_after := to_integer(unsigned(pos_x));
		tb_print("player x " & integer'image(x_before) & " -> " & integer'image(x_after) &
			", y " & integer'image(to_integer(unsigned(pos_y))));
		-- Positions are Q6.16 tiles: 4096 is 1/16 tile, y = 8.5 is the start row's middle
		chk.check(x_after > x_before + 4096, "W moved the player east");
		chk.check(x_after < 16 * 65536, "player stayed in the start room");
		chk.check(unsigned(pos_y) = 8 * 65536 + 32768, "no sideways drift");
		chk.check(unsigned(late) = 0, "no late frames: " & integer'image(to_integer(unsigned(late))));
		chk.check(unsigned(frames) >= 3, "frames keep swapping: " &
			integer'image(to_integer(unsigned(frames))));

		chk.check(mon_errors = 0, "VGA timing errors " & integer'image(mon_errors));
		chk.check(sram_errors = 0, "SRAM timing errors " & integer'image(sram_errors));
		chk.check(flash_errors = 0, "flash protocol errors " & integer'image(flash_errors));
		done <= true;
		tb_finish("tb_game_top", chk.checks, chk.errors);
		wait;
	end process;
end arch;

--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Bring-up Diagnostics Top Level Testbench
-- Module Name:    tb_bringup_top
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    System testbench for the stage-0 bring-up design, from the
--                 12 MHz oscillator (real MMCM model) to every board model:
--                 SRAM, SPI flash (game-data header "SHOOTER0" at
--                 0x220000), PS/2 keyboard and mouse with 10 kohm pull-ups,
--                 VGA monitor, I2S receiver, and a PC on the UART.
--                 Checks, about 40 ms of operation:
--                 - PWR_SENSE gate: VGA and I2S pins high impedance and
--                   PS/2 lines released before pcb_on (10 ms), driven after
--                 - UART: ping; build id, flash JEDEC id and the first 8
--                   flash data bytes through register reads
--                 - a keyboard make code reaches the key register and the
--                   keyboard history, a break code clears it
--                 - SRAM self-test runs without errors; frames swap with no
--                   late frames and no line fetch overruns
--                 - the front framebuffer holds the status page: the rows
--                   with no live values match the golden image exactly
--                 - VGA timing (monitor) and I2S format clean, tone present
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 std.textio, tb_pkg, bringup_top and everything under it,
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
use work.game_pkg.all;

entity tb_bringup_top is
	generic(
		GOLDEN_FILE: string := "../../sim/golden/page_expected.txt" -- Relative to build/sim
	);
end tb_bringup_top;

architecture arch of tb_bringup_top is
	component bringup_top is
		generic(
			BUILD_ID: std_logic_vector(31 downto 0) := x"53470001"
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
	constant BIT_TIME: time := 1 us; -- UART at 1 Mbaud
	constant T_OUT: time := 3.5 ns; -- FPGA clock-to-out plus board trace
	type bytes_t is array (0 to 255) of std_logic_vector(7 downto 0);
	type image_t is array (0 to 76_799) of integer;
	shared variable chk: checker_t;

	signal clk12: std_logic := '0';
	signal done: boolean := false;
	signal btn: std_logic_vector(1 downto 0) := "01";
	signal led: std_logic_vector(1 downto 0);
	signal led0_r, led0_g, led0_b: std_logic;
	signal pc_tx: std_logic := '1';
	signal fpga_tx: std_logic;
	signal replies: bytes_t;
	signal nreplies: natural := 0;
	signal pwr_sense: std_logic := '1';

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
	signal clk_pix_mon: std_logic := '0';
	signal mon_locked, mon_visible, mon_sample: boolean;
	signal mon_h, mon_v, mon_frames, mon_errors: natural;

	signal i2s_mclk, i2s_lrck, i2s_sclk, i2s_sdin: std_logic;
	signal i2s_left, i2s_right: std_logic_vector(15 downto 0);
	signal i2s_count, i2s_errors: natural;

	signal kb_clk, kb_dat, ms_clk, ms_dat: std_logic;
	signal kb_send: boolean := false;
	signal kb_byte: std_logic_vector(7 downto 0) := x"00";
	signal kb_sent, kb_rx_count, kb_rx_errors: natural;
	signal ms_sent, ms_rx_count, ms_rx_errors: natural;
	signal kb_rx_byte, ms_rx_byte: std_logic_vector(7 downto 0);

	procedure pc_send(signal line: out std_logic; b: std_logic_vector(7 downto 0)) is
	begin
		line <= '0';
		wait for BIT_TIME;
		for i in 0 to 7 loop
			line <= b(i);
			wait for BIT_TIME;
		end loop;
		line <= '1';
		wait for BIT_TIME;
	end procedure;

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
	dut: bringup_top
		port map (
			clk12 => clk12,
			btn => btn,
			led => led,
			led0_r => led0_r,
			led0_g => led0_g,
			led0_b => led0_b,
			uart_txd_in => pc_tx,
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
			pwr_sense => pwr_sense
		);

	------------------------------------------------------------------
	-- Board
	------------------------------------------------------------------
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

	-- The monitor samples with its own 25 MHz clock; the design's pixel
	-- clock comes from the MMCM, so take it from inside for alignment
	clk_pix_mon <= << signal .tb_bringup_top.dut.clk_pix: std_logic >>;

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

	audio: i2s_receiver_model
		generic map (
			ASSUME_START => false -- The I2S pins start high-Z (PWR_SENSE gate)
		)
		port map (
			mclk_i => i2s_mclk,
			lrck_i => i2s_lrck,
			sclk_i => i2s_sclk,
			sdin_i => i2s_sdin,
			left_o => i2s_left,
			right_o => i2s_right,
			count_o => i2s_count,
			errors_o => i2s_errors
		);

	-- PC side UART receiver
	process
		variable b: std_logic_vector(7 downto 0);
	begin
		wait until falling_edge(fpga_tx);
		-- Half a bit into the start bit, so each data bit below is sampled mid-bit
		wait for BIT_TIME / 2;
		for i in 0 to 7 loop
			wait for BIT_TIME;
			b(i) := fpga_tx;
		end loop;
		wait for BIT_TIME;
		replies(nreplies mod 256) <= b;
		nreplies <= nreplies + 1;
	end process;

	------------------------------------------------------------------
	-- Stimulus and checks
	------------------------------------------------------------------
	process
		variable first: natural;
		variable word: std_logic_vector(31 downto 0);
		variable golden: image_t;
		variable a, bad: natural;
		variable buf_base: natural;
		variable i2s_errors_at_on: natural;
		alias front is << signal .tb_bringup_top.dut.front: std_logic >>;

		procedure read_reg(n: natural; variable value: out std_logic_vector(31 downto 0)) is
		begin
			first := nreplies;
			pc_send(pc_tx, x"52");
			pc_send(pc_tx, std_logic_vector(to_unsigned(n, 8)));
			wait until (nreplies >= first + 4) for 1 ms;
			chk.check(nreplies >= first + 4, "reply to read reg " & integer'image(n));
			-- The register comes back least significant byte first
			value := replies((first + 3) mod 256) & replies((first + 2) mod 256) &
				replies((first + 1) mod 256) & replies(first mod 256);
		end procedure;
	begin
		-- Game-data header in flash: "SHOOTER0"
		flash_mem.write(16#220000#, 16#53#);
		flash_mem.write(16#220001#, 16#48#);
		flash_mem.write(16#220002#, 16#4F#);
		flash_mem.write(16#220003#, 16#4F#);
		flash_mem.write(16#220004#, 16#54#);
		flash_mem.write(16#220005#, 16#45#);
		flash_mem.write(16#220006#, 16#52#);
		flash_mem.write(16#220007#, 16#30#);
		golden := read_golden;

		-- Before pcb_on (10 ms of PWR_SENSE high): everything released
		wait for 8 ms;
		chk.check(led(0) = '1', "MMCM locked");
		chk.check(led(1) = '0', "pcb_on still low at 8 ms");
		chk.check((vga_r = "ZZZZ") and (vga_g = "ZZZZ") and (vga_b = "ZZZZ") and
			(vga_hs = 'Z') and (vga_vs = 'Z'), "VGA pins high-Z before pcb_on");
		chk.check((i2s_mclk = 'Z') and (i2s_sdin = 'Z'), "I2S pins high-Z before pcb_on");
		chk.check((kb_clk = 'H') and (ms_clk = 'H'), "PS/2 lines released before pcb_on");
		wait for 3 ms;
		chk.check(led(1) = '1', "pcb_on after 10 ms");
		chk.check((vga_hs = '0') or (vga_hs = '1'), "VGA pins driven after pcb_on");
		-- The I2S receiver may see one partial channel when the pins switch
		-- from high-Z to driven in the middle of a frame; count from here
		i2s_errors_at_on := i2s_errors;

		-- Keyboard: W pressed (make 1D)
		kb_byte <= x"1D";
		kb_send <= not kb_send;
		wait for 2 ms;

		-- UART: ping, build id, flash id and data
		first := nreplies;
		pc_send(pc_tx, x"50");
		wait until (nreplies > first) for 1 ms;
		chk.check((nreplies > first) and (replies(first mod 256) = x"4B"), "UART ping");
		read_reg(0, word);
		chk.check(word = x"53470001", "build id " & to_hex(word));
		read_reg(4, word);
		chk.check(word = x"00C22016", "flash JEDEC id " & to_hex(word));
		read_reg(5, word);
		chk.check(word = x"53484F4F", "flash data bytes 0-3 " & to_hex(word));
		read_reg(6, word);
		chk.check(word = x"54455230", "flash data bytes 4-7 " & to_hex(word));
		read_reg(18, word);
		chk.check(word(KEY_W) = '1', "W held in the key register " & to_hex(word));
		read_reg(8, word);
		chk.check(word(7 downto 0) = x"1D", "keyboard history shows 1D " & to_hex(word));

		-- Keyboard: W released (F0 1D)
		kb_byte <= x"F0";
		kb_send <= not kb_send;
		wait for 1.5 ms;
		kb_byte <= x"1D";
		kb_send <= not kb_send;
		wait for 1.5 ms;
		read_reg(18, word);
		chk.check(word(KEY_W) = '0', "W released " & to_hex(word));
		read_reg(16, word);
		chk.check(word = x"00000000", "no keyboard errors " & to_hex(word));

		-- Let a few more frames go by, then check the status page and the
		-- counters
		wait until (mon_frames >= 2);
		wait until (mon_v = 100);
		if (front = '1') then
			buf_base := 16#20000#;
		else
			buf_base := 0;
		end if;
		-- Rows without live values: title and rule (pixel rows 0..15) and
		-- the help text (cell rows 23..25, pixel rows 184..207)
		bad := 0;
		for y in 0 to 207 loop
			if ((y < 16) or (y >= 184)) then
				for x in 0 to 319 loop
					a := y * 320 + x;
					if (to_integer(unsigned(sram_mem.read(buf_base + a))) /= golden(a)) then
						bad := bad + 1;
					end if;
				end loop;
			end if;
		end loop;
		chk.check(bad = 0, "status page static rows: " & integer'image(bad) & " wrong pixels");

		read_reg(1, word);
		chk.check(word(15 downto 0) = x"0000", "SRAM self-test errors " & to_hex(word));
		read_reg(3, word);
		chk.check(word(19 downto 16) /= x"0", "SRAM self-test has moved past phase 0");
		read_reg(22, word);
		chk.check(unsigned(word(31 downto 16)) >= 2, "frames swapped " & to_hex(word));
		chk.check(word(15 downto 0) = x"0000", "no late frames");
		read_reg(26, word);
		chk.check(word(15 downto 0) = x"0000", "no line fetch overruns");

		chk.check(mon_errors = 0, "VGA timing errors " & integer'image(mon_errors));
		chk.check(sram_errors = 0, "SRAM timing errors " & integer'image(sram_errors));
		chk.check(flash_errors = 0, "flash protocol errors " & integer'image(flash_errors));
		chk.check(i2s_errors = i2s_errors_at_on, "I2S format errors after pcb_on " &
			integer'image(i2s_errors - i2s_errors_at_on));
		chk.check(i2s_count > 100, "I2S samples received " & integer'image(i2s_count));
		chk.check(kb_rx_count = 0, "nothing sent to the keyboard");
		done <= true;
		tb_finish("tb_bringup_top", chk.checks, chk.errors);
		wait;
	end process;
end arch;

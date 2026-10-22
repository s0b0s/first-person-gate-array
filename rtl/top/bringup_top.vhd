--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Bring-up Diagnostics Top Level
-- Module Name:    bringup_top
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Stage-0 bring-up design, kept buildable as a diagnostics
--                 image for checking the board, the PCB and its wiring.
--                 - Display: 640x480 from the SRAM front buffer; BTN1
--                   cycles the test patterns (framebuffer, color bands,
--                   checker, grid, gradient).
--                 - A status page (text_painter) is redrawn into the back
--                   buffer every frame and swapped in at vblank by the
--                   buffer manager, as the renderer will be later.
--                 - SRAM self-test on 0x40000..0x7FFFF (outside both
--                   framebuffers), flash JEDEC ID and data-area pattern,
--                   PS/2 keyboard and mouse, 440 Hz test tone on the
--                   Pmod I2S2, UART debug port (1 Mbaud).
--                 SRAM masters: 0 display, 1 SRAM tester, 2 pixel FIFO
--                 (status page), 3 UART debug port.
--                 PWR_SENSE gate: VGA and I2S pins are high impedance and
--                 the PS/2 lines released until pcb_on (power_gate).
--                 LEDs: LED0 MMCM locked, LED1 pcb_on; RGB (dim): red =
--                 SRAM errors or line overruns, green = 1 Hz heartbeat,
--                 blue = PS/2 errors.
--                 Clock domains: clk_sys (100 MHz) and clk_pix (25 MHz),
--                 crossed only inside display_controller.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, every
--                 stage-0 block (see the component list)
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First version
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;
use work.game_pkg.all;

entity bringup_top is
	generic(
		BUILD_ID: std_logic_vector(31 downto 0) := x"53470001" -- Shown on the status page
	);
	port(
		clk12: in std_logic; -- 12 MHz oscillator
		btn: in std_logic_vector(1 downto 0); -- BTN0 reset, BTN1 next pattern
		led: out std_logic_vector(1 downto 0); -- LED0 locked, LED1 pcb_on
		led0_r: out std_logic; -- RGB LED, active low
		led0_g: out std_logic;
		led0_b: out std_logic;
		uart_txd_in: in std_logic; -- PC to FPGA
		uart_rxd_out: out std_logic; -- FPGA to PC
		sram_a: out std_logic_vector(18 downto 0);
		sram_dq: inout std_logic_vector(7 downto 0);
		sram_oe_n: out std_logic;
		sram_we_n: out std_logic;
		sram_ce_n: out std_logic;
		qspi_cs_n: out std_logic;
		qspi_sck: out std_logic; -- E19, user I/O after configuration
		qspi_dq: inout std_logic_vector(3 downto 0); -- DQ0 MOSI, DQ1 MISO, DQ2 WP_n, DQ3 HOLD_n
		vga_r: out std_logic_vector(3 downto 0);
		vga_g: out std_logic_vector(3 downto 0);
		vga_b: out std_logic_vector(3 downto 0);
		vga_hs: out std_logic;
		vga_vs: out std_logic;
		i2s_mclk: out std_logic;
		i2s_lrck: out std_logic;
		i2s_sclk: out std_logic;
		i2s_sdin: out std_logic;
		kb_clk: inout std_logic; -- Open drain: '0' or 'Z' only
		kb_dat: inout std_logic;
		ms_clk: inout std_logic;
		ms_dat: inout std_logic;
		pwr_sense: in std_logic -- PCB 3.3 V present (PULLDOWN)
	);
end bringup_top;

architecture arch of bringup_top is
	component clock_reset is
		generic(
			MULT_F: real := 50.0
		);
		port(
			clk12_i: in std_logic;
			btn_rst_i: in std_logic;
			clk_sys_o: out std_logic;
			clk_pix_o: out std_logic;
			clk_sram_rd_o: out std_logic;
			rst_sys_o: out std_logic;
			rst_pix_o: out std_logic;
			locked_o: out std_logic
		);
	end component;
	component power_gate is
		generic(
			HOLD_CYCLES: positive := 1_000_000
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			pwr_sense_i: in std_logic;
			pcb_on_o: out std_logic
		);
	end component;
	component debounce is
		generic(
			TICK_CYCLES: positive := 100;
			CNT_BITS: positive := 16
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			button_i: in std_logic;
			level_o: out std_logic;
			rise_o: out std_logic
		);
	end component;
	component sram_controller is
		generic(
			CYCLES: positive := 2;
			TAG_BITS: positive := 2
		);
		port(
			clk_i: in std_logic;
			clk_rd_i: in std_logic;
			rst_i: in std_logic;
			cmd_valid_i: in std_logic;
			cmd_ready_o: out std_logic;
			cmd_we_i: in std_logic;
			cmd_addr_i: in std_logic_vector(18 downto 0);
			cmd_wdata_i: in std_logic_vector(7 downto 0);
			cmd_tag_i: in std_logic_vector(TAG_BITS - 1 downto 0);
			rsp_valid_o: out std_logic;
			rsp_data_o: out std_logic_vector(7 downto 0);
			rsp_tag_o: out std_logic_vector(TAG_BITS - 1 downto 0);
			busy_o: out std_logic;
			sram_a_o: out std_logic_vector(18 downto 0);
			sram_dq_o: out std_logic_vector(7 downto 0);
			sram_dq_t_o: out std_logic_vector(7 downto 0);
			sram_dq_i: in std_logic_vector(7 downto 0);
			sram_oe_n_o: out std_logic;
			sram_we_n_o: out std_logic;
			sram_ce_n_o: out std_logic
		);
	end component;
	component sram_arbiter is
		generic(
			BURST_MAX: positive := 32
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			m_req_i: in std_logic_vector(3 downto 0);
			m_we_i: in std_logic_vector(3 downto 0);
			m_addr_i: in std_logic_vector(4 * 19 - 1 downto 0);
			m_wdata_i: in std_logic_vector(4 * 8 - 1 downto 0);
			m_gnt_o: out std_logic_vector(3 downto 0);
			m_rvalid_o: out std_logic_vector(3 downto 0);
			m_rdata_o: out std_logic_vector(7 downto 0);
			cmd_valid_o: out std_logic;
			cmd_ready_i: in std_logic;
			cmd_we_o: out std_logic;
			cmd_addr_o: out std_logic_vector(18 downto 0);
			cmd_wdata_o: out std_logic_vector(7 downto 0);
			cmd_tag_o: out std_logic_vector(1 downto 0);
			rsp_valid_i: in std_logic;
			rsp_data_i: in std_logic_vector(7 downto 0);
			rsp_tag_i: in std_logic_vector(1 downto 0);
			busy_i: in std_logic;
			clear_count_i: in std_logic;
			busy_count_o: out std_logic_vector(23 downto 0)
		);
	end component;
	component sync_fifo is
		generic(
			WIDTH: positive := 8;
			DEPTH_BITS: positive := 9
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			in_valid_i: in std_logic;
			in_ready_o: out std_logic;
			in_data_i: in std_logic_vector(WIDTH - 1 downto 0);
			out_valid_o: out std_logic;
			out_ready_i: in std_logic;
			out_data_o: out std_logic_vector(WIDTH - 1 downto 0);
			level_o: out std_logic_vector(DEPTH_BITS - 1 downto 0)
		);
	end component;
	component display_controller is
		generic(
			OUT_BITS: positive := 4
		);
		port(
			clk_sys_i: in std_logic;
			rst_sys_i: in std_logic;
			clk_pix_i: in std_logic;
			rst_pix_i: in std_logic;
			front_i: in std_logic;
			pattern_i: in std_logic_vector(2 downto 0);
			tint_i: in std_logic_vector(1 downto 0);
			blank_i: in std_logic;
			pcb_on_i: in std_logic;
			pal_valid_i: in std_logic;
			pal_ready_o: out std_logic;
			pal_addr_i: in std_logic_vector(7 downto 0);
			pal_data_i: in std_logic_vector(17 downto 0);
			m_req_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0);
			vblank_o: out std_logic;
			line_start_o: out std_logic;
			line_o: out std_logic_vector(7 downto 0);
			overrun_o: out std_logic;
			vga_r_o: out std_logic_vector(OUT_BITS - 1 downto 0);
			vga_g_o: out std_logic_vector(OUT_BITS - 1 downto 0);
			vga_b_o: out std_logic_vector(OUT_BITS - 1 downto 0);
			vga_hs_o: out std_logic;
			vga_vs_o: out std_logic;
			vga_t_o: out std_logic_vector(3 * OUT_BITS + 1 downto 0)
		);
	end component;
	component buffer_manager is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			vblank_i: in std_logic;
			line_start_i: in std_logic;
			line_i: in std_logic_vector(7 downto 0);
			start_line_i: in std_logic_vector(7 downto 0);
			frame_done_i: in std_logic;
			frame_start_o: out std_logic;
			front_o: out std_logic;
			back_o: out std_logic;
			rendering_o: out std_logic;
			frame_count_o: out std_logic_vector(15 downto 0);
			late_count_o: out std_logic_vector(15 downto 0)
		);
	end component;
	component text_painter is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			buf_i: in std_logic;
			values_i: in std_logic_vector(32 * 32 - 1 downto 0);
			pix_valid_o: out std_logic;
			pix_ready_i: in std_logic;
			pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic
		);
	end component;
	component sram_tester is
		generic(
			FIRST: natural := 16#40000#;
			LAST: natural := 16#7FFFF#
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			enable_i: in std_logic;
			m_req_o: out std_logic;
			m_we_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_wdata_o: out std_logic_vector(7 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0);
			phase_o: out std_logic_vector(2 downto 0);
			pass_count_o: out std_logic_vector(15 downto 0);
			error_count_o: out std_logic_vector(15 downto 0);
			first_error_addr_o: out std_logic_vector(18 downto 0);
			first_error_data_o: out std_logic_vector(15 downto 0)
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
	component flash_probe is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			req_valid_o: out std_logic;
			req_ready_i: in std_logic;
			req_id_o: out std_logic;
			req_addr_o: out std_logic_vector(23 downto 0);
			req_len_o: out std_logic_vector(23 downto 0);
			data_valid_i: in std_logic;
			data_ready_o: out std_logic;
			data_i: in std_logic_vector(7 downto 0);
			data_last_i: in std_logic;
			id_o: out std_logic_vector(23 downto 0);
			data_o: out std_logic_vector(63 downto 0);
			done_o: out std_logic
		);
	end component;
	component ps2_input is
		generic(
			CLK_HZ: natural := 100_000_000
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			enable_i: in std_logic;
			kb_clk_i: in std_logic;
			kb_dat_i: in std_logic;
			ms_clk_i: in std_logic;
			ms_dat_i: in std_logic;
			kb_clk_pull_o: out std_logic;
			kb_dat_pull_o: out std_logic;
			ms_clk_pull_o: out std_logic;
			ms_dat_pull_o: out std_logic;
			frame_start_i: in std_logic;
			snapshot_o: out std_logic_vector(39 downto 0);
			snapshot_valid_o: out std_logic;
			keys_o: out std_logic_vector(KEYS_N - 1 downto 0);
			mouse_buttons_o: out std_logic_vector(2 downto 0);
			mouse_x_total_o: out std_logic_vector(15 downto 0);
			mouse_y_total_o: out std_logic_vector(15 downto 0);
			mouse_state_o: out std_logic_vector(3 downto 0);
			mouse_retries_o: out std_logic_vector(7 downto 0);
			kb_history_o: out std_logic_vector(127 downto 0);
			ms_history_o: out std_logic_vector(127 downto 0);
			kb_errors_o: out std_logic_vector(23 downto 0);
			ms_errors_o: out std_logic_vector(23 downto 0)
		);
	end component;
	component i2s_tx is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			left_i: in std_logic_vector(15 downto 0);
			right_i: in std_logic_vector(15 downto 0);
			sample_req_o: out std_logic;
			mclk_o: out std_logic;
			lrck_o: out std_logic;
			sclk_o: out std_logic;
			sdin_o: out std_logic
		);
	end component;
	component tone_gen is
		generic(
			CLK_HZ: natural := 100_000_000;
			FREQ_HZ: natural := 440
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			enable_i: in std_logic;
			step_i: in std_logic;
			sample_o: out std_logic_vector(15 downto 0)
		);
	end component;
	component debug_port is
		generic(
			CLK_HZ: natural := 100_000_000;
			BAUD: natural := 1_000_000;
			TIMEOUT_MS: natural := 100;
			CTRL_INIT: std_logic_vector(8 * 32 - 1 downto 0) := (others => '0')
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			rx_i: in std_logic;
			tx_o: out std_logic;
			status_i: in std_logic_vector(32 * 32 - 1 downto 0);
			ctrl_o: out std_logic_vector(8 * 32 - 1 downto 0);
			m_req_o: out std_logic;
			m_we_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_wdata_o: out std_logic_vector(7 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0);
			rx_count_o: out std_logic_vector(15 downto 0);
			tx_count_o: out std_logic_vector(15 downto 0)
		);
	end component;

	-- Control register 32 (UART 'W' 32): bit 0 tone on, bit 7 pattern
	-- override with bits 6:4, bit 8 SRAM test on, bit 9 flash re-read
	-- (rising edge), bits 13:12 tint. Register 33: frame start line.
	constant CTRL_INIT: std_logic_vector(8 * 32 - 1 downto 0) :=
		(6 * 32 - 1 downto 0 => '0') & x"00000073" & x"00000101";

	-- Clocks and resets
	signal clk_sys, clk_pix, clk_rd: std_logic;
	signal rst_sys, rst_pix, locked: std_logic;
	signal pcb_on: std_logic;

	-- SRAM
	signal m_req, m_we, m_gnt, m_rvalid: std_logic_vector(3 downto 0);
	signal m_addr: std_logic_vector(4 * 19 - 1 downto 0);
	signal m_wdata: std_logic_vector(4 * 8 - 1 downto 0);
	signal m_rdata: std_logic_vector(7 downto 0);
	signal cmd_valid, cmd_ready, cmd_we: std_logic;
	signal cmd_addr: std_logic_vector(18 downto 0);
	signal cmd_wdata: std_logic_vector(7 downto 0);
	signal cmd_tag, rsp_tag: std_logic_vector(1 downto 0);
	signal rsp_valid, sram_busy: std_logic;
	signal rsp_data: std_logic_vector(7 downto 0);
	signal dq_o, dq_t: std_logic_vector(7 downto 0);
	signal busy_count: std_logic_vector(23 downto 0);
	signal busy_last: std_logic_vector(23 downto 0) := (others => '0');

	-- Display and frames
	signal d_req: std_logic;
	signal d_addr: std_logic_vector(18 downto 0);
	signal vblank, line_start, overrun: std_logic;
	signal line: std_logic_vector(7 downto 0);
	signal vga_r_i, vga_g_i, vga_b_i: std_logic_vector(3 downto 0);
	signal vga_hs_i, vga_vs_i: std_logic;
	signal vga_t: std_logic_vector(13 downto 0);
	signal front, back, rendering: std_logic;
	signal frame_start, frame_done: std_logic;
	signal frame_count, late_count: std_logic_vector(15 downto 0);
	signal overruns: unsigned(15 downto 0) := (others => '0');
	signal pattern_btn: unsigned(2 downto 0) := (others => '0');
	signal pattern: std_logic_vector(2 downto 0);
	signal btn1_rise: std_logic;

	-- Status page and pixel FIFO
	signal values: std_logic_vector(32 * 32 - 1 downto 0);
	signal paint_valid, paint_ready, paint_done: std_logic;
	signal paint_data: std_logic_vector(PIXW_BITS - 1 downto 0);
	signal paint_finished: std_logic := '0';
	signal fifo_valid: std_logic;
	signal fifo_data: std_logic_vector(PIXW_BITS - 1 downto 0);
	signal fifo_level: std_logic_vector(8 downto 0);

	-- SRAM tester
	signal t_req, t_we: std_logic;
	signal t_addr: std_logic_vector(18 downto 0);
	signal t_wdata: std_logic_vector(7 downto 0);
	signal t_phase: std_logic_vector(2 downto 0);
	signal t_passes, t_errors: std_logic_vector(15 downto 0);
	signal t_first_addr: std_logic_vector(18 downto 0);
	signal t_first_data: std_logic_vector(15 downto 0);

	-- Flash
	signal f_req_valid, f_req_ready, f_req_id: std_logic;
	signal f_req_addr, f_req_len: std_logic_vector(23 downto 0);
	signal f_data_valid, f_data_ready, f_data_last: std_logic;
	signal f_data: std_logic_vector(7 downto 0);
	signal f_id: std_logic_vector(23 downto 0);
	signal f_bytes: std_logic_vector(63 downto 0);
	signal f_mosi, f_miso: std_logic;
	signal reprobe_old: std_logic := '0';
	signal reprobe: std_logic;

	-- PS/2
	signal kb_clk_pull, kb_dat_pull, ms_clk_pull, ms_dat_pull: std_logic;
	signal snapshot: std_logic_vector(39 downto 0);
	signal snapshot_valid: std_logic;
	signal snapshot_held: std_logic_vector(39 downto 0) := (others => '0');
	signal keys: std_logic_vector(KEYS_N - 1 downto 0);
	signal mouse_buttons: std_logic_vector(2 downto 0);
	signal mouse_x, mouse_y: std_logic_vector(15 downto 0);
	signal mouse_state: std_logic_vector(3 downto 0);
	signal mouse_retries: std_logic_vector(7 downto 0);
	signal kb_history, ms_history: std_logic_vector(127 downto 0);
	signal kb_errors, ms_errors: std_logic_vector(23 downto 0);

	-- Audio
	signal sample_req: std_logic;
	signal tone: std_logic_vector(15 downto 0);
	signal mclk, lrck, sclk, sdin: std_logic;
	signal i2s_t: std_logic_vector(3 downto 0) := (others => '1');
	attribute IOB: string;
	attribute IOB of i2s_t: signal is "TRUE";

	-- UART debug
	signal ctrl: std_logic_vector(8 * 32 - 1 downto 0);
	signal g_req, g_we: std_logic;
	signal g_addr: std_logic_vector(18 downto 0);
	signal g_wdata: std_logic_vector(7 downto 0);
	signal rx_count, tx_count: std_logic_vector(15 downto 0);

	-- LEDs
	signal pwm: unsigned(4 downto 0) := (others => '0');
	signal pwm_on: std_logic;
	signal led_r, led_g, led_b: std_logic;
begin
	------------------------------------------------------------------
	-- Clocks, resets, PWR_SENSE
	------------------------------------------------------------------
	clocks: clock_reset
		port map (
			clk12_i => clk12,
			btn_rst_i => btn(0),
			clk_sys_o => clk_sys,
			clk_pix_o => clk_pix,
			clk_sram_rd_o => clk_rd,
			rst_sys_o => rst_sys,
			rst_pix_o => rst_pix,
			locked_o => locked
		);

	gate: power_gate
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			pwr_sense_i => pwr_sense,
			pcb_on_o => pcb_on
		);

	------------------------------------------------------------------
	-- SRAM: arbiter, controller, pins
	------------------------------------------------------------------
	-- Packed master buses, master 3 leftmost. The pixel FIFO only writes, at
	-- '0' & buf & (y * 320 + x); the display only reads.
	m_req <= g_req & fifo_valid & t_req & d_req;
	m_we <= g_we & '1' & t_we & '0';
	m_addr <= g_addr & ('0' & fifo_data(PIXW_BUF) & fifo_data(PIXW_ADDR_HI downto PIXW_ADDR_LO)) &
		t_addr & d_addr;
	m_wdata <= g_wdata & fifo_data(PIXW_DATA_HI downto PIXW_DATA_LO) & t_wdata & x"00";

	arb: sram_arbiter
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			m_req_i => m_req,
			m_we_i => m_we,
			m_addr_i => m_addr,
			m_wdata_i => m_wdata,
			m_gnt_o => m_gnt,
			m_rvalid_o => m_rvalid,
			m_rdata_o => m_rdata,
			cmd_valid_o => cmd_valid,
			cmd_ready_i => cmd_ready,
			cmd_we_o => cmd_we,
			cmd_addr_o => cmd_addr,
			cmd_wdata_o => cmd_wdata,
			cmd_tag_o => cmd_tag,
			rsp_valid_i => rsp_valid,
			rsp_data_i => rsp_data,
			rsp_tag_i => rsp_tag,
			busy_i => sram_busy,
			clear_count_i => vblank,
			busy_count_o => busy_count
		);

	sram: sram_controller
		generic map (
			CYCLES => SRAM_CYCLES
		)
		port map (
			clk_i => clk_sys,
			clk_rd_i => clk_rd,
			rst_i => rst_sys,
			cmd_valid_i => cmd_valid,
			cmd_ready_o => cmd_ready,
			cmd_we_i => cmd_we,
			cmd_addr_i => cmd_addr,
			cmd_wdata_i => cmd_wdata,
			cmd_tag_i => cmd_tag,
			rsp_valid_o => rsp_valid,
			rsp_data_o => rsp_data,
			rsp_tag_o => rsp_tag,
			busy_o => sram_busy,
			sram_a_o => sram_a,
			sram_dq_o => dq_o,
			sram_dq_t_o => dq_t,
			sram_dq_i => sram_dq,
			sram_oe_n_o => sram_oe_n,
			sram_we_n_o => sram_we_n,
			sram_ce_n_o => sram_ce_n
		);

	sram_pins: for i in 0 to 7 generate
		sram_dq(i) <= dq_o(i) when (dq_t(i) = '0') else 'Z';
	end generate;

	-- Bus use in the last frame, sampled just before the arbiter clears it
	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			busy_last <= (others => '0');
		elsif rising_edge(clk_sys) then
			if (vblank = '1') then
				busy_last <= busy_count;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Display, frames, test pattern selection
	------------------------------------------------------------------
	btn1: debounce
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			button_i => btn(1),
			level_o => open,
			rise_o => btn1_rise
		);

	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			pattern_btn <= (others => '0');
			overruns <= (others => '0');
		elsif rising_edge(clk_sys) then
			if (btn1_rise = '1') then
				if (pattern_btn = PATTERN_GRADIENT) then
					pattern_btn <= (others => '0');
				else
					pattern_btn <= pattern_btn + 1;
				end if;
			end if;
			if ((overrun = '1') and (overruns /= x"FFFF")) then
				overruns <= overruns + 1;
			end if;
		end if;
	end process;

	pattern <= ctrl(6 downto 4) when (ctrl(7) = '1') else std_logic_vector(pattern_btn);

	display: display_controller
		port map (
			clk_sys_i => clk_sys,
			rst_sys_i => rst_sys,
			clk_pix_i => clk_pix,
			rst_pix_i => rst_pix,
			front_i => front,
			pattern_i => pattern,
			tint_i => ctrl(13 downto 12),
			blank_i => '0',
			pcb_on_i => pcb_on,
			pal_valid_i => '0',
			pal_ready_o => open,
			pal_addr_i => (others => '0'),
			pal_data_i => (others => '0'),
			m_req_o => d_req,
			m_addr_o => d_addr,
			m_gnt_i => m_gnt(MASTER_DISPLAY),
			m_rvalid_i => m_rvalid(MASTER_DISPLAY),
			m_rdata_i => m_rdata,
			vblank_o => vblank,
			line_start_o => line_start,
			line_o => line,
			overrun_o => overrun,
			vga_r_o => vga_r_i,
			vga_g_o => vga_g_i,
			vga_b_o => vga_b_i,
			vga_hs_o => vga_hs_i,
			vga_vs_o => vga_vs_i,
			vga_t_o => vga_t
		);

	-- VGA pins: high impedance until pcb_on (tristate registers in IOBs)
	-- vga_t bits: 3:0 red, 7:4 green, 11:8 blue, 12 HS, 13 VS
	vga_pins: for i in 0 to 3 generate
		vga_r(i) <= vga_r_i(i) when (vga_t(i) = '0') else 'Z';
		vga_g(i) <= vga_g_i(i) when (vga_t(4 + i) = '0') else 'Z';
		vga_b(i) <= vga_b_i(i) when (vga_t(8 + i) = '0') else 'Z';
	end generate;
	vga_hs <= vga_hs_i when (vga_t(12) = '0') else 'Z';
	vga_vs <= vga_vs_i when (vga_t(13) = '0') else 'Z';

	buffers: buffer_manager
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			vblank_i => vblank,
			line_start_i => line_start,
			line_i => line,
			start_line_i => ctrl(32 + 7 downto 32),
			frame_done_i => frame_done,
			frame_start_o => frame_start,
			front_o => front,
			back_o => back,
			rendering_o => rendering,
			frame_count_o => frame_count,
			late_count_o => late_count
		);

	------------------------------------------------------------------
	-- Status page into the back buffer
	------------------------------------------------------------------
	painter: text_painter
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			start_i => frame_start,
			buf_i => back,
			values_i => values,
			pix_valid_o => paint_valid,
			pix_ready_i => paint_ready,
			pix_data_o => paint_data,
			busy_o => open,
			done_o => paint_done
		);

	pixel_fifo: sync_fifo
		generic map (
			WIDTH => PIXW_BITS,
			DEPTH_BITS => 9
		)
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			in_valid_i => paint_valid,
			in_ready_o => paint_ready,
			in_data_i => paint_data,
			out_valid_o => fifo_valid,
			out_ready_i => m_gnt(MASTER_PIXEL),
			out_data_o => fifo_data,
			level_o => fifo_level
		);

	-- The frame is done when the painter has finished and the FIFO has
	-- handed its last pixel to the SRAM controller
	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			paint_finished <= '0';
			frame_done <= '0';
		elsif rising_edge(clk_sys) then
			frame_done <= '0';
			if (paint_done = '1') then
				paint_finished <= '1';
			elsif ((paint_finished = '1') and (fifo_valid = '0') and (unsigned(fifo_level) = 0)) then
				paint_finished <= '0';
				frame_done <= '1';
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- SRAM self-test (master 1)
	------------------------------------------------------------------
	tester: sram_tester
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			enable_i => ctrl(8),
			m_req_o => t_req,
			m_we_o => t_we,
			m_addr_o => t_addr,
			m_wdata_o => t_wdata,
			m_gnt_i => m_gnt(MASTER_SPRITE),
			m_rvalid_i => m_rvalid(MASTER_SPRITE),
			m_rdata_i => m_rdata,
			phase_o => t_phase,
			pass_count_o => t_passes,
			error_count_o => t_errors,
			first_error_addr_o => t_first_addr,
			first_error_data_o => t_first_data
		);

	------------------------------------------------------------------
	-- Flash: JEDEC ID and the data-area test pattern
	------------------------------------------------------------------
	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			reprobe_old <= '0';
		elsif rising_edge(clk_sys) then
			reprobe_old <= ctrl(9);
		end if;
	end process;
	reprobe <= ctrl(9) and (not reprobe_old);

	probe: flash_probe
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			start_i => reprobe,
			req_valid_o => f_req_valid,
			req_ready_i => f_req_ready,
			req_id_o => f_req_id,
			req_addr_o => f_req_addr,
			req_len_o => f_req_len,
			data_valid_i => f_data_valid,
			data_ready_o => f_data_ready,
			data_i => f_data,
			data_last_i => f_data_last,
			id_o => f_id,
			data_o => f_bytes,
			done_o => open
		);

	flash: flash_reader
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			req_valid_i => f_req_valid,
			req_ready_o => f_req_ready,
			req_id_i => f_req_id,
			req_addr_i => f_req_addr,
			req_len_i => f_req_len,
			data_valid_o => f_data_valid,
			data_ready_i => f_data_ready,
			data_o => f_data,
			data_last_o => f_data_last,
			busy_o => open,
			cs_n_o => qspi_cs_n,
			sck_o => qspi_sck,
			mosi_o => f_mosi,
			miso_i => f_miso
		);

	-- Single-bit SPI: DQ0 out, DQ1 in, WP_n and HOLD_n held high
	qspi_dq(0) <= f_mosi;
	qspi_dq(1) <= 'Z';
	qspi_dq(2) <= '1';
	qspi_dq(3) <= '1';
	f_miso <= qspi_dq(1);

	------------------------------------------------------------------
	-- PS/2 keyboard and mouse (open drain, released until pcb_on)
	------------------------------------------------------------------
	ps2: ps2_input
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			enable_i => pcb_on,
			-- to_X01: a pulled-up line reads as '1' (the input buffer's
			-- threshold); in simulation the pull-up is a weak 'H'
			kb_clk_i => to_X01(kb_clk),
			kb_dat_i => to_X01(kb_dat),
			ms_clk_i => to_X01(ms_clk),
			ms_dat_i => to_X01(ms_dat),
			kb_clk_pull_o => kb_clk_pull,
			kb_dat_pull_o => kb_dat_pull,
			ms_clk_pull_o => ms_clk_pull,
			ms_dat_pull_o => ms_dat_pull,
			frame_start_i => frame_start,
			snapshot_o => snapshot,
			snapshot_valid_o => snapshot_valid,
			keys_o => keys,
			mouse_buttons_o => mouse_buttons,
			mouse_x_total_o => mouse_x,
			mouse_y_total_o => mouse_y,
			mouse_state_o => mouse_state,
			mouse_retries_o => mouse_retries,
			kb_history_o => kb_history,
			ms_history_o => ms_history,
			kb_errors_o => kb_errors,
			ms_errors_o => ms_errors
		);

	kb_clk <= '0' when ((kb_clk_pull = '1') and (pcb_on = '1')) else 'Z';
	kb_dat <= '0' when ((kb_dat_pull = '1') and (pcb_on = '1')) else 'Z';
	ms_clk <= '0' when ((ms_clk_pull = '1') and (pcb_on = '1')) else 'Z';
	ms_dat <= '0' when ((ms_dat_pull = '1') and (pcb_on = '1')) else 'Z';

	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			snapshot_held <= (others => '0');
		elsif rising_edge(clk_sys) then
			if (snapshot_valid = '1') then
				snapshot_held <= snapshot;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Audio: 440 Hz test tone, both channels
	------------------------------------------------------------------
	tone_440: tone_gen
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			enable_i => ctrl(0),
			step_i => sample_req,
			sample_o => tone
		);

	i2s: i2s_tx
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			left_i => tone,
			right_i => tone,
			sample_req_o => sample_req,
			mclk_o => mclk,
			lrck_o => lrck,
			sclk_o => sclk,
			sdin_o => sdin
		);

	-- I2S pins: high impedance until pcb_on (tristate registers in IOBs)
	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			i2s_t <= (others => '1');
		elsif rising_edge(clk_sys) then
			i2s_t <= (others => not pcb_on);
		end if;
	end process;

	i2s_mclk <= mclk when (i2s_t(0) = '0') else 'Z';
	i2s_lrck <= lrck when (i2s_t(1) = '0') else 'Z';
	i2s_sclk <= sclk when (i2s_t(2) = '0') else 'Z';
	i2s_sdin <= sdin when (i2s_t(3) = '0') else 'Z';

	------------------------------------------------------------------
	-- UART debug port (master 3) and the status words
	------------------------------------------------------------------
	uart: debug_port
		generic map (
			CTRL_INIT => CTRL_INIT
		)
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			rx_i => uart_txd_in,
			tx_o => uart_rxd_out,
			status_i => values,
			ctrl_o => ctrl,
			m_req_o => g_req,
			m_we_o => g_we,
			m_addr_o => g_addr,
			m_wdata_o => g_wdata,
			m_gnt_i => m_gnt(MASTER_LOADER),
			m_rvalid_i => m_rvalid(MASTER_LOADER),
			m_rdata_i => m_rdata,
			rx_count_o => rx_count,
			tx_count_o => tx_count
		);

	-- Status words, same numbering as tools/bringup/make_page.py
	values(0 * 32 + 31 downto 0 * 32) <= BUILD_ID;
	values(1 * 32 + 31 downto 1 * 32) <= t_passes & t_errors;
	values(2 * 32 + 31 downto 2 * 32) <= "0000000000000" & t_first_addr;
	-- 3: test phase 18:16, first error expected 15:8, read 7:0
	values(3 * 32 + 31 downto 3 * 32) <= x"000" & '0' & t_phase & t_first_data;
	values(4 * 32 + 31 downto 4 * 32) <= x"00" & f_id;
	values(5 * 32 + 31 downto 5 * 32) <= f_bytes(63 downto 32);
	values(6 * 32 + 31 downto 6 * 32) <= f_bytes(31 downto 0);
	values(7 * 32 + 31 downto 7 * 32) <= (others => '0');
	values(11 * 32 + 31 downto 8 * 32) <= kb_history;
	values(15 * 32 + 31 downto 12 * 32) <= ms_history;
	values(16 * 32 + 31 downto 16 * 32) <= x"00" & kb_errors;
	values(17 * 32 + 31 downto 17 * 32) <= x"00" & ms_errors;
	values(18 * 32 + 31 downto 18 * 32) <= std_logic_vector(resize(unsigned(keys), 32));
	values(19 * 32 + 31 downto 19 * 32) <= mouse_x & mouse_y;
	values(20 * 32 + 31 downto 20 * 32) <= x"0000" & mouse_retries & mouse_state & '0' & mouse_buttons;
	values(21 * 32 + 31 downto 21 * 32) <= rx_count & tx_count;
	values(22 * 32 + 31 downto 22 * 32) <= frame_count & late_count;
	values(23 * 32 + 31 downto 23 * 32) <= x"00" & busy_last;
	values(24 * 32 + 31 downto 24 * 32) <= snapshot_held(31 downto 0);
	values(25 * 32 + 31 downto 25 * 32) <= x"000000" & snapshot_held(39 downto 32);
	-- 26: locked 20, PCB on 16, line fetch overruns 15:0
	values(26 * 32 + 31 downto 26 * 32) <= "00000000000" & locked & "000" & pcb_on &
		std_logic_vector(overruns);
	values(27 * 32 + 31 downto 27 * 32) <= x"000000" & '0' & pattern & "000" & ctrl(0); -- Pattern 6:4, tone 0
	values(31 * 32 + 31 downto 28 * 32) <= (others => '0');

	------------------------------------------------------------------
	-- LEDs. The RGB LED is very bright, so it runs at 1/32 duty.
	------------------------------------------------------------------
	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			pwm <= (others => '0');
		elsif rising_edge(clk_sys) then
			pwm <= pwm + 1;
		end if;
	end process;

	led_r <= '1' when ((unsigned(t_errors) /= 0) or (overruns /= 0)) else '0';
	led_g <= frame_count(5); -- Toggles every 32 frames: about 1 Hz
	led_b <= '1' when ((unsigned(kb_errors) /= 0) or (unsigned(ms_errors) /= 0)) else '0';
	pwm_on <= '1' when (pwm = 0) else '0';
	led0_r <= not (led_r and pwm_on);
	led0_g <= not (led_g and pwm_on);
	led0_b <= not (led_b and pwm_on);
	led(0) <= locked;
	led(1) <= pcb_on;
end arch;

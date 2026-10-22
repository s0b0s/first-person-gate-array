--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Stage-1 Game Top Level
-- Module Name:    game_top
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Stage-1 game: walk the textured maze of level 1 in first
--                 person with keyboard and mouse, open doors, never pass
--                 through walls (the stage-1 goal).
--                 Boot: the level loader copies level 1 from flash into the
--                 tile map (the map's power-on contents are level 1 too, so
--                 a failed load still starts the game), then the game runs.
--                 Every frame: the buffer manager pulses frame_start at the
--                 start line; ps2_input latches the input snapshot;
--                 game_seq updates the player and doors; render_top draws
--                 the back buffer; when the last pixel has left the pixel
--                 FIFO the frame is done and the buffers swap at vblank.
--                 Tile map port B: the level loader while it runs, the game
--                 while it updates, otherwise the renderer's floor caster
--                 (the three never overlap in time).
--                 SRAM masters: 0 display, 1 (sprites, stage 2), 2 pixel
--                 FIFO, 3 UART debug port.
--                 UART control register 32: bit 0 test tone, bit 7 test
--                 pattern override with bits 6:4, bits 13:12 tint, bit 16
--                 freeze (no new frames; the front buffer stays for a
--                 dump). Register 33: frame start line (default 115).
--                 Status registers: see the "Status words" block below.
--                 Clock domains: clk_sys (100 MHz), clk_pix (25 MHz),
--                 crossed only inside display_controller.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, every
--                 stage-0 and stage-1 block
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Stage 1
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;
use work.game_pkg.all;
use work.render_types_pkg.all;
use work.map_init_pkg.all;

entity game_top is
	generic(
		BUILD_ID: std_logic_vector(31 downto 0) := x"53470101"; -- Stage 1 build
		POWER_HOLD: positive := 1_000_000 -- PWR_SENSE hold time in clocks (10 ms)
	);
	port(
		clk12: in std_logic; -- 12 MHz oscillator
		btn: in std_logic_vector(1 downto 0); -- BTN0 reset, BTN1 next test pattern
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
		kb_clk: inout std_logic; -- Open drain: '0' or 'Z' only
		kb_dat: inout std_logic;
		ms_clk: inout std_logic;
		ms_dat: inout std_logic;
		pwr_sense: in std_logic -- PCB 3.3 V present (PULLDOWN)
	);
end game_top;

architecture arch of game_top is
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
	component tile_map is
		port(
			clk_i: in std_logic;
			a_addr_i: in std_logic_vector(11 downto 0);
			a_data_o: out std_logic_vector(23 downto 0);
			b_we_i: in std_logic;
			b_addr_i: in std_logic_vector(11 downto 0);
			b_data_i: in std_logic_vector(23 downto 0);
			b_data_o: out std_logic_vector(23 downto 0)
		);
	end component;
	component game_seq is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			load_i: in std_logic;
			start_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			start_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			start_angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			frame_start_i: in std_logic;
			snapshot_i: in std_logic_vector(SNAP_BITS - 1 downto 0);
			snapshot_valid_i: in std_logic;
			map_addr_o: out std_logic_vector(11 downto 0);
			map_data_i: in std_logic_vector(23 downto 0);
			pos_x_o: out std_logic_vector(POS_BITS - 1 downto 0);
			pos_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
			angle_o: out std_logic_vector(ANGLE_BITS - 1 downto 0);
			eye_o: out std_logic_vector(EYE_BITS - 1 downto 0);
			doors_o: out std_logic_vector(DOORS_BITS - 1 downto 0);
			render_start_o: out std_logic;
			busy_o: out std_logic;
			door_state_o: out std_logic_vector(8 * 2 - 1 downto 0);
			door_timer_o: out std_logic_vector(8 * 8 - 1 downto 0)
		);
	end component;
	component render_top is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			pos_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			pos_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			eye_i: in std_logic_vector(EYE_BITS - 1 downto 0);
			doors_i: in std_logic_vector(DOORS_BITS - 1 downto 0);
			fx_i: in std_logic_vector(FX_BITS - 1 downto 0);
			buf_i: in std_logic;
			map_a_addr_o: out std_logic_vector(11 downto 0);
			map_a_data_i: in std_logic_vector(23 downto 0);
			map_b_addr_o: out std_logic_vector(11 downto 0);
			map_b_data_i: in std_logic_vector(23 downto 0);
			pix_valid_o: out std_logic;
			pix_ready_i: in std_logic;
			pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
			zbuf_addr_i: in std_logic_vector(8 downto 0);
			zbuf_data_o: out std_logic_vector(15 downto 0);
			seen_we_o: out std_logic;
			seen_addr_o: out std_logic_vector(11 downto 0);
			clip_raddr_i: in std_logic_vector(12 downto 0);
			clip_rdata_o: out std_logic_vector(CLIP_BITS - 1 downto 0);
			ccount_raddr_i: in std_logic_vector(8 downto 0);
			ccount_rdata_o: out std_logic_vector(4 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic;
			cycles_o: out std_logic_vector(23 downto 0)
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

	-- Control registers: 32 = tone off, no override; 33 = start line 115
	constant CTRL_INIT: std_logic_vector(8 * 32 - 1 downto 0) :=
		(6 * 32 - 1 downto 0 => '0') & x"00000073" & x"00000000";
	constant LEVEL_ID: std_logic_vector(7 downto 0) := x"01";

	type boot_t is (B_START, B_LOADING, B_RUN);
	signal boot: boot_t := B_START;

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
	signal bm_frame_start, frame_done: std_logic;
	signal frame_count, late_count: std_logic_vector(15 downto 0);
	signal pattern_btn: unsigned(2 downto 0) := (others => '0');
	signal pattern: std_logic_vector(2 downto 0);
	signal btn1_rise: std_logic;
	signal blank: std_logic;
	signal shown: std_logic := '0'; -- A rendered frame is on screen

	-- Game frame control
	signal freeze, freeze_old: std_logic := '0';
	signal frame_go: std_logic; -- Start a game frame now
	signal frame_open: std_logic := '0'; -- Game frame in progress
	signal draining: std_logic := '0'; -- Renderer done, pixel FIFO emptying
	signal snapshot: std_logic_vector(39 downto 0);
	signal snapshot_valid: std_logic;
	signal snapshot_held: std_logic_vector(39 downto 0) := (others => '0');

	-- Flash and level loader
	signal f_req_valid, f_req_ready, f_req_id: std_logic;
	signal f_req_addr, f_req_len: std_logic_vector(23 downto 0);
	signal f_data_valid, f_data_ready, f_data_last: std_logic;
	signal f_data: std_logic_vector(7 downto 0);
	signal f_mosi, f_miso: std_logic;
	signal load_start, load_busy, load_done, load_error: std_logic;
	signal ld_we: std_logic;
	signal ld_addr: std_logic_vector(11 downto 0);
	signal ld_data: std_logic_vector(23 downto 0);
	signal ld_x, ld_y: std_logic_vector(POS_BITS - 1 downto 0);
	signal ld_angle: std_logic_vector(ANGLE_BITS - 1 downto 0);
	signal game_load: std_logic := '0';
	signal start_x, start_y: std_logic_vector(POS_BITS - 1 downto 0) := LEVEL1_START_X;
	signal start_angle: std_logic_vector(ANGLE_BITS - 1 downto 0) := LEVEL1_START_ANGLE;
	signal load_status: std_logic_vector(1 downto 0) := "00"; -- 01 loaded, 10 failed

	-- Tile map
	signal map_a_addr: std_logic_vector(11 downto 0);
	signal map_a_data: std_logic_vector(23 downto 0);
	signal map_b_we: std_logic;
	signal map_b_addr: std_logic_vector(11 downto 0);
	signal map_b_wdata: std_logic_vector(23 downto 0);
	signal map_b_data: std_logic_vector(23 downto 0);
	signal game_map_addr, render_map_addr: std_logic_vector(11 downto 0);

	-- Game and renderer
	signal game_busy, render_start: std_logic;
	signal pos_x, pos_y: std_logic_vector(POS_BITS - 1 downto 0);
	signal angle: std_logic_vector(ANGLE_BITS - 1 downto 0);
	signal eye: std_logic_vector(EYE_BITS - 1 downto 0);
	signal doors: std_logic_vector(DOORS_BITS - 1 downto 0);
	signal render_busy, render_done: std_logic;
	signal render_cycles: std_logic_vector(23 downto 0);
	signal pix_valid, pix_ready: std_logic;
	signal pix_data: std_logic_vector(PIXW_BITS - 1 downto 0);
	signal fifo_valid: std_logic;
	signal fifo_data: std_logic_vector(PIXW_BITS - 1 downto 0);
	signal fifo_level: std_logic_vector(8 downto 0);

	-- PS/2
	signal kb_clk_pull, kb_dat_pull, ms_clk_pull, ms_dat_pull: std_logic;
	signal keys: std_logic_vector(KEYS_N - 1 downto 0);
	signal mouse_buttons: std_logic_vector(2 downto 0);
	signal mouse_x, mouse_y: std_logic_vector(15 downto 0);
	signal mouse_state: std_logic_vector(3 downto 0);
	signal mouse_retries: std_logic_vector(7 downto 0);
	signal kb_errors, ms_errors: std_logic_vector(23 downto 0);

	-- Audio
	signal sample_req: std_logic;
	signal tone: std_logic_vector(15 downto 0);
	signal mclk, lrck, sclk, sdin: std_logic;
	signal i2s_t: std_logic_vector(3 downto 0) := (others => '1');
	attribute IOB: string;
	attribute IOB of i2s_t: signal is "TRUE";

	-- UART debug
	signal values: std_logic_vector(32 * 32 - 1 downto 0);
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
		generic map (
			HOLD_CYCLES => POWER_HOLD
		)
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			pwr_sense_i => pwr_sense,
			pcb_on_o => pcb_on
		);

	------------------------------------------------------------------
	-- SRAM: arbiter, controller, pins
	------------------------------------------------------------------
	-- Packed master buses, master 3 leftmost; master 1 is unused in stage 1.
	-- The pixel FIFO only writes, at '0' & buf & (y * 320 + x).
	m_req <= g_req & fifo_valid & '0' & d_req;
	m_we <= g_we & '1' & '0' & '0';
	m_addr <= g_addr & ('0' & fifo_data(PIXW_BUF) & fifo_data(PIXW_ADDR_HI downto PIXW_ADDR_LO)) &
		(18 downto 0 => '0') & d_addr;
	m_wdata <= g_wdata & fifo_data(PIXW_DATA_HI downto PIXW_DATA_LO) & x"00" & x"00";

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
	-- Display, buffers, test pattern selection
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
			shown <= '0';
		elsif rising_edge(clk_sys) then
			if (btn1_rise = '1') then
				if (pattern_btn = PATTERN_GRADIENT) then
					pattern_btn <= (others => '0');
				else
					pattern_btn <= pattern_btn + 1;
				end if;
			end if;
			-- The SRAM holds garbage until the first frame is drawn and swapped
			if (unsigned(frame_count) >= 1) then
				shown <= '1';
			end if;
		end if;
	end process;

	pattern <= ctrl(6 downto 4) when (ctrl(7) = '1') else std_logic_vector(pattern_btn);
	blank <= '1' when ((shown = '0') and (unsigned(pattern) = PATTERN_FRAMEBUFFER)) else '0';

	display: display_controller
		port map (
			clk_sys_i => clk_sys,
			rst_sys_i => rst_sys,
			clk_pix_i => clk_pix,
			rst_pix_i => rst_pix,
			front_i => front,
			pattern_i => pattern,
			tint_i => ctrl(13 downto 12),
			blank_i => blank,
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
			frame_start_o => bm_frame_start,
			front_o => front,
			back_o => back,
			rendering_o => rendering,
			frame_count_o => frame_count,
			late_count_o => late_count
		);

	------------------------------------------------------------------
	-- Boot: load level 1 from flash, then run
	------------------------------------------------------------------
	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			boot <= B_START;
			game_load <= '0';
			start_x <= LEVEL1_START_X;
			start_y <= LEVEL1_START_Y;
			start_angle <= LEVEL1_START_ANGLE;
			load_status <= "00";
		elsif rising_edge(clk_sys) then
			game_load <= '0';
			case boot is
				when B_START =>
					boot <= B_LOADING;
				when B_LOADING =>
					if (load_done = '1') then
						start_x <= ld_x;
						start_y <= ld_y;
						start_angle <= ld_angle;
						load_status <= "01";
						game_load <= '1';
						boot <= B_RUN;
					elsif (load_error = '1') then
						-- The map still holds its power-on copy of level 1
						load_status <= "10";
						game_load <= '1';
						boot <= B_RUN;
					end if;
				when B_RUN =>
					null;
			end case;
		end if;
	end process;

	load_start <= '1' when (boot = B_START) else '0';

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

	-- Single-bit SPI: DQ0 = MOSI, DQ1 = MISO, DQ2 (WP_n) and DQ3 (HOLD_n) high
	qspi_dq(0) <= f_mosi;
	qspi_dq(1) <= 'Z';
	qspi_dq(2) <= '1';
	qspi_dq(3) <= '1';
	f_miso <= qspi_dq(1);

	loader: level_loader
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			start_i => load_start,
			level_id_i => LEVEL_ID,
			req_valid_o => f_req_valid,
			req_ready_i => f_req_ready,
			req_id_o => f_req_id,
			req_addr_o => f_req_addr,
			req_len_o => f_req_len,
			data_valid_i => f_data_valid,
			data_ready_o => f_data_ready,
			data_i => f_data,
			data_last_i => f_data_last,
			map_we_o => ld_we,
			map_addr_o => ld_addr,
			map_data_o => ld_data,
			start_x_o => ld_x,
			start_y_o => ld_y,
			start_angle_o => ld_angle,
			busy_o => load_busy,
			done_o => load_done,
			error_o => load_error
		);

	------------------------------------------------------------------
	-- Tile map; port B goes to the loader, the game or the renderer
	------------------------------------------------------------------
	map_b_we <= ld_we when (boot /= B_RUN) else '0';
	map_b_addr <= ld_addr when (boot /= B_RUN) else
		game_map_addr when (game_busy = '1') else
		render_map_addr;
	map_b_wdata <= ld_data;

	tiles: tile_map
		port map (
			clk_i => clk_sys,
			a_addr_i => map_a_addr,
			a_data_o => map_a_data,
			b_we_i => map_b_we,
			b_addr_i => map_b_addr,
			b_data_i => map_b_wdata,
			b_data_o => map_b_data
		);

	------------------------------------------------------------------
	-- Frame control: game update, render, drain, done
	------------------------------------------------------------------
	freeze <= ctrl(16);

	-- A game frame starts at the buffer manager's start line, or right
	-- after an unfreeze if the buffer manager is still waiting for the
	-- frame it asked for while frozen
	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			freeze_old <= '0';
			frame_open <= '0';
			draining <= '0';
			frame_done <= '0';
		elsif rising_edge(clk_sys) then
			freeze_old <= freeze;
			frame_done <= '0';
			if (frame_go = '1') then
				frame_open <= '1';
			end if;
			if (render_done = '1') then
				draining <= '1';
			elsif ((draining = '1') and (fifo_valid = '0') and (unsigned(fifo_level) = 0)) then
				draining <= '0';
				frame_open <= '0';
				frame_done <= '1';
			end if;
		end if;
	end process;

	frame_go <= '1' when ((boot = B_RUN) and (freeze = '0') and (frame_open = '0') and
		((bm_frame_start = '1') or ((freeze_old = '1') and (rendering = '1')))) else '0';

	game: game_seq
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			load_i => game_load,
			start_x_i => start_x,
			start_y_i => start_y,
			start_angle_i => start_angle,
			frame_start_i => frame_go,
			snapshot_i => snapshot,
			snapshot_valid_i => snapshot_valid,
			map_addr_o => game_map_addr,
			map_data_i => map_b_data,
			pos_x_o => pos_x,
			pos_y_o => pos_y,
			angle_o => angle,
			eye_o => eye,
			doors_o => doors,
			render_start_o => render_start,
			busy_o => game_busy,
			door_state_o => open,
			door_timer_o => open
		);

	renderer: render_top
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			start_i => render_start,
			pos_x_i => pos_x,
			pos_y_i => pos_y,
			angle_i => angle,
			eye_i => eye,
			doors_i => doors,
			fx_i => (others => '0'), -- Stage-1 game: no light effects or animation
			buf_i => back,
			map_a_addr_o => map_a_addr,
			map_a_data_i => map_a_data,
			map_b_addr_o => render_map_addr,
			map_b_data_i => map_b_data,
			pix_valid_o => pix_valid,
			pix_ready_i => pix_ready,
			pix_data_o => pix_data,
			zbuf_addr_i => (others => '0'),
			zbuf_data_o => open,
			seen_we_o => open,
			seen_addr_o => open,
			clip_raddr_i => (others => '0'), -- Stage-1 game: no sprites to clip
			clip_rdata_o => open,
			ccount_raddr_i => (others => '0'),
			ccount_rdata_o => open,
			busy_o => render_busy,
			done_o => render_done,
			cycles_o => render_cycles
		);

	pixel_fifo: sync_fifo
		generic map (
			WIDTH => PIXW_BITS,
			DEPTH_BITS => 9
		)
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			in_valid_i => pix_valid,
			in_ready_o => pix_ready,
			in_data_i => pix_data,
			out_valid_o => fifo_valid,
			out_ready_i => m_gnt(MASTER_PIXEL),
			out_data_o => fifo_data,
			level_o => fifo_level
		);

	------------------------------------------------------------------
	-- PS/2 keyboard and mouse
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
			frame_start_i => frame_go,
			snapshot_o => snapshot,
			snapshot_valid_o => snapshot_valid,
			keys_o => keys,
			mouse_buttons_o => mouse_buttons,
			mouse_x_total_o => mouse_x,
			mouse_y_total_o => mouse_y,
			mouse_state_o => mouse_state,
			mouse_retries_o => mouse_retries,
			kb_history_o => open,
			ms_history_o => open,
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
	-- Audio: test tone only in stage 1 (off by default)
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
	-- UART debug port and status words
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

	-- Status words (UART register n = word n)
	values(0 * 32 + 31 downto 0 * 32) <= BUILD_ID;
	values(1 * 32 + 31 downto 1 * 32) <= "0000000000" & pos_x; -- Player x, Q6.16
	values(2 * 32 + 31 downto 2 * 32) <= "0000000000" & pos_y; -- Player y, Q6.16
	values(3 * 32 + 31 downto 3 * 32) <= x"00" & '0' & eye & "000000" & angle; -- Eye 22:16, angle 9:0
	values(4 * 32 + 31 downto 4 * 32) <= x"00" & render_cycles; -- Last frame render clocks
	values(5 * 32 + 31 downto 5 * 32) <= frame_count & late_count;
	values(6 * 32 + 31 downto 6 * 32) <= x"00" & busy_last; -- SRAM busy clocks last frame
	values(7 * 32 + 31 downto 7 * 32) <= x"0000000" & "00" & load_status; -- 1 loaded, 2 failed
	values(8 * 32 + 31 downto 8 * 32) <= snapshot_held(31 downto 0);
	values(9 * 32 + 31 downto 9 * 32) <= x"000000" & snapshot_held(39 downto 32);
	values(10 * 32 + 31 downto 10 * 32) <= std_logic_vector(resize(unsigned(keys), 32));
	values(11 * 32 + 31 downto 11 * 32) <= mouse_x & mouse_y;
	values(12 * 32 + 31 downto 12 * 32) <= x"00" & kb_errors;
	values(13 * 32 + 31 downto 13 * 32) <= x"00" & ms_errors;
	-- 14: mouse retries 15:8, start-up state 7:4, buttons 2:0
	values(14 * 32 + 31 downto 14 * 32) <= x"0000" & mouse_retries & mouse_state & '0' & mouse_buttons;
	values(15 * 32 + 31 downto 15 * 32) <= rx_count & tx_count;
	values(16 * 32 + 31 downto 16 * 32) <= x"0000000" & '0' & front & locked & pcb_on; -- 2 front, 1 locked, 0 PCB on
	-- Words 17..24: the door table as rendered (x, y, open per entry), so
	-- the PC can render the same frame with the model (frame capture)
	door_words: for k in 0 to 7 generate
		values((17 + k) * 32 + 31 downto (17 + k) * 32) <=
			"0000000000000" & doors(k * DOOR_BITS + DOOR_BITS - 1 downto k * DOOR_BITS);
	end generate;
	values(31 * 32 + 31 downto 25 * 32) <= (others => '0');

	------------------------------------------------------------------
	-- LEDs (RGB at 1/32 duty): red = late frames or PS/2 errors,
	-- green = heartbeat, blue = level load failed
	------------------------------------------------------------------
	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			pwm <= (others => '0');
		elsif rising_edge(clk_sys) then
			pwm <= pwm + 1;
		end if;
	end process;

	pwm_on <= '1' when (pwm = 0) else '0';
	led_r <= '1' when ((unsigned(kb_errors) /= 0) or (unsigned(ms_errors) /= 0)) else '0';
	led_g <= frame_count(5); -- Toggles every 32 frames: about 1 Hz
	led_b <= load_status(1);
	led0_r <= not (led_r and pwm_on);
	led0_g <= not (led_g and pwm_on);
	led0_b <= not (led_b and pwm_on);
	led(0) <= locked;
	led(1) <= pcb_on;
end arch;

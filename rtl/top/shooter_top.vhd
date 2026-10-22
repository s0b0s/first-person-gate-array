--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    First-Person Gate Array Top Level
-- Module Name:    shooter_top
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    The full game (stages 2 and 3): title, briefing, three
--                 levels with monsters, items, weapons, keys and doors,
--                 score screens, ending; HUD, minimap and automap; sound
--                 effects and music; deterministic replay. game_top stays
--                 as the saved stage-1 design.
--                 Boot: the asset loader copies the sprite art from flash
--                 into SRAM (about 64 ms, screen black), then the game
--                 runs. Levels load when the game core asks (briefing,
--                 restart): map and actor records from flash, then the
--                 game core finishes the level reset and the renderer
--                 clears the minimap's seen bits.
--                 Every frame: the buffer
--                 manager pulses frame_start at the start line; ps2_input
--                 latches the input snapshot; the replay unit passes it
--                 on (or replaces it in play mode); game_core runs one
--                 step and pulses render_start; frame_renderer draws
--                 walls, sprites and overlay into the back buffer; when
--                 the last pixel has left the pixel FIFO the frame is done
--                 and the buffers swap at vblank. The step's sound
--                 commands go to the audio mixer.
--                 Tile map port B: the asset loader while it loads, the
--                 game core while it steps, otherwise the renderer (floor
--                 casting, then the minimap); the three never overlap.
--                 SRAM masters: 0 display; 1 art (boot art copy, then the
--                 frame renderer's sprite and weapon reads, through
--                 sram_port_mux); 2 pixel FIFO; 3 UART debug port and
--                 replay unit (sram_port_mux).
--                 Flash: flash_arbiter, audio refills first, then loader.
--                 UART control registers (ctrl word n = register 32 + n):
--                   32 bit 0 test tone instead of the mixer, bit 7 test
--                      pattern override with bits 6:4, bits 13:12 tint
--                      override (0 = the game's tint), bit 16 freeze (no
--                      new frames), bit 17 audio off
--                   33 frame start line (default 115)
--                   34 bits 5:0 master volume (default 32)
--                   35 bits 1:0 replay mode (0 pass, 1 record, 2 play)
--                   36 bits 6:0 game state word shown in status 26, 27
--                 Status registers: see the "Status words" block below.
--                 Clock domains: clk_sys (100 MHz), clk_pix (25 MHz),
--                 crossed only inside display_controller.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, every
--                 stage-0 block, frame_renderer (and the render blocks),
--                 game_core, asset_loader, flash_arbiter, audio_mixer,
--                 replay_unit, sram_port_mux
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Stages 2 and 3
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;
use work.game_pkg.all;
use work.render_types_pkg.all;

entity shooter_top is
	generic(
		BUILD_ID: std_logic_vector(31 downto 0) := x"53470301"; -- Stage 2/3 build
		POWER_HOLD: positive := 1_000_000; -- PWR_SENSE hold time in clocks (10 ms)
		REPLAY_INIT: natural range 0 to 2 := 0; -- Replay mode at reset (2: the system testbench plays a session)
		BOOT_ART: boolean := true -- false: no art copy at boot (simulation preloads the SRAM)
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
end shooter_top;

architecture arch of shooter_top is
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
	component sram_port_mux is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			a_req_i: in std_logic;
			a_we_i: in std_logic;
			a_addr_i: in std_logic_vector(18 downto 0);
			a_wdata_i: in std_logic_vector(7 downto 0);
			a_gnt_o: out std_logic;
			a_rvalid_o: out std_logic;
			b_req_i: in std_logic;
			b_we_i: in std_logic;
			b_addr_i: in std_logic_vector(18 downto 0);
			b_wdata_i: in std_logic_vector(7 downto 0);
			b_gnt_o: out std_logic;
			b_rvalid_o: out std_logic;
			m_req_o: out std_logic;
			m_we_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_wdata_o: out std_logic_vector(7 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic
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
	component game_core is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			load_req_o: out std_logic;
			load_level_o: out std_logic_vector(1 downto 0);
			load_done_i: in std_logic;
			start_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			start_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			start_angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			act_we_i: in std_logic;
			act_addr_i: in std_logic_vector(4 downto 0);
			act_data_i: in std_logic_vector(63 downto 0);
			frame_start_i: in std_logic;
			snapshot_i: in std_logic_vector(SNAP_BITS - 1 downto 0);
			snapshot_valid_i: in std_logic;
			map_addr_o: out std_logic_vector(11 downto 0);
			map_we_o: out std_logic;
			map_wdata_o: out std_logic_vector(23 downto 0);
			map_data_i: in std_logic_vector(23 downto 0);
			span_addr_o: out std_logic_vector(4 downto 0);
			span_data_i: in std_logic_vector(SPAN_BITS - 1 downto 0);
			span_count_i: in std_logic_vector(5 downto 0);
			zwall_addr_o: out std_logic_vector(8 downto 0);
			zwall_data_i: in std_logic_vector(15 downto 0);
			cam_x_o: out std_logic_vector(POS_BITS - 1 downto 0);
			cam_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
			angle_o: out std_logic_vector(ANGLE_BITS - 1 downto 0);
			eye_o: out std_logic_vector(EYE_BITS - 1 downto 0);
			doors_o: out std_logic_vector(DOORS_BITS - 1 downto 0);
			player_x_o: out std_logic_vector(POS_BITS - 1 downto 0);
			player_y_o: out std_logic_vector(POS_BITS - 1 downto 0);
			hud_o: out std_logic_vector(HUD_BITS - 1 downto 0);
			keypos_o: out std_logic_vector(KEYPOS_BITS - 1 downto 0);
			music_o: out std_logic_vector(1 downto 0);
			tint_o: out std_logic_vector(1 downto 0);
			fx_o: out std_logic_vector(FX_BITS - 1 downto 0);
			spr_addr_i: in std_logic_vector(4 downto 0);
			spr_data_o: out std_logic_vector(SPR_BITS - 1 downto 0);
			spr_count_o: out std_logic_vector(5 downto 0);
			render_start_o: out std_logic;
			busy_o: out std_logic;
			snd_valid_o: out std_logic;
			snd_ready_i: in std_logic;
			snd_data_o: out std_logic_vector(SND_BITS - 1 downto 0);
			level_loaded_o: out std_logic;
			state_addr_i: in std_logic_vector(6 downto 0);
			state_data_o: out std_logic_vector(63 downto 0);
			crc_o: out std_logic_vector(31 downto 0)
		);
	end component;
	component frame_renderer is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			cam_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			cam_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			eye_i: in std_logic_vector(EYE_BITS - 1 downto 0);
			doors_i: in std_logic_vector(DOORS_BITS - 1 downto 0);
			fx_i: in std_logic_vector(FX_BITS - 1 downto 0);
			player_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			player_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			hud_i: in std_logic_vector(HUD_BITS - 1 downto 0);
			keypos_i: in std_logic_vector(KEYPOS_BITS - 1 downto 0);
			debug_i: in std_logic_vector(4 * 24 - 1 downto 0);
			buf_i: in std_logic;
			spr_addr_o: out std_logic_vector(4 downto 0);
			spr_data_i: in std_logic_vector(SPR_BITS - 1 downto 0);
			spr_count_i: in std_logic_vector(5 downto 0);
			gz_addr_i: in std_logic_vector(8 downto 0);
			gz_data_o: out std_logic_vector(15 downto 0);
			span_raddr_i: in std_logic_vector(4 downto 0);
			span_rdata_o: out std_logic_vector(SPAN_BITS - 1 downto 0);
			span_count_o: out std_logic_vector(5 downto 0);
			seen_clear_i: in std_logic;
			map_a_addr_o: out std_logic_vector(11 downto 0);
			map_a_data_i: in std_logic_vector(23 downto 0);
			map_b_addr_o: out std_logic_vector(11 downto 0);
			map_b_data_i: in std_logic_vector(23 downto 0);
			m_req_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0);
			pix_valid_o: out std_logic;
			pix_ready_i: in std_logic;
			pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic;
			cycles_o: out std_logic_vector(23 downto 0);
			sprite_pixels_o: out std_logic_vector(15 downto 0)
		);
	end component;
	component ps2_input is
		generic(
			CLK_HZ: natural := 100_000_000;
			SAMPLE_HZ: natural := 1_000_000;
			RX_TIMEOUT_US: natural := 2_000;
			TX_INHIBIT_US: natural := 150;
			TX_TIMEOUT_US: natural := 20_000;
			MOUSE_STARTUP_US: natural := 500_000;
			MOUSE_RESP_US: natural := 1_000_000;
			PACKET_GAP_US: natural := 3_000;
			MOUSE_SHIFT: natural := 1;
			KEY_TURN: natural := 6
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
	component replay_unit is
		generic(
			MAX_FRAMES: positive := 3600
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			mode_i: in std_logic_vector(1 downto 0);
			frames_o: out std_logic_vector(15 downto 0);
			snap_in_i: in std_logic_vector(SNAP_BITS - 1 downto 0);
			snap_in_valid_i: in std_logic;
			snap_out_o: out std_logic_vector(SNAP_BITS - 1 downto 0);
			snap_out_valid_o: out std_logic;
			crc_i: in std_logic_vector(31 downto 0);
			crc_valid_i: in std_logic;
			m_req_o: out std_logic;
			m_we_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_wdata_o: out std_logic_vector(7 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0)
		);
	end component;
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

	-- Control registers: 32 = 0, 33 = start line 115, 34 = master volume 32,
	-- 35 = replay mode REPLAY_INIT, rest 0
	constant CTRL_INIT: std_logic_vector(8 * 32 - 1 downto 0) :=
		(4 * 32 - 1 downto 0 => '0') & std_logic_vector(to_unsigned(REPLAY_INIT, 32)) &
		x"00000020" & x"00000073" & x"00000000";

	-- Boot: copy the art, then run (levels load on the game core's request)
	type boot_t is (B_START, B_ART, B_RUN);
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
	signal art_req, art_we: std_logic;
	signal art_addr: std_logic_vector(18 downto 0);
	signal art_wdata: std_logic_vector(7 downto 0);
	signal dbg_req, dbg_we: std_logic;
	signal dbg_addr: std_logic_vector(18 downto 0);
	signal dbg_wdata: std_logic_vector(7 downto 0);

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
	signal tint: std_logic_vector(1 downto 0);

	-- Game frame control
	signal freeze: std_logic := '0';
	signal frame_owed: std_logic := '0'; -- The buffer manager asked while the game could not start
	signal frame_go: std_logic; -- Start a game frame now
	signal frame_open: std_logic := '0'; -- Game frame in progress
	signal draining: std_logic := '0'; -- Renderer done, pixel FIFO emptying
	signal snapshot, play_snapshot: std_logic_vector(SNAP_BITS - 1 downto 0);
	signal snapshot_valid, play_snapshot_valid: std_logic;
	signal snapshot_held: std_logic_vector(SNAP_BITS - 1 downto 0) := (others => '0');

	-- Flash: reader, arbiter, clients
	signal f_req_valid, f_req_ready, f_req_id: std_logic;
	signal f_req_addr, f_req_len: std_logic_vector(23 downto 0);
	signal f_data_valid, f_data_ready, f_data_last: std_logic;
	signal f_data: std_logic_vector(7 downto 0);
	signal f_mosi, f_miso: std_logic;
	signal au_req_valid, au_req_ready, au_req_id: std_logic;
	signal au_req_addr, au_req_len: std_logic_vector(23 downto 0);
	signal au_data_valid, au_data_ready, au_data_last: std_logic;
	signal au_data: std_logic_vector(7 downto 0);
	signal ld_req_valid, ld_req_ready, ld_req_id: std_logic;
	signal ld_req_addr, ld_req_len: std_logic_vector(23 downto 0);
	signal ld_data_valid, ld_data_ready, ld_data_last: std_logic;
	signal ld_data: std_logic_vector(7 downto 0);

	-- Asset loader
	signal art_start, level_start: std_logic := '0';
	signal level_num: std_logic_vector(1 downto 0) := "01";
	signal ld_busy, ld_done, ld_error: std_logic;
	signal ld_map_we: std_logic;
	signal ld_map_addr: std_logic_vector(11 downto 0);
	signal ld_map_data: std_logic_vector(23 downto 0);
	signal ld_act_we: std_logic;
	signal ld_act_addr: std_logic_vector(4 downto 0);
	signal ld_act_data: std_logic_vector(63 downto 0);
	signal ld_x, ld_y: std_logic_vector(POS_BITS - 1 downto 0);
	signal ld_angle: std_logic_vector(ANGLE_BITS - 1 downto 0);
	signal ld_m_req, ld_m_we: std_logic;
	signal ld_m_addr: std_logic_vector(18 downto 0);
	signal ld_m_wdata: std_logic_vector(7 downto 0);
	signal ld_m_gnt: std_logic;
	signal level_loading: std_logic := '0'; -- A level job runs for the game core
	signal level_pending: std_logic := '0'; -- The game core asked, the loader is not free yet
	signal level_load_done: std_logic := '0';
	signal art_status: std_logic_vector(1 downto 0) := "00"; -- 01 copied, 10 failed
	signal level_status: std_logic_vector(1 downto 0) := "00"; -- Last level load: 01 ok, 10 failed

	-- Tile map
	signal map_a_addr: std_logic_vector(11 downto 0);
	signal map_a_data: std_logic_vector(23 downto 0);
	signal map_b_we: std_logic;
	signal map_b_addr: std_logic_vector(11 downto 0);
	signal map_b_wdata: std_logic_vector(23 downto 0);
	signal map_b_data: std_logic_vector(23 downto 0);

	-- Game core
	signal core_load_req: std_logic;
	signal core_load_level: std_logic_vector(1 downto 0);
	signal core_map_addr: std_logic_vector(11 downto 0);
	signal core_map_we: std_logic;
	signal core_map_wdata: std_logic_vector(23 downto 0);
	signal core_span_addr: std_logic_vector(4 downto 0);
	signal core_zwall_addr: std_logic_vector(8 downto 0);
	signal cam_x, cam_y, player_x, player_y: std_logic_vector(POS_BITS - 1 downto 0);
	signal angle: std_logic_vector(ANGLE_BITS - 1 downto 0);
	signal eye: std_logic_vector(EYE_BITS - 1 downto 0);
	signal doors: std_logic_vector(DOORS_BITS - 1 downto 0);
	signal hud: std_logic_vector(HUD_BITS - 1 downto 0);
	signal keypos: std_logic_vector(KEYPOS_BITS - 1 downto 0);
	signal music: std_logic_vector(1 downto 0);
	signal game_tint: std_logic_vector(1 downto 0);
	signal fx: std_logic_vector(FX_BITS - 1 downto 0);
	signal render_start, core_busy, level_loaded: std_logic;
	signal snd_valid, snd_ready: std_logic;
	signal snd_data: std_logic_vector(SND_BITS - 1 downto 0);
	signal state_data: std_logic_vector(63 downto 0);
	signal crc: std_logic_vector(31 downto 0);

	-- Frame renderer
	signal spr_addr: std_logic_vector(4 downto 0);
	signal spr_data: std_logic_vector(SPR_BITS - 1 downto 0);
	signal spr_count: std_logic_vector(5 downto 0);
	signal zwall_data: std_logic_vector(15 downto 0);
	signal span_data: std_logic_vector(SPAN_BITS - 1 downto 0);
	signal span_count: std_logic_vector(5 downto 0);
	signal fr_map_b_addr: std_logic_vector(11 downto 0);
	signal fr_m_req: std_logic;
	signal fr_m_addr: std_logic_vector(18 downto 0);
	signal fr_m_gnt, fr_m_rvalid: std_logic;
	signal render_busy, render_done: std_logic;
	signal render_cycles: std_logic_vector(23 downto 0);
	signal sprite_pixels: std_logic_vector(15 downto 0);
	signal debug_values: std_logic_vector(4 * 24 - 1 downto 0);
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
	signal tone, mix_left, mix_right, out_left, out_right: std_logic_vector(15 downto 0);
	signal audio_on: std_logic;
	signal underflows: std_logic_vector(15 downto 0);
	signal mclk, lrck, sclk, sdin: std_logic;
	signal i2s_t: std_logic_vector(3 downto 0) := (others => '1');
	attribute IOB: string;
	attribute IOB of i2s_t: signal is "TRUE";

	-- Replay
	signal replay_frames: std_logic_vector(15 downto 0);
	signal rp_req, rp_we: std_logic;
	signal rp_addr: std_logic_vector(18 downto 0);
	signal rp_wdata: std_logic_vector(7 downto 0);
	signal rp_gnt, rp_rvalid: std_logic;

	-- UART debug
	signal values: std_logic_vector(32 * 32 - 1 downto 0);
	signal ctrl: std_logic_vector(8 * 32 - 1 downto 0);
	signal g_req, g_we: std_logic;
	signal g_addr: std_logic_vector(18 downto 0);
	signal g_wdata: std_logic_vector(7 downto 0);
	signal g_gnt, g_rvalid: std_logic;
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
	-- SRAM: two port muxes, arbiter, controller, pins
	------------------------------------------------------------------
	-- Master 1: the asset loader writes the art at boot; afterwards the
	-- frame renderer reads it (they never overlap, the mux keeps read
	-- data with the right client anyway)
	art_mux: sram_port_mux
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			a_req_i => ld_m_req,
			a_we_i => ld_m_we,
			a_addr_i => ld_m_addr,
			a_wdata_i => ld_m_wdata,
			a_gnt_o => ld_m_gnt,
			a_rvalid_o => open,
			b_req_i => fr_m_req,
			b_we_i => '0',
			b_addr_i => fr_m_addr,
			b_wdata_i => (others => '0'),
			b_gnt_o => fr_m_gnt,
			b_rvalid_o => fr_m_rvalid,
			m_req_o => art_req,
			m_we_o => art_we,
			m_addr_o => art_addr,
			m_wdata_o => art_wdata,
			m_gnt_i => m_gnt(MASTER_SPRITE),
			m_rvalid_i => m_rvalid(MASTER_SPRITE)
		);

	-- Master 3: UART debug port and replay unit (both byte-serial, may overlap)
	debug_mux: sram_port_mux
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			a_req_i => g_req,
			a_we_i => g_we,
			a_addr_i => g_addr,
			a_wdata_i => g_wdata,
			a_gnt_o => g_gnt,
			a_rvalid_o => g_rvalid,
			b_req_i => rp_req,
			b_we_i => rp_we,
			b_addr_i => rp_addr,
			b_wdata_i => rp_wdata,
			b_gnt_o => rp_gnt,
			b_rvalid_o => rp_rvalid,
			m_req_o => dbg_req,
			m_we_o => dbg_we,
			m_addr_o => dbg_addr,
			m_wdata_o => dbg_wdata,
			m_gnt_i => m_gnt(MASTER_LOADER),
			m_rvalid_i => m_rvalid(MASTER_LOADER)
		);

	-- Packed master buses, master 3 leftmost. The pixel FIFO only writes, at
	-- '0' & buf & (y * 320 + x); the display only reads.
	m_req <= dbg_req & fifo_valid & art_req & d_req;
	m_we <= dbg_we & '1' & art_we & '0';
	m_addr <= dbg_addr & ('0' & fifo_data(PIXW_BUF) & fifo_data(PIXW_ADDR_HI downto PIXW_ADDR_LO)) &
		art_addr & d_addr;
	m_wdata <= dbg_wdata & fifo_data(PIXW_DATA_HI downto PIXW_DATA_LO) & art_wdata & x"00";

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
	-- The game's tint (damage, pickup, toxic floor) unless the PC overrides it
	tint <= ctrl(13 downto 12) when (ctrl(13 downto 12) /= "00") else game_tint;

	display: display_controller
		port map (
			clk_sys_i => clk_sys,
			rst_sys_i => rst_sys,
			clk_pix_i => clk_pix,
			rst_pix_i => rst_pix,
			front_i => front,
			pattern_i => pattern,
			tint_i => tint,
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
	-- Boot and level loads
	------------------------------------------------------------------
	-- B_START pulses the art job; B_ART waits for it (a failed copy still
	-- runs the game, with garbage sprites, and lights the blue LED);
	-- B_RUN serves the game core's level requests. A request can come in
	-- any state (the core asks for level 1 right after reset, during the
	-- art copy), so it is latched in level_pending and started once the
	-- loader is free. The loader's done or error both release the game
	-- core, which then finishes the level reset on whatever the map holds.
	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			boot <= B_START;
			art_start <= '0';
			level_start <= '0';
			level_num <= "01";
			level_loading <= '0';
			level_pending <= '0';
			level_load_done <= '0';
			art_status <= "00";
			level_status <= "00";
		elsif rising_edge(clk_sys) then
			art_start <= '0';
			level_start <= '0';
			level_load_done <= '0';
			if (core_load_req = '1') then
				level_num <= core_load_level;
				level_pending <= '1';
			end if;
			case boot is
				when B_START =>
					if (BOOT_ART) then
						art_start <= '1';
						boot <= B_ART;
					else
						art_status <= "01";
						boot <= B_RUN;
					end if;
				when B_ART =>
					if (ld_done = '1') then
						art_status <= "01";
						boot <= B_RUN;
					elsif (ld_error = '1') then
						art_status <= "10";
						boot <= B_RUN;
					end if;
				when B_RUN =>
					if ((level_pending = '1') and (level_loading = '0') and (ld_busy = '0')) then
						level_start <= '1';
						level_loading <= '1';
						level_pending <= '0';
					elsif ((level_loading = '1') and ((ld_done = '1') or (ld_error = '1'))) then
						level_loading <= '0';
						level_load_done <= '1';
						if (ld_done = '1') then
							level_status <= "01";
						else
							level_status <= "10";
						end if;
					end if;
			end case;
		end if;
	end process;

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

	flash_share: flash_arbiter
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			c0_req_valid_i => au_req_valid,
			c0_req_ready_o => au_req_ready,
			c0_req_id_i => au_req_id,
			c0_req_addr_i => au_req_addr,
			c0_req_len_i => au_req_len,
			c0_data_valid_o => au_data_valid,
			c0_data_ready_i => au_data_ready,
			c0_data_o => au_data,
			c0_data_last_o => au_data_last,
			c1_req_valid_i => ld_req_valid,
			c1_req_ready_o => ld_req_ready,
			c1_req_id_i => ld_req_id,
			c1_req_addr_i => ld_req_addr,
			c1_req_len_i => ld_req_len,
			c1_data_valid_o => ld_data_valid,
			c1_data_ready_i => ld_data_ready,
			c1_data_o => ld_data,
			c1_data_last_o => ld_data_last,
			req_valid_o => f_req_valid,
			req_ready_i => f_req_ready,
			req_id_o => f_req_id,
			req_addr_o => f_req_addr,
			req_len_o => f_req_len,
			data_valid_i => f_data_valid,
			data_ready_o => f_data_ready,
			data_i => f_data,
			data_last_i => f_data_last
		);

	loader: asset_loader
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			art_start_i => art_start,
			level_start_i => level_start,
			level_i => level_num,
			req_valid_o => ld_req_valid,
			req_ready_i => ld_req_ready,
			req_id_o => ld_req_id,
			req_addr_o => ld_req_addr,
			req_len_o => ld_req_len,
			data_valid_i => ld_data_valid,
			data_ready_o => ld_data_ready,
			data_i => ld_data,
			data_last_i => ld_data_last,
			map_we_o => ld_map_we,
			map_addr_o => ld_map_addr,
			map_data_o => ld_map_data,
			act_we_o => ld_act_we,
			act_addr_o => ld_act_addr,
			act_data_o => ld_act_data,
			start_x_o => ld_x,
			start_y_o => ld_y,
			start_angle_o => ld_angle,
			m_req_o => ld_m_req,
			m_we_o => ld_m_we,
			m_addr_o => ld_m_addr,
			m_wdata_o => ld_m_wdata,
			m_gnt_i => ld_m_gnt,
			busy_o => ld_busy,
			done_o => ld_done,
			error_o => ld_error
		);

	------------------------------------------------------------------
	-- Tile map; port B goes to the loader, the game core or the renderer
	------------------------------------------------------------------
	map_b_we <= ld_map_we when (ld_busy = '1') else
		core_map_we when (core_busy = '1') else '0';
	map_b_addr <= ld_map_addr when (ld_busy = '1') else
		core_map_addr when (core_busy = '1') else
		fr_map_b_addr;
	map_b_wdata <= ld_map_data when (ld_busy = '1') else core_map_wdata;

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
	-- Frame control: game step, render, drain, done
	------------------------------------------------------------------
	freeze <= ctrl(16);

	-- A game frame starts at the buffer manager's start line. The buffer
	-- manager asks once and then waits for frame_done, so a request that
	-- comes while no frame may start (boot art copy, freeze) is kept in
	-- frame_owed and served as soon as frames may start again
	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			frame_owed <= '0';
			frame_open <= '0';
			draining <= '0';
			frame_done <= '0';
		elsif rising_edge(clk_sys) then
			if (frame_go = '1') then
				frame_owed <= '0';
			elsif (bm_frame_start = '1') then
				frame_owed <= '1';
			end if;
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
		((bm_frame_start = '1') or (frame_owed = '1'))) else '0';

	core: game_core
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			load_req_o => core_load_req,
			load_level_o => core_load_level,
			load_done_i => level_load_done,
			start_x_i => ld_x,
			start_y_i => ld_y,
			start_angle_i => ld_angle,
			act_we_i => ld_act_we,
			act_addr_i => ld_act_addr,
			act_data_i => ld_act_data,
			frame_start_i => frame_go,
			snapshot_i => play_snapshot,
			snapshot_valid_i => play_snapshot_valid,
			map_addr_o => core_map_addr,
			map_we_o => core_map_we,
			map_wdata_o => core_map_wdata,
			map_data_i => map_b_data,
			span_addr_o => core_span_addr,
			span_data_i => span_data,
			span_count_i => span_count,
			zwall_addr_o => core_zwall_addr,
			zwall_data_i => zwall_data,
			cam_x_o => cam_x,
			cam_y_o => cam_y,
			angle_o => angle,
			eye_o => eye,
			doors_o => doors,
			player_x_o => player_x,
			player_y_o => player_y,
			hud_o => hud,
			keypos_o => keypos,
			music_o => music,
			tint_o => game_tint,
			fx_o => fx,
			spr_addr_i => spr_addr,
			spr_data_o => spr_data,
			spr_count_o => spr_count,
			render_start_o => render_start,
			busy_o => core_busy,
			snd_valid_o => snd_valid,
			snd_ready_i => snd_ready,
			snd_data_o => snd_data,
			level_loaded_o => level_loaded,
			state_addr_i => ctrl(4 * 32 + 6 downto 4 * 32),
			state_data_o => state_data,
			crc_o => crc
		);

	-- F1 overlay counters (model labels RENDER, SRAM, LATE, SPRITES)
	debug_values <= std_logic_vector(resize(unsigned(span_count), 24)) &
		x"00" & late_count & busy_last & render_cycles;

	renderer: frame_renderer
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			start_i => render_start,
			cam_x_i => cam_x,
			cam_y_i => cam_y,
			angle_i => angle,
			eye_i => eye,
			doors_i => doors,
			fx_i => fx,
			player_x_i => player_x,
			player_y_i => player_y,
			hud_i => hud,
			keypos_i => keypos,
			debug_i => debug_values,
			buf_i => back,
			spr_addr_o => spr_addr,
			spr_data_i => spr_data,
			spr_count_i => spr_count,
			gz_addr_i => core_zwall_addr,
			gz_data_o => zwall_data,
			span_raddr_i => core_span_addr,
			span_rdata_o => span_data,
			span_count_o => span_count,
			seen_clear_i => level_loaded,
			map_a_addr_o => map_a_addr,
			map_a_data_i => map_a_data,
			map_b_addr_o => fr_map_b_addr,
			map_b_data_i => map_b_data,
			m_req_o => fr_m_req,
			m_addr_o => fr_m_addr,
			m_gnt_i => fr_m_gnt,
			m_rvalid_i => fr_m_rvalid,
			m_rdata_i => m_rdata,
			pix_valid_o => pix_valid,
			pix_ready_i => pix_ready,
			pix_data_o => pix_data,
			busy_o => render_busy,
			done_o => render_done,
			cycles_o => render_cycles,
			sprite_pixels_o => sprite_pixels
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
	-- PS/2 keyboard and mouse, replay
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

	-- Between the keyboard and the game: pass, record, or play back
	replay: replay_unit
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			mode_i => ctrl(3 * 32 + 1 downto 3 * 32),
			frames_o => replay_frames,
			snap_in_i => snapshot,
			snap_in_valid_i => snapshot_valid,
			snap_out_o => play_snapshot,
			snap_out_valid_o => play_snapshot_valid,
			crc_i => crc,
			crc_valid_i => render_start,
			m_req_o => rp_req,
			m_we_o => rp_we,
			m_addr_o => rp_addr,
			m_wdata_o => rp_wdata,
			m_gnt_i => rp_gnt,
			m_rvalid_i => rp_rvalid,
			m_rdata_i => m_rdata
		);

	-- The snapshot the game actually used (after the replay unit)
	process(clk_sys, rst_sys)
	begin
		if (rst_sys = '1') then
			snapshot_held <= (others => '0');
		elsif rising_edge(clk_sys) then
			if (play_snapshot_valid = '1') then
				snapshot_held <= play_snapshot;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Audio: mixer (sound effects, music) or the test tone, to I2S
	------------------------------------------------------------------
	audio_on <= '1' when ((boot = B_RUN) and (ctrl(17) = '0')) else '0';

	mixer: audio_mixer
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			enable_i => audio_on,
			snd_valid_i => snd_valid,
			snd_ready_o => snd_ready,
			snd_data_i => snd_data,
			music_i => music,
			master_i => ctrl(2 * 32 + 5 downto 2 * 32),
			sample_req_i => sample_req,
			left_o => mix_left,
			right_o => mix_right,
			req_valid_o => au_req_valid,
			req_ready_i => au_req_ready,
			req_id_o => au_req_id,
			req_addr_o => au_req_addr,
			req_len_o => au_req_len,
			data_valid_i => au_data_valid,
			data_ready_o => au_data_ready,
			data_i => au_data,
			data_last_i => au_data_last,
			underflows_o => underflows
		);

	tone_440: tone_gen
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			enable_i => ctrl(0),
			step_i => sample_req,
			sample_o => tone
		);

	out_left <= tone when (ctrl(0) = '1') else mix_left;
	out_right <= tone when (ctrl(0) = '1') else mix_right;

	i2s: i2s_tx
		port map (
			clk_i => clk_sys,
			rst_i => rst_sys,
			left_i => out_left,
			right_i => out_right,
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
			m_gnt_i => g_gnt,
			m_rvalid_i => g_rvalid,
			m_rdata_i => m_rdata,
			rx_count_o => rx_count,
			tx_count_o => tx_count
		);

	-- Status words (UART register n = word n); 0..24 keep their stage-1
	-- meaning, with the camera in words 1..3 (the frame capture renders
	-- from it)
	values(0 * 32 + 31 downto 0 * 32) <= BUILD_ID;
	values(1 * 32 + 31 downto 1 * 32) <= "0000000000" & cam_x; -- Camera x, Q6.16
	values(2 * 32 + 31 downto 2 * 32) <= "0000000000" & cam_y; -- Camera y, Q6.16
	values(3 * 32 + 31 downto 3 * 32) <= x"00" & '0' & eye & "000000" & angle; -- Eye 22:16, angle 9:0
	values(4 * 32 + 31 downto 4 * 32) <= x"00" & render_cycles; -- Last frame render clocks
	values(5 * 32 + 31 downto 5 * 32) <= frame_count & late_count;
	values(6 * 32 + 31 downto 6 * 32) <= x"00" & busy_last; -- SRAM busy clocks last frame
	-- 7: 1:0 art copy, 5:4 last level load (01 ok, 10 failed), 9:8 its level
	values(7 * 32 + 31 downto 7 * 32) <= x"00000" & "00" & level_num & "00" & level_status &
		"00" & art_status;
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
	door_words: for k in 0 to 7 generate
		values((17 + k) * 32 + 31 downto (17 + k) * 32) <=
			"0000000000000" & doors(k * DOOR_BITS + DOOR_BITS - 1 downto k * DOOR_BITS);
	end generate;
	values(25 * 32 + 31 downto 25 * 32) <= crc; -- game.state_crc() of the last frame
	values(26 * 32 + 31 downto 26 * 32) <= state_data(31 downto 0); -- State word (ctrl 36)
	values(27 * 32 + 31 downto 27 * 32) <= state_data(63 downto 32);
	values(28 * 32 + 31 downto 28 * 32) <= hud(31 downto 0);
	values(29 * 32 + 31 downto 29 * 32) <= hud(63 downto 32);
	values(30 * 32 + 31 downto 30 * 32) <= hud(95 downto 64); -- 100:96 spare
	values(31 * 32 + 31 downto 31 * 32) <= underflows & replay_frames;

	------------------------------------------------------------------
	-- LEDs (RGB at 1/32 duty): red = PS/2 errors or audio underflows,
	-- green = heartbeat, blue = art copy or level load failed
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
	led_r <= '1' when ((unsigned(kb_errors) /= 0) or (unsigned(ms_errors) /= 0) or
		(unsigned(underflows) /= 0)) else '0';
	led_g <= frame_count(5); -- Toggles every 32 frames: about 1 Hz
	led_b <= art_status(1) or level_status(1);
	led0_r <= not (led_r and pwm_on);
	led0_g <= not (led_g and pwm_on);
	led0_b <= not (led_b and pwm_on);
	led(0) <= locked;
	led(1) <= pcb_on;
end arch;

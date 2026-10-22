--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Display Controller
-- Module Name:    display_controller
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Shows the 320x240 front framebuffer (SRAM) on 640x480
--                 VGA, each game pixel as a 2x2 block. Blocks:
--                   vga_timing, display_pixel   pixel domain
--                   line_fetcher                system domain
--                   line_buffer, palette_ram    written in system, read
--                                               in pixel domain
--                 This is the design's only clock-domain crossing (the
--                 XDC declares clk_sys and clk_pix asynchronous).
--                 Everything that crosses:
--                 1. Pixel to system, single-cycle events through
--                    pulse_sync (toggle + 3-stage synchronizer):
--                    - next line: at h = 0 of scanline 2r (r = 0..238),
--                      when line r starts showing, fetch line r + 1
--                    - first line: at h = 0 of scanline 523 (2 lines
--                      before the frame), fetch line 0
--                    - vblank: at h = 0 of scanline 480 (frame swap point)
--                    Line numbers are counted on the system side, so no
--                    multi-bit value crosses this way.
--                 2. Line buffer and palette RAMs (dual clock): the
--                    fetcher writes only the half not being shown;
--                    palette writes are accepted (pal_ready_o) only
--                    between the vblank and first-line events.
--                 3. System to pixel, quasi-static settings (pattern,
--                    tint, blank), registered in the system domain, then
--                    through 3-stage synchronizers, then
--                    latched at the start of vertical blanking so they
--                    change only between frames; pcb_on goes through a
--                    synchronizer straight to the output enables.
--                 Clock domains: clk_sys_i (100 MHz), clk_pix_i (25 MHz),
--                 declared asynchronous in the XDC.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, game_pkg,
--                 hw_pkg, vga_timing, display_pixel, line_fetcher,
--                 line_buffer, palette_ram, pulse_sync, synchronizer
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
use work.hw_pkg.all;
use work.game_pkg.all;

entity display_controller is
	generic(
		OUT_BITS: positive := 4 -- Bits per channel at the DAC (4 or 6)
	);
	port(
		clk_sys_i: in std_logic; -- System clock
		rst_sys_i: in std_logic; -- System-domain reset
		clk_pix_i: in std_logic; -- Pixel clock
		rst_pix_i: in std_logic; -- Pixel-domain reset
		-- Settings (system domain)
		front_i: in std_logic; -- Front buffer (from the buffer manager)
		pattern_i: in std_logic_vector(2 downto 0); -- Test pattern (game_pkg)
		tint_i: in std_logic_vector(1 downto 0); -- Screen tint (game_pkg)
		blank_i: in std_logic; -- Black screen
		pcb_on_i: in std_logic; -- PWR_SENSE gate: drive the VGA pins
		-- Palette write port (system domain, valid/ready)
		pal_valid_i: in std_logic;
		pal_ready_o: out std_logic; -- High only during vertical blanking
		pal_addr_i: in std_logic_vector(7 downto 0);
		pal_data_i: in std_logic_vector(17 downto 0); -- RGB666
		-- SRAM arbiter master 0 (system domain)
		m_req_o: out std_logic;
		m_addr_o: out std_logic_vector(18 downto 0);
		m_gnt_i: in std_logic;
		m_rvalid_i: in std_logic;
		m_rdata_i: in std_logic_vector(7 downto 0);
		-- Events (system domain)
		vblank_o: out std_logic; -- Pulse at the start of vertical blanking
		line_start_o: out std_logic; -- Pulse when a line fetch starts
		line_o: out std_logic_vector(7 downto 0); -- Line being fetched
		overrun_o: out std_logic; -- Pulse: a line fetch missed its deadline
		-- VGA pins (pixel domain, IOB registers)
		vga_r_o: out std_logic_vector(OUT_BITS - 1 downto 0);
		vga_g_o: out std_logic_vector(OUT_BITS - 1 downto 0);
		vga_b_o: out std_logic_vector(OUT_BITS - 1 downto 0);
		vga_hs_o: out std_logic;
		vga_vs_o: out std_logic;
		vga_t_o: out std_logic_vector(3 * OUT_BITS + 1 downto 0) -- '1' = high-Z
	);
end display_controller;

architecture arch of display_controller is
	component vga_timing is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			h_o: out std_logic_vector(9 downto 0);
			v_o: out std_logic_vector(9 downto 0);
			hsync_o: out std_logic;
			vsync_o: out std_logic;
			active_o: out std_logic
		);
	end component;
	component display_pixel is
		generic(
			OUT_BITS: positive := 4
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			h_i: in std_logic_vector(9 downto 0);
			v_i: in std_logic_vector(9 downto 0);
			hsync_i: in std_logic;
			vsync_i: in std_logic;
			active_i: in std_logic;
			pattern_i: in std_logic_vector(2 downto 0);
			tint_i: in std_logic_vector(1 downto 0);
			blank_i: in std_logic;
			out_en_i: in std_logic;
			lb_addr_o: out std_logic_vector(9 downto 0);
			lb_data_i: in std_logic_vector(7 downto 0);
			pal_addr_o: out std_logic_vector(7 downto 0);
			pal_data_i: in std_logic_vector(17 downto 0);
			vga_r_o: out std_logic_vector(OUT_BITS - 1 downto 0);
			vga_g_o: out std_logic_vector(OUT_BITS - 1 downto 0);
			vga_b_o: out std_logic_vector(OUT_BITS - 1 downto 0);
			vga_hs_o: out std_logic;
			vga_vs_o: out std_logic;
			vga_t_o: out std_logic_vector(3 * OUT_BITS + 1 downto 0)
		);
	end component;
	component line_fetcher is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			first_i: in std_logic;
			next_i: in std_logic;
			front_i: in std_logic;
			m_req_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0);
			lb_we_o: out std_logic;
			lb_addr_o: out std_logic_vector(9 downto 0);
			lb_data_o: out std_logic_vector(7 downto 0);
			line_start_o: out std_logic;
			line_o: out std_logic_vector(7 downto 0);
			overrun_o: out std_logic
		);
	end component;
	component line_buffer is
		port(
			wr_clk_i: in std_logic;
			wr_en_i: in std_logic;
			wr_addr_i: in std_logic_vector(9 downto 0);
			wr_data_i: in std_logic_vector(7 downto 0);
			rd_clk_i: in std_logic;
			rd_addr_i: in std_logic_vector(9 downto 0);
			rd_data_o: out std_logic_vector(7 downto 0)
		);
	end component;
	component palette_ram is
		port(
			wr_clk_i: in std_logic;
			wr_en_i: in std_logic;
			wr_addr_i: in std_logic_vector(7 downto 0);
			wr_data_i: in std_logic_vector(17 downto 0);
			rd_clk_i: in std_logic;
			rd_addr_i: in std_logic_vector(7 downto 0);
			rd_data_o: out std_logic_vector(17 downto 0)
		);
	end component;
	component pulse_sync is
		port(
			clk_a_i: in std_logic;
			rst_a_i: in std_logic;
			pulse_i: in std_logic;
			clk_b_i: in std_logic;
			rst_b_i: in std_logic;
			pulse_o: out std_logic
		);
	end component;
	component synchronizer is
		generic(
			STAGES: positive := 3;
			INIT: std_logic := '0'
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			async_i: in std_logic;
			sync_o: out std_logic
		);
	end component;

	-- Pixel domain
	signal h, v: std_logic_vector(9 downto 0);
	signal hsync, vsync, active: std_logic;
	signal ev_next_pix: std_logic := '0';
	signal ev_first_pix: std_logic := '0';
	signal ev_vblank_pix: std_logic := '0';
	-- Settings bits: 5:3 pattern, 2:1 tint, 0 blank. settings_sys is a
	-- system-domain register so each synchronizer starts from a flip-flop
	-- (logic in front of a synchronizer could glitch while it samples)
	signal settings_in: std_logic_vector(5 downto 0);
	signal settings_sys: std_logic_vector(5 downto 0) := (others => '0');
	signal settings_sync: std_logic_vector(5 downto 0);
	signal settings_pix: std_logic_vector(5 downto 0) := (others => '0');
	signal pcb_on_pix: std_logic;
	signal lb_rd_addr: std_logic_vector(9 downto 0);
	signal lb_rd_data: std_logic_vector(7 downto 0);
	signal pal_rd_addr: std_logic_vector(7 downto 0);
	signal pal_rd_data: std_logic_vector(17 downto 0);

	-- System domain
	signal ev_next_sys: std_logic;
	signal ev_first_sys: std_logic;
	signal ev_vblank_sys: std_logic;
	signal in_vblank: std_logic := '0';
	signal pal_wr_en: std_logic; -- Palette writes only during vertical blanking
	signal lb_we: std_logic;
	signal lb_wr_addr: std_logic_vector(9 downto 0);
	signal lb_wr_data: std_logic_vector(7 downto 0);
begin
	------------------------------------------------------------------
	-- Pixel domain: raster, events, settings, color path
	------------------------------------------------------------------
	timing: vga_timing
		port map (
			clk_i => clk_pix_i,
			rst_i => rst_pix_i,
			h_o => h,
			v_o => v,
			hsync_o => hsync,
			vsync_o => vsync,
			active_o => active
		);

	-- Registered event pulses at h = 0 of the chosen scanlines
	process(clk_pix_i, rst_pix_i)
		variable vn: natural range 0 to 1023;
	begin
		if (rst_pix_i = '1') then
			ev_next_pix <= '0';
			ev_first_pix <= '0';
			ev_vblank_pix <= '0';
		elsif rising_edge(clk_pix_i) then
			vn := to_integer(unsigned(v));
			ev_next_pix <= '0';
			ev_first_pix <= '0';
			ev_vblank_pix <= '0';
			if (unsigned(h) = 0) then
				-- Scanline 2r (r = 0 .. RENDER_H - 2): fetch line r + 1 while line r shows
				if ((v(0) = '0') and (vn <= 2 * (RENDER_H - 2))) then
					ev_next_pix <= '1';
				end if;
				if (vn = V_TOTAL - 2) then -- Two scanlines before the frame: fetch line 0
					ev_first_pix <= '1';
				end if;
				if (vn = V_VISIBLE) then -- First scanline of vertical blanking
					ev_vblank_pix <= '1';
				end if;
			end if;
		end if;
	end process;

	-- Settings: synchronize each bit, then take them only at vblank
	settings_in <= pattern_i & tint_i & blank_i;

	process(clk_sys_i, rst_sys_i)
	begin
		if (rst_sys_i = '1') then
			settings_sys <= (others => '0');
		elsif rising_edge(clk_sys_i) then
			settings_sys <= settings_in;
		end if;
	end process;

	sync_settings: for i in 0 to 5 generate
		sync_bit: synchronizer
			port map (
				clk_i => clk_pix_i,
				rst_i => rst_pix_i,
				async_i => settings_sys(i),
				sync_o => settings_sync(i)
			);
	end generate;

	process(clk_pix_i, rst_pix_i)
	begin
		if (rst_pix_i = '1') then
			settings_pix <= (others => '0');
		elsif rising_edge(clk_pix_i) then
			if (ev_vblank_pix = '1') then
				settings_pix <= settings_sync;
			end if;
		end if;
	end process;

	sync_pcb_on: synchronizer
		port map (
			clk_i => clk_pix_i,
			rst_i => rst_pix_i,
			async_i => pcb_on_i,
			sync_o => pcb_on_pix
		);

	pixel: display_pixel
		generic map (
			OUT_BITS => OUT_BITS
		)
		port map (
			clk_i => clk_pix_i,
			rst_i => rst_pix_i,
			h_i => h,
			v_i => v,
			hsync_i => hsync,
			vsync_i => vsync,
			active_i => active,
			pattern_i => settings_pix(5 downto 3),
			tint_i => settings_pix(2 downto 1),
			blank_i => settings_pix(0),
			out_en_i => pcb_on_pix,
			lb_addr_o => lb_rd_addr,
			lb_data_i => lb_rd_data,
			pal_addr_o => pal_rd_addr,
			pal_data_i => pal_rd_data,
			vga_r_o => vga_r_o,
			vga_g_o => vga_g_o,
			vga_b_o => vga_b_o,
			vga_hs_o => vga_hs_o,
			vga_vs_o => vga_vs_o,
			vga_t_o => vga_t_o
		);

	------------------------------------------------------------------
	-- Crossing RAMs
	------------------------------------------------------------------
	lbuf: line_buffer
		port map (
			wr_clk_i => clk_sys_i,
			wr_en_i => lb_we,
			wr_addr_i => lb_wr_addr,
			wr_data_i => lb_wr_data,
			rd_clk_i => clk_pix_i,
			rd_addr_i => lb_rd_addr,
			rd_data_o => lb_rd_data
		);

	pal_wr_en <= pal_valid_i and in_vblank;

	pal: palette_ram
		port map (
			wr_clk_i => clk_sys_i,
			wr_en_i => pal_wr_en,
			wr_addr_i => pal_addr_i,
			wr_data_i => pal_data_i,
			rd_clk_i => clk_pix_i,
			rd_addr_i => pal_rd_addr,
			rd_data_o => pal_rd_data
		);

	------------------------------------------------------------------
	-- Events into the system domain
	------------------------------------------------------------------
	psync_next: pulse_sync
		port map (
			clk_a_i => clk_pix_i,
			rst_a_i => rst_pix_i,
			pulse_i => ev_next_pix,
			clk_b_i => clk_sys_i,
			rst_b_i => rst_sys_i,
			pulse_o => ev_next_sys
		);

	psync_first: pulse_sync
		port map (
			clk_a_i => clk_pix_i,
			rst_a_i => rst_pix_i,
			pulse_i => ev_first_pix,
			clk_b_i => clk_sys_i,
			rst_b_i => rst_sys_i,
			pulse_o => ev_first_sys
		);

	psync_vblank: pulse_sync
		port map (
			clk_a_i => clk_pix_i,
			rst_a_i => rst_pix_i,
			pulse_i => ev_vblank_pix,
			clk_b_i => clk_sys_i,
			rst_b_i => rst_sys_i,
			pulse_o => ev_vblank_sys
		);

	------------------------------------------------------------------
	-- System domain: palette write window and the line fetcher
	------------------------------------------------------------------
	process(clk_sys_i, rst_sys_i)
	begin
		if (rst_sys_i = '1') then
			in_vblank <= '0';
		elsif rising_edge(clk_sys_i) then
			if (ev_vblank_sys = '1') then
				in_vblank <= '1';
			elsif (ev_first_sys = '1') then
				in_vblank <= '0'; -- Window closes before line 0 reaches the palette
			end if;
		end if;
	end process;

	pal_ready_o <= in_vblank;

	fetch: line_fetcher
		port map (
			clk_i => clk_sys_i,
			rst_i => rst_sys_i,
			first_i => ev_first_sys,
			next_i => ev_next_sys,
			front_i => front_i,
			m_req_o => m_req_o,
			m_addr_o => m_addr_o,
			m_gnt_i => m_gnt_i,
			m_rvalid_i => m_rvalid_i,
			m_rdata_i => m_rdata_i,
			lb_we_o => lb_we,
			lb_addr_o => lb_wr_addr,
			lb_data_o => lb_wr_data,
			line_start_o => line_start_o,
			line_o => line_o,
			overrun_o => overrun_o
		);

	vblank_o <= ev_vblank_sys;
end arch;

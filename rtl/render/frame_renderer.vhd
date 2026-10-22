--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Frame Renderer
-- Module Name:    frame_renderer
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    The stage-2 renderer: one frame into the back buffer, in
--                 the order of tools/model/frame.py:
--                   1. walls, floors, ceilings (render_top: ray engine +
--                      column rasterizer); the z-buffer and the minimap
--                      seen bits are written on the way
--                   2. sprites, far to near (sprite_engine)
--                   3. 2D overlay (overlay)
--                 On the text screens (title, briefing, score, ending)
--                 only the overlay runs; it fills the whole screen.
--                 Shared resources, one user at a time by phase:
--                   - pixel write port: walls, then sprites, then overlay
--                   - SRAM art reads (master 1): sprites, then overlay
--                   - tile map port B: floor casting (walls), then the
--                     minimap (overlay)
--                   - z-buffer read port: the sprite engine during the
--                     sprite phase, the game core (hitscan, last frame's
--                     walls) while the renderer is idle
--                 Seen bits: 4096 x 1 RAM written by the ray engine, read
--                 by the overlay, cleared on seen_clear_i (4,096 clocks;
--                 start_i waits for the clear to finish).
--                 Stage 4: render_top keeps each column's clip list (the
--                 open row window after every height edge); the sprite
--                 engine is its only reader (sprite phase), so its clip
--                 ports connect straight through.
--                 Frame inputs (camera, door table, HUD, buf) must be
--                 stable from start_i until done_o.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std,
--                 render_types_pkg, game_pkg, render_top, sprite_engine,
--                 overlay
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.20 - Stage 4: clip lists to the sprite engine; effects register
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.game_pkg.all;
use work.render_types_pkg.all;

entity frame_renderer is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		start_i: in std_logic; -- Pulse: render one frame
		cam_x_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Camera (with peek), Q6.16
		cam_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
		angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
		eye_i: in std_logic_vector(EYE_BITS - 1 downto 0);
		doors_i: in std_logic_vector(DOORS_BITS - 1 downto 0);
		fx_i: in std_logic_vector(FX_BITS - 1 downto 0); -- Light offsets, animation frame
		player_x_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Player, for the maps
		player_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
		hud_i: in std_logic_vector(HUD_BITS - 1 downto 0);
		keypos_i: in std_logic_vector(KEYPOS_BITS - 1 downto 0);
		debug_i: in std_logic_vector(4 * 24 - 1 downto 0); -- F1 overlay counters
		buf_i: in std_logic; -- Framebuffer to draw
		-- Sprite table (game core), 1-clock read
		spr_addr_o: out std_logic_vector(4 downto 0);
		spr_data_i: in std_logic_vector(SPR_BITS - 1 downto 0);
		spr_count_i: in std_logic_vector(5 downto 0);
		-- Hitscan inputs for the game core (last frame), 1-clock reads
		gz_addr_i: in std_logic_vector(8 downto 0);
		gz_data_o: out std_logic_vector(15 downto 0);
		span_raddr_i: in std_logic_vector(4 downto 0);
		span_rdata_o: out std_logic_vector(SPAN_BITS - 1 downto 0);
		span_count_o: out std_logic_vector(5 downto 0);
		seen_clear_i: in std_logic; -- Pulse: a level was loaded
		-- Tile map: port A (ray engine) and port B while rendering
		map_a_addr_o: out std_logic_vector(11 downto 0);
		map_a_data_i: in std_logic_vector(23 downto 0);
		map_b_addr_o: out std_logic_vector(11 downto 0);
		map_b_data_i: in std_logic_vector(23 downto 0);
		-- SRAM art reads (arbiter master 1)
		m_req_o: out std_logic;
		m_addr_o: out std_logic_vector(18 downto 0);
		m_gnt_i: in std_logic;
		m_rvalid_i: in std_logic;
		m_rdata_i: in std_logic_vector(7 downto 0);
		-- Pixel write port
		pix_valid_o: out std_logic;
		pix_ready_i: in std_logic;
		pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
		busy_o: out std_logic; -- Frame in progress
		done_o: out std_logic; -- Pulse: every pixel handed to the pixel port
		cycles_o: out std_logic_vector(23 downto 0); -- Clocks the last frame took
		sprite_pixels_o: out std_logic_vector(15 downto 0) -- Sprite pixels last frame
	);
end frame_renderer;

architecture arch of frame_renderer is
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
	component sprite_engine is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			cam_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			cam_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			eye_i: in std_logic_vector(EYE_BITS - 1 downto 0);
			buf_i: in std_logic;
			spr_addr_o: out std_logic_vector(4 downto 0);
			spr_data_i: in std_logic_vector(SPR_BITS - 1 downto 0);
			spr_count_i: in std_logic_vector(5 downto 0);
			zwall_addr_o: out std_logic_vector(8 downto 0);
			zwall_data_i: in std_logic_vector(15 downto 0);
			m_req_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0);
			pix_valid_o: out std_logic;
			pix_ready_i: in std_logic;
			pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
			span_raddr_i: in std_logic_vector(4 downto 0);
			span_rdata_o: out std_logic_vector(SPAN_BITS - 1 downto 0);
			span_count_o: out std_logic_vector(5 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic;
			pixels_o: out std_logic_vector(15 downto 0);
			clip_addr_o: out std_logic_vector(12 downto 0);
			clip_data_i: in std_logic_vector(CLIP_BITS - 1 downto 0);
			ccount_addr_o: out std_logic_vector(8 downto 0);
			ccount_data_i: in std_logic_vector(4 downto 0)
		);
	end component;
	component overlay is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			buf_i: in std_logic;
			hud_i: in std_logic_vector(HUD_BITS - 1 downto 0);
			player_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			player_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			keypos_i: in std_logic_vector(KEYPOS_BITS - 1 downto 0);
			debug_i: in std_logic_vector(4 * 24 - 1 downto 0);
			map_addr_o: out std_logic_vector(11 downto 0);
			map_data_i: in std_logic_vector(23 downto 0);
			seen_addr_o: out std_logic_vector(11 downto 0);
			seen_data_i: in std_logic;
			m_req_o: out std_logic;
			m_addr_o: out std_logic_vector(18 downto 0);
			m_gnt_i: in std_logic;
			m_rvalid_i: in std_logic;
			m_rdata_i: in std_logic_vector(7 downto 0);
			pix_valid_o: out std_logic;
			pix_ready_i: in std_logic;
			pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic
		);
	end component;

	-- Phases of one frame
	type phase_t is (P_IDLE, P_CLEAR, P_WALLS, P_SPRITES, P_OVERLAY);
	signal phase: phase_t := P_IDLE;
	signal pending: std_logic := '0'; -- start_i arrived during a clear
	signal clear_addr: unsigned(11 downto 0) := (others => '0');
	signal walls_start, sprites_start, overlay_start: std_logic := '0';
	signal walls_done, sprites_done, overlay_done: std_logic;
	signal done: std_logic := '0';
	signal count: unsigned(23 downto 0) := (others => '0');
	signal cycles: unsigned(23 downto 0) := (others => '0');
	signal text_screen: std_logic;

	-- Engine ports
	signal w_pix_valid, s_pix_valid, o_pix_valid: std_logic;
	signal w_pix_data, s_pix_data, o_pix_data: std_logic_vector(PIXW_BITS - 1 downto 0);
	signal w_map_b_addr, o_map_addr: std_logic_vector(11 downto 0);
	signal s_req, o_req: std_logic;
	signal s_addr, o_addr: std_logic_vector(18 downto 0);
	signal s_zaddr: std_logic_vector(8 downto 0);
	signal zaddr: std_logic_vector(8 downto 0);
	signal zdata: std_logic_vector(15 downto 0);
	signal seen_we: std_logic;
	signal clip_addr: std_logic_vector(12 downto 0);
	signal clip_data: std_logic_vector(CLIP_BITS - 1 downto 0);
	signal ccount_addr: std_logic_vector(8 downto 0);
	signal ccount_data: std_logic_vector(4 downto 0);
	signal seen_waddr, o_seen_addr: std_logic_vector(11 downto 0);
	signal seen_rdata: std_logic := '0';
	type seen_t is array (0 to 4095) of std_logic;
	signal seen: seen_t := (others => '0');
begin
	-- Text screens (flow 0 title, 1 briefing, 5 score, 6 ending) skip the 3D view
	process(hud_i)
		variable f: natural range 0 to 7;
	begin
		f := to_integer(unsigned(hud_i(HUD_FLOW_HI downto HUD_FLOW_LO)));
		if ((f = 0) or (f = 1) or (f = 5) or (f = 6)) then
			text_screen <= '1';
		else
			text_screen <= '0';
		end if;
	end process;

	------------------------------------------------------------------
	-- Phase sequencer
	------------------------------------------------------------------
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			phase <= P_IDLE;
			pending <= '0';
			clear_addr <= (others => '0');
			walls_start <= '0';
			sprites_start <= '0';
			overlay_start <= '0';
			done <= '0';
			count <= (others => '0');
			cycles <= (others => '0');
		elsif rising_edge(clk_i) then
			walls_start <= '0';
			sprites_start <= '0';
			overlay_start <= '0';
			done <= '0';
			-- Frame time counter: runs only while drawing, saturates at 2^24 - 1
			if (phase /= P_IDLE) and (phase /= P_CLEAR) and (count /= x"FFFFFF") then
				count <= count + 1;
			end if;
			case phase is
				when P_IDLE =>
					if (seen_clear_i = '1') then
						clear_addr <= (others => '0');
						pending <= start_i;
						phase <= P_CLEAR;
					elsif (start_i = '1') then
						count <= (others => '0');
						if (text_screen = '1') then
							overlay_start <= '1';
							phase <= P_OVERLAY;
						else
							walls_start <= '1';
							phase <= P_WALLS;
						end if;
					end if;
				when P_CLEAR =>
					-- One seen bit per clock, 4096 clocks; a start meanwhile is remembered
					if (start_i = '1') then
						pending <= '1';
					end if;
					clear_addr <= clear_addr + 1;
					if (clear_addr = 4095) then
						phase <= P_IDLE;
						if ((pending = '1') or (start_i = '1')) then
							-- Start the frame that arrived during the clear
							count <= (others => '0');
							pending <= '0';
							if (text_screen = '1') then
								overlay_start <= '1';
								phase <= P_OVERLAY;
							else
								walls_start <= '1';
								phase <= P_WALLS;
							end if;
						end if;
					end if;
				when P_WALLS =>
					if (walls_done = '1') then
						sprites_start <= '1';
						phase <= P_SPRITES;
					end if;
				when P_SPRITES =>
					if (sprites_done = '1') then
						overlay_start <= '1';
						phase <= P_OVERLAY;
					end if;
				when P_OVERLAY =>
					if (overlay_done = '1') then
						done <= '1';
						cycles <= count + 1; -- + 1 includes this last clock
						phase <= P_IDLE;
					end if;
			end case;
		end if;
	end process;

	------------------------------------------------------------------
	-- Engines
	------------------------------------------------------------------
	walls: render_top
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			start_i => walls_start,
			pos_x_i => cam_x_i,
			pos_y_i => cam_y_i,
			angle_i => angle_i,
			eye_i => eye_i,
			doors_i => doors_i,
			fx_i => fx_i,
			buf_i => buf_i,
			map_a_addr_o => map_a_addr_o,
			map_a_data_i => map_a_data_i,
			map_b_addr_o => w_map_b_addr,
			map_b_data_i => map_b_data_i,
			pix_valid_o => w_pix_valid,
			pix_ready_i => pix_ready_i,
			pix_data_o => w_pix_data,
			zbuf_addr_i => zaddr,
			zbuf_data_o => zdata,
			seen_we_o => seen_we,
			seen_addr_o => seen_waddr,
			clip_raddr_i => clip_addr,
			clip_rdata_o => clip_data,
			ccount_raddr_i => ccount_addr,
			ccount_rdata_o => ccount_data,
			busy_o => open,
			done_o => walls_done,
			cycles_o => open
		);

	sprites: sprite_engine
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			start_i => sprites_start,
			cam_x_i => cam_x_i,
			cam_y_i => cam_y_i,
			angle_i => angle_i,
			eye_i => eye_i,
			buf_i => buf_i,
			spr_addr_o => spr_addr_o,
			spr_data_i => spr_data_i,
			spr_count_i => spr_count_i,
			zwall_addr_o => s_zaddr,
			zwall_data_i => zdata,
			m_req_o => s_req,
			m_addr_o => s_addr,
			m_gnt_i => m_gnt_i,
			m_rvalid_i => m_rvalid_i,
			m_rdata_i => m_rdata_i,
			pix_valid_o => s_pix_valid,
			pix_ready_i => pix_ready_i,
			pix_data_o => s_pix_data,
			span_raddr_i => span_raddr_i,
			span_rdata_o => span_rdata_o,
			span_count_o => span_count_o,
			busy_o => open,
			done_o => sprites_done,
			pixels_o => sprite_pixels_o,
			clip_addr_o => clip_addr,
			clip_data_i => clip_data,
			ccount_addr_o => ccount_addr,
			ccount_data_i => ccount_data
		);

	hud: overlay
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			start_i => overlay_start,
			buf_i => buf_i,
			hud_i => hud_i,
			player_x_i => player_x_i,
			player_y_i => player_y_i,
			angle_i => angle_i,
			keypos_i => keypos_i,
			debug_i => debug_i,
			map_addr_o => o_map_addr,
			map_data_i => map_b_data_i,
			seen_addr_o => o_seen_addr,
			seen_data_i => seen_rdata,
			m_req_o => o_req,
			m_addr_o => o_addr,
			m_gnt_i => m_gnt_i,
			m_rvalid_i => m_rvalid_i,
			m_rdata_i => m_rdata_i,
			pix_valid_o => o_pix_valid,
			pix_ready_i => pix_ready_i,
			pix_data_o => o_pix_data,
			busy_o => open,
			done_o => overlay_done
		);

	------------------------------------------------------------------
	-- Shared ports by phase. Ready goes to every engine; only the
	-- engine of the current phase drives valid, so only it sees a
	-- transfer. Read data (SRAM, map) is shared the same way.
	------------------------------------------------------------------
	pix_valid_o <= w_pix_valid when (phase = P_WALLS) else
		s_pix_valid when (phase = P_SPRITES) else
		o_pix_valid when (phase = P_OVERLAY) else '0';
	pix_data_o <= w_pix_data when (phase = P_WALLS) else
		s_pix_data when (phase = P_SPRITES) else
		o_pix_data;
	m_req_o <= s_req when (phase = P_SPRITES) else
		o_req when (phase = P_OVERLAY) else '0';
	m_addr_o <= s_addr when (phase = P_SPRITES) else o_addr;
	map_b_addr_o <= o_map_addr when (phase = P_OVERLAY) else w_map_b_addr;
	-- The wall z-buffer: the sprite engine's while it draws, otherwise the game core's hitscan
	zaddr <= s_zaddr when (phase = P_SPRITES) else gz_addr_i;
	gz_data_o <= zdata;

	-- Minimap seen bits: ray engine writes, overlay reads, cleared per level
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (phase = P_CLEAR) then
				seen(to_integer(clear_addr)) <= '0';
			elsif (seen_we = '1') then
				seen(to_integer(unsigned(seen_waddr))) <= '1';
			end if;
			seen_rdata <= seen(to_integer(unsigned(o_seen_addr)));
		end if;
	end process;

	busy_o <= '0' when (phase = P_IDLE) else '1';
	done_o <= done;
	cycles_o <= std_logic_vector(cycles);
end arch;

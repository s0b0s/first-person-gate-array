--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Wall Renderer
-- Module Name:    render_top
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Walls, floors and ceilings of one frame with floor and
--                 ceiling heights and ramps (stage 4):
--                   ray_engine -> span FIFO (16) -> column_rasterizer
--                   -> pixel write port (to the SRAM pixel FIFO)
--                 The ray engine walks each column front to back and sends
--                 its spans (render_types_pkg DESC_*) while the rasterizer
--                 draws earlier ones (the rasterizer's SRAM writes set the
--                 pace: about 480 clocks per column).
--                 The ray engine owns tile map port A; the rasterizer reads
--                 the map through the shared port B (the frame renderer
--                 hands port B to it while busy_o is high).
--                 Memories filled by the ray engine, read by the sprite
--                 engine and the game (1-clock reads):
--                   z-buffer  320 x 16: z of the wall (or of the edge that
--                             closed the window) per column, Q6.10
--                   clip RAM  320 x 16 entries of CLIP_BITS (z, top, bottom:
--                             the open window after each height edge,
--                             nearest first), address column & entry
--                             (5,120 words, about 4.5 BRAM36)
--                   counts    320 x 5: clip entries per column
--                 Frame registers (pos, angle, eye, doors, fx, buf) must be
--                 stable from start_i until done_o. fx_i (stage 4 effects:
--                 light type offsets, animation frame) goes to both engines:
--                 the ray engine for wall, riser and upper-wall light, the
--                 rasterizer for floor and ceiling light, the sky (with the
--                 view angle) and the animated slime texture.
--                 cycles_o counts clocks from start_i to done_o of the
--                 last frame (debug overlay: render time).
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std,
--                 render_types_pkg, game_pkg, ray_engine, column_rasterizer,
--                 sync_fifo
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 2.10 - Stage 4 effects: fx_i to both engines, angle to the
--                 rasterizer (2.00: spans, clip RAM and clip counts)
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.game_pkg.all;
use work.render_types_pkg.all;

entity render_top is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		start_i: in std_logic; -- Pulse: render one frame
		pos_x_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Camera x, Q6.16
		pos_y_i: in std_logic_vector(POS_BITS - 1 downto 0); -- Camera y, Q6.16
		angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0); -- View angle
		eye_i: in std_logic_vector(EYE_BITS - 1 downto 0); -- Eye height 0..127 (floor + eye)
		doors_i: in std_logic_vector(DOORS_BITS - 1 downto 0); -- Door table
		fx_i: in std_logic_vector(FX_BITS - 1 downto 0); -- Light type offsets, animation frame
		buf_i: in std_logic; -- Framebuffer to draw
		-- Tile map: port A (ray engine) and the renderer's use of port B
		map_a_addr_o: out std_logic_vector(11 downto 0);
		map_a_data_i: in std_logic_vector(23 downto 0);
		map_b_addr_o: out std_logic_vector(11 downto 0);
		map_b_data_i: in std_logic_vector(23 downto 0);
		-- Pixel write port
		pix_valid_o: out std_logic;
		pix_ready_i: in std_logic;
		pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
		-- Z-buffer read port (sprites, hitscan), 1-clock latency
		zbuf_addr_i: in std_logic_vector(8 downto 0);
		zbuf_data_o: out std_logic_vector(15 downto 0);
		-- Clip entries and counts (sprite clipping), 1-clock latency
		clip_raddr_i: in std_logic_vector(12 downto 0); -- Column & entry 3:0
		clip_rdata_o: out std_logic_vector(CLIP_BITS - 1 downto 0);
		ccount_raddr_i: in std_logic_vector(8 downto 0); -- Column
		ccount_rdata_o: out std_logic_vector(4 downto 0);
		seen_we_o: out std_logic; -- Minimap: the ray engine visited ...
		seen_addr_o: out std_logic_vector(11 downto 0); -- ... this cell
		busy_o: out std_logic; -- Frame in progress
		done_o: out std_logic; -- Pulse: every pixel handed to the pixel port
		cycles_o: out std_logic_vector(23 downto 0) -- Clocks the last frame took
	);
end render_top;

architecture arch of render_top is
	component ray_engine is
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
			map_addr_o: out std_logic_vector(11 downto 0);
			map_data_i: in std_logic_vector(23 downto 0);
			desc_valid_o: out std_logic;
			desc_ready_i: in std_logic;
			desc_o: out std_logic_vector(DESC_BITS - 1 downto 0);
			zbuf_we_o: out std_logic;
			zbuf_addr_o: out std_logic_vector(8 downto 0);
			zbuf_data_o: out std_logic_vector(15 downto 0);
			clip_we_o: out std_logic;
			clip_addr_o: out std_logic_vector(12 downto 0);
			clip_data_o: out std_logic_vector(CLIP_BITS - 1 downto 0);
			ccount_we_o: out std_logic;
			ccount_addr_o: out std_logic_vector(8 downto 0);
			ccount_data_o: out std_logic_vector(4 downto 0);
			seen_we_o: out std_logic;
			seen_addr_o: out std_logic_vector(11 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic
		);
	end component;
	component column_rasterizer is
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			start_i: in std_logic;
			pos_x_i: in std_logic_vector(POS_BITS - 1 downto 0);
			pos_y_i: in std_logic_vector(POS_BITS - 1 downto 0);
			angle_i: in std_logic_vector(ANGLE_BITS - 1 downto 0);
			fx_i: in std_logic_vector(FX_BITS - 1 downto 0);
			buf_i: in std_logic;
			desc_valid_i: in std_logic;
			desc_ready_o: out std_logic;
			desc_i: in std_logic_vector(DESC_BITS - 1 downto 0);
			map_addr_o: out std_logic_vector(11 downto 0);
			map_data_i: in std_logic_vector(23 downto 0);
			pix_valid_o: out std_logic;
			pix_ready_i: in std_logic;
			pix_data_o: out std_logic_vector(PIXW_BITS - 1 downto 0);
			busy_o: out std_logic;
			done_o: out std_logic
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

	signal ray_valid, ray_ready: std_logic;
	signal ray_desc: std_logic_vector(DESC_BITS - 1 downto 0);
	signal fifo_valid, fifo_ready: std_logic;
	signal fifo_desc: std_logic_vector(DESC_BITS - 1 downto 0);
	signal zb_we: std_logic;
	signal zb_waddr: std_logic_vector(8 downto 0);
	signal zb_wdata: std_logic_vector(15 downto 0);
	type zbuf_t is array (0 to 511) of std_logic_vector(15 downto 0);
	signal zbuf: zbuf_t := (others => (others => '0'));
	signal clip_we: std_logic;
	signal clip_waddr: std_logic_vector(12 downto 0);
	signal clip_wdata: std_logic_vector(CLIP_BITS - 1 downto 0);
	-- Address column & entry: columns 0..319 use the first 5,120 words only
	constant CLIP_WORDS: natural := 320 * 16;
	type clip_ram_t is array (0 to CLIP_WORDS - 1) of std_logic_vector(CLIP_BITS - 1 downto 0);
	signal clip_ram: clip_ram_t := (others => (others => '0'));
	signal cc_we: std_logic;
	signal cc_waddr: std_logic_vector(8 downto 0);
	signal cc_wdata: std_logic_vector(4 downto 0);
	type count_ram_t is array (0 to 511) of std_logic_vector(4 downto 0);
	signal count_ram: count_ram_t := (others => (others => '0'));
	signal raster_busy, raster_done: std_logic;
	signal busy: std_logic := '0';
	signal count: unsigned(23 downto 0) := (others => '0');
	signal cycles: unsigned(23 downto 0) := (others => '0');
begin
	rays: ray_engine
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			start_i => start_i,
			pos_x_i => pos_x_i,
			pos_y_i => pos_y_i,
			angle_i => angle_i,
			eye_i => eye_i,
			doors_i => doors_i,
			fx_i => fx_i,
			map_addr_o => map_a_addr_o,
			map_data_i => map_a_data_i,
			desc_valid_o => ray_valid,
			desc_ready_i => ray_ready,
			desc_o => ray_desc,
			zbuf_we_o => zb_we,
			zbuf_addr_o => zb_waddr,
			zbuf_data_o => zb_wdata,
			clip_we_o => clip_we,
			clip_addr_o => clip_waddr,
			clip_data_o => clip_wdata,
			ccount_we_o => cc_we,
			ccount_addr_o => cc_waddr,
			ccount_data_o => cc_wdata,
			seen_we_o => seen_we_o,
			seen_addr_o => seen_addr_o,
			busy_o => open,
			done_o => open
		);

	spans: sync_fifo
		generic map (
			WIDTH => DESC_BITS,
			DEPTH_BITS => 4 -- 16 spans: lets the ray engine run ahead of the rasterizer
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			in_valid_i => ray_valid,
			in_ready_o => ray_ready,
			in_data_i => ray_desc,
			out_valid_o => fifo_valid,
			out_ready_i => fifo_ready,
			out_data_o => fifo_desc,
			level_o => open
		);

	raster: column_rasterizer
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			start_i => start_i,
			pos_x_i => pos_x_i,
			pos_y_i => pos_y_i,
			angle_i => angle_i,
			fx_i => fx_i,
			buf_i => buf_i,
			desc_valid_i => fifo_valid,
			desc_ready_o => fifo_ready,
			desc_i => fifo_desc,
			map_addr_o => map_b_addr_o,
			map_data_i => map_b_data_i,
			pix_valid_o => pix_valid_o,
			pix_ready_i => pix_ready_i,
			pix_data_o => pix_data_o,
			busy_o => raster_busy,
			done_o => raster_done
		);

	-- Z-buffer, clip entries and clip counts: written by the ray engine, read
	-- by the sprite engine and the game (block or LUT RAM, 1-clock reads)
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (zb_we = '1') then
				zbuf(to_integer(unsigned(zb_waddr))) <= zb_wdata;
			end if;
			zbuf_data_o <= zbuf(to_integer(unsigned(zbuf_addr_i)));
		end if;
	end process;

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			-- Addresses of columns 320..511 do not exist; the guards keep the index in range
			if ((clip_we = '1') and (unsigned(clip_waddr) < CLIP_WORDS)) then
				clip_ram(to_integer(unsigned(clip_waddr))) <= clip_wdata;
			end if;
			if (unsigned(clip_raddr_i) < CLIP_WORDS) then
				clip_rdata_o <= clip_ram(to_integer(unsigned(clip_raddr_i)));
			end if;
		end if;
	end process;

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			if (cc_we = '1') then
				count_ram(to_integer(unsigned(cc_waddr))) <= cc_wdata;
			end if;
			ccount_rdata_o <= count_ram(to_integer(unsigned(ccount_raddr_i)));
		end if;
	end process;

	-- Frame busy flag and render time
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			busy <= '0';
			count <= (others => '0');
			cycles <= (others => '0');
		elsif rising_edge(clk_i) then
			if (start_i = '1') then
				busy <= '1';
				count <= (others => '0');
			elsif (busy = '1') then
				if (raster_done = '1') then
					busy <= '0';
					cycles <= count + 1;
				elsif (count /= x"FFFFFF") then
					count <= count + 1;
				end if;
			end if;
		end if;
	end process;

	busy_o <= busy;
	done_o <= raster_done;
	cycles_o <= std_logic_vector(cycles);
end arch;

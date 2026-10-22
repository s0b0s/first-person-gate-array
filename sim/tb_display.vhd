--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Display Testbench
-- Module Name:    tb_display
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for display_controller with the
--                 real SRAM path (sram_arbiter, sram_controller,
--                 sram_model) while masters 2 and 3 load the SRAM with
--                 background traffic. Both framebuffers are preloaded
--                 through the SRAM model's back door.
--                 vga_monitor checks sync timing and blanking on every
--                 pixel clock; this testbench predicts every visible
--                 pixel of every checked frame from its own model of the
--                 pixel doubling, palette, tint, dither and test patterns:
--                   frame 1  framebuffer 0
--                   frame 2  framebuffer 1, red tint, one palette entry
--                            rewritten during the previous vblank
--                   frame 3  color bands      frame 4  checker + border
--                   frame 5  grid             frame 6  palette gradient
--                   frame 7  blank
--                 Also checks the PWR_SENSE output enables, that palette
--                 writes are refused outside vblank, and that no line
--                 fetch overruns. Frame 2 is saved as
--                 build/sim/tb_display_frame2.ppm for a visual check.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real, tb_pkg, sram_model, vga_monitor,
--                 display_controller, sram_arbiter, sram_controller,
--                 palette_pkg, game_pkg
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
use work.tb_pkg.all;
use work.sram_model_pkg.all;
use work.palette_pkg.all;
use work.game_pkg.all;

entity tb_display is
end tb_display;

architecture arch of tb_display is
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

	constant PERIOD_SYS: time := 10 ns;
	constant PERIOD_PIX: time := 40 ns;
	constant T_OUT: time := 3.5 ns; -- FPGA clock-to-out plus board trace
	constant LAST_FRAME: natural := 7;
	constant PAL_TEST_INDEX: natural := 16#55#;
	constant PAL_TEST_COLOR: std_logic_vector(17 downto 0) := "110000" & "011000" & "000110";

	type cfg_t is record
		front: natural range 0 to 1;
		pattern: natural range 0 to 7;
		tint: natural range 0 to 3;
		blank: boolean;
		pal_changed: boolean;
	end record;
	type cfg_array_t is array (0 to LAST_FRAME + 1) of cfg_t;
	constant CFG: cfg_array_t := (
		0 => (0, PATTERN_FRAMEBUFFER, TINT_NONE, false, false),
		1 => (0, PATTERN_FRAMEBUFFER, TINT_NONE, false, false),
		2 => (1, PATTERN_FRAMEBUFFER, TINT_RED, false, true),
		3 => (1, PATTERN_BANDS, TINT_NONE, false, true),
		4 => (1, PATTERN_CHECKER, TINT_NONE, false, true),
		5 => (1, PATTERN_GRID, TINT_NONE, false, true),
		6 => (1, PATTERN_GRADIENT, TINT_NONE, false, true),
		7 => (1, PATTERN_FRAMEBUFFER, TINT_NONE, true, true),
		8 => (1, PATTERN_FRAMEBUFFER, TINT_NONE, true, true)
	);

	shared variable chk: checker_t;

	signal clk_sys: std_logic := '0';
	signal clk_rd: std_logic := '0';
	signal clk_pix: std_logic := '0';
	signal rst: std_logic := '1';
	signal done: boolean := false;

	-- Display settings
	signal front: std_logic := '0';
	signal pattern: std_logic_vector(2 downto 0) := (others => '0');
	signal tint: std_logic_vector(1 downto 0) := (others => '0');
	signal blank: std_logic := '0';
	signal pcb_on: std_logic := '0';
	signal pal_valid: std_logic := '0';
	signal pal_ready: std_logic;
	signal pal_addr: std_logic_vector(7 downto 0) := (others => '0');
	signal pal_data: std_logic_vector(17 downto 0) := (others => '0');
	signal vblank, line_start, overrun: std_logic;
	signal line: std_logic_vector(7 downto 0);
	signal overruns: natural := 0;

	-- VGA pins
	signal vga_r, vga_g, vga_b: std_logic_vector(3 downto 0);
	signal vga_hs, vga_vs: std_logic;
	signal vga_t: std_logic_vector(13 downto 0);
	signal mon_locked, mon_visible, mon_sample: boolean;
	signal mon_h, mon_v, mon_frames, mon_errors: natural;

	-- SRAM path
	signal m_req, m_we, m_gnt, m_rvalid: std_logic_vector(3 downto 0);
	signal m_addr: std_logic_vector(4 * 19 - 1 downto 0);
	signal m_wdata: std_logic_vector(4 * 8 - 1 downto 0);
	signal m_rdata: std_logic_vector(7 downto 0);
	signal d_req: std_logic;
	signal d_addr: std_logic_vector(18 downto 0);
	signal bg_addr2, bg_addr3: unsigned(18 downto 0) := to_unsigned(16#40000#, 19);
	signal cmd_valid, cmd_ready, cmd_we: std_logic;
	signal cmd_addr: std_logic_vector(18 downto 0);
	signal cmd_wdata: std_logic_vector(7 downto 0);
	signal cmd_tag, rsp_tag: std_logic_vector(1 downto 0);
	signal rsp_valid, busy: std_logic;
	signal rsp_data: std_logic_vector(7 downto 0);
	signal pin_a: std_logic_vector(18 downto 0);
	signal pin_dq_o, pin_dq_t: std_logic_vector(7 downto 0);
	signal pin_oe_n, pin_we_n, pin_ce_n: std_logic;
	signal brd_a: std_logic_vector(18 downto 0) := (others => '0');
	signal brd_oe_n, brd_we_n, brd_ce_n: std_logic := '1';
	signal dq: std_logic_vector(7 downto 0);
	signal sram_driving: boolean;
	signal sram_errors: natural;

	-- Framebuffer contents used by the preload and the prediction
	function fb_value(buf: natural; x: natural; y: natural) return natural is
	begin
		if (buf = 0) then
			return (x + 3 * y) mod 256;
		else
			return ((x / 4) * 16 + (y / 4)) mod 256;
		end if;
	end function;

	-- Expected palette index of a screen pixel (not used for bands)
	function expected_index(c: cfg_t; h: natural; v: natural) return natural is
		constant X: natural := h / 2;
		constant Y: natural := v / 2;
		constant BORDER: boolean := (X = 0) or (X = 319) or (Y = 0) or (Y = 239);
	begin
		case c.pattern is
			when PATTERN_CHECKER =>
				if (BORDER) then
					return 15;
				elsif (((X + Y) mod 2) = 1) then
					return 7;
				else
					return 0;
				end if;
			when PATTERN_GRID =>
				if (BORDER or ((X mod 8) = 0) or ((Y mod 8) = 0)) then
					return 15;
				else
					return 0;
				end if;
			when PATTERN_GRADIENT =>
				return ((v / 32) * 20 + h / 32) mod 256;
			when others =>
				return fb_value(c.front, X, Y);
		end case;
	end function;

	-- Expected 12-bit pin value (R & G & B) of a screen pixel
	function expected_pins(c: cfg_t; h: natural; v: natural) return std_logic_vector is
		type dither_t is array (0 to 3) of natural;
		constant BAYER: dither_t := (0, 2, 3, 1); -- index 2 * (v mod 2) + (h mod 2)
		variable col: std_logic_vector(17 downto 0);
		variable ch: natural;
		variable res: std_logic_vector(11 downto 0);
		type tint_t is array (0 to 2) of natural;
		variable t: tint_t;
	begin
		if (c.blank) then
			return x"000";
		end if;
		if (c.pattern = PATTERN_BANDS) then
			res := (others => '0');
			-- 12 bars, one per pin bit from R(3) down to B(0), 42 pixels wide every 50
			for i in 0 to 11 loop
				if ((h >= 20 + 50 * i) and (h < 20 + 50 * i + 42)) then
					res(11 - i) := '1';
				end if;
			end loop;
			return res;
		end if;
		if (c.pal_changed and (expected_index(c, h, v) = PAL_TEST_INDEX)) then
			col := PAL_TEST_COLOR;
		else
			col := DEFAULT_PALETTE(expected_index(c, h, v));
		end if;
		case c.tint is
			when TINT_RED => t := (63, 0, 0);
			when TINT_GOLD => t := (63, 52, 0);
			when TINT_GREEN => t := (0, 63, 0);
			when others => null;
		end case;
		-- Per 6-bit channel (R, G, B): the tint blends 3/4 color with 1/4 tint color, then
		-- the 2x2 Bayer offset and the divide by 4 give the 4-bit pin value
		for k in 0 to 2 loop
			ch := to_integer(unsigned(col(17 - 6 * k downto 12 - 6 * k)));
			if (c.tint /= TINT_NONE) then
				ch := (3 * ch + t(k)) / 4;
			end if;
			ch := (ch + BAYER(2 * (v mod 2) + (h mod 2))) / 4;
			if (ch > 15) then
				ch := 15;
			end if;
			res(11 - 4 * k downto 8 - 4 * k) := std_logic_vector(to_unsigned(ch, 4));
		end loop;
		return res;
	end function;
begin
	------------------------------------------------------------------
	-- Design under test and the SRAM path
	------------------------------------------------------------------
	dut: display_controller
		port map (
			clk_sys_i => clk_sys,
			rst_sys_i => rst,
			clk_pix_i => clk_pix,
			rst_pix_i => rst,
			front_i => front,
			pattern_i => pattern,
			tint_i => tint,
			blank_i => blank,
			pcb_on_i => pcb_on,
			pal_valid_i => pal_valid,
			pal_ready_o => pal_ready,
			pal_addr_i => pal_addr,
			pal_data_i => pal_data,
			m_req_o => d_req,
			m_addr_o => d_addr,
			m_gnt_i => m_gnt(0),
			m_rvalid_i => m_rvalid(0),
			m_rdata_i => m_rdata,
			vblank_o => vblank,
			line_start_o => line_start,
			line_o => line,
			overrun_o => overrun,
			vga_r_o => vga_r,
			vga_g_o => vga_g,
			vga_b_o => vga_b,
			vga_hs_o => vga_hs,
			vga_vs_o => vga_vs,
			vga_t_o => vga_t
		);

	-- Masters: 0 display, 1 idle, 2 writes and 3 reads outside the
	-- framebuffers as background traffic
	m_req <= '1' & '1' & '0' & d_req;
	m_we <= "0100";
	m_addr <= std_logic_vector(bg_addr3) & std_logic_vector(bg_addr2) &
		std_logic_vector(to_unsigned(0, 19)) & d_addr;
	m_wdata <= x"00" & std_logic_vector(bg_addr2(7 downto 0)) & x"0000";

	process(clk_sys)
	begin
		if rising_edge(clk_sys) then
			-- Bit 18 stays set: the traffic never touches the framebuffers
			if (m_gnt(2) = '1') then
				bg_addr2 <= (bg_addr2 + 7) or to_unsigned(16#40000#, 19);
			end if;
			if (m_gnt(3) = '1') then
				bg_addr3 <= (bg_addr3 + 13) or to_unsigned(16#40000#, 19);
			end if;
		end if;
	end process;

	arb: sram_arbiter
		port map (
			clk_i => clk_sys,
			rst_i => rst,
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
			busy_i => busy,
			clear_count_i => '0',
			busy_count_o => open
		);

	ctrl: sram_controller
		port map (
			clk_i => clk_sys,
			clk_rd_i => clk_rd,
			rst_i => rst,
			cmd_valid_i => cmd_valid,
			cmd_ready_o => cmd_ready,
			cmd_we_i => cmd_we,
			cmd_addr_i => cmd_addr,
			cmd_wdata_i => cmd_wdata,
			cmd_tag_i => cmd_tag,
			rsp_valid_o => rsp_valid,
			rsp_data_o => rsp_data,
			rsp_tag_o => rsp_tag,
			busy_o => busy,
			sram_a_o => pin_a,
			sram_dq_o => pin_dq_o,
			sram_dq_t_o => pin_dq_t,
			sram_dq_i => dq,
			sram_oe_n_o => pin_oe_n,
			sram_we_n_o => pin_we_n,
			sram_ce_n_o => pin_ce_n
		);

	brd_a <= transport pin_a after T_OUT;
	brd_oe_n <= transport pin_oe_n after T_OUT;
	brd_we_n <= transport pin_we_n after T_OUT;
	brd_ce_n <= transport pin_ce_n after T_OUT;
	dq <= transport pin_dq_o after T_OUT when (pin_dq_t(0) = '0') else
		(others => 'Z') after T_OUT;

	mem: sram_model
		port map (
			a_i => brd_a,
			dq_io => dq,
			ce_n_i => brd_ce_n,
			oe_n_i => brd_oe_n,
			we_n_i => brd_we_n,
			driving_o => sram_driving,
			errors_o => sram_errors
		);

	mon: vga_monitor
		generic map (
			OUT_BITS => 4,
			DUMP_FRAME => 2,
			DUMP_FILE => "tb_display_frame2.ppm"
		)
		port map (
			clk_pix_i => clk_pix,
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

	------------------------------------------------------------------
	-- Clocks and reset
	------------------------------------------------------------------
	process
	begin
		if (done) then
			wait;
		end if;
		clk_sys <= '0';
		wait for PERIOD_SYS / 2;
		clk_sys <= '1';
		wait for PERIOD_SYS / 2;
	end process;

	clk_rd <= transport clk_sys after 1.04 ns; -- The MMCM's +37.5 deg SRAM read clock

	process
	begin
		-- Start the pixel clock at an odd offset: the domains are unrelated
		wait for 3.3 ns;
		while (not done) loop
			clk_pix <= '0';
			wait for PERIOD_PIX / 2;
			clk_pix <= '1';
			wait for PERIOD_PIX / 2;
		end loop;
		wait;
	end process;

	process
	begin
		rst <= '1';
		wait for 10.5 * PERIOD_PIX;
		rst <= '0';
		wait;
	end process;

	------------------------------------------------------------------
	-- Pixel checker: every visible pixel of frames 1..LAST_FRAME
	------------------------------------------------------------------
	process
		variable got, want: std_logic_vector(11 downto 0);
		variable bad: natural := 0;
		variable frame_bad: natural := 0;
		variable last_frame: natural := 0;
	begin
		if (mon_frames /= last_frame) then
			if ((last_frame >= 1) and (last_frame <= LAST_FRAME)) then
				chk.check(frame_bad = 0, "frame " & integer'image(last_frame) & ": " &
					integer'image(frame_bad) & " wrong pixels");
			end if;
			frame_bad := 0;
			last_frame := mon_frames;
		end if;
		if (mon_visible and (mon_frames >= 1) and (mon_frames <= LAST_FRAME)) then
			got := vga_r & vga_g & vga_b;
			want := expected_pins(CFG(mon_frames), mon_h, mon_v);
			if (got /= want) then
				frame_bad := frame_bad + 1;
				bad := bad + 1;
				if (bad <= 5) then
					report "pixel (" & integer'image(mon_h) & "," & integer'image(mon_v) &
						") frame " & integer'image(mon_frames) & " got " & to_hex(got) &
						" want " & to_hex(want) severity error;
				end if;
			end if;
		end if;
		wait on mon_sample; -- One check per monitor sample
	end process;

	process(clk_sys)
	begin
		if rising_edge(clk_sys) then
			if (overrun = '1') then
				overruns <= overruns + 1;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Stimulus: preload, output enable, per-frame settings
	------------------------------------------------------------------
	process
	begin
		for y in 0 to 239 loop
			for x in 0 to 319 loop
				sram_mem.write(y * 320 + x, std_logic_vector(to_unsigned(fb_value(0, x, y), 8)));
				sram_mem.write(16#20000# + y * 320 + x,
					std_logic_vector(to_unsigned(fb_value(1, x, y), 8)));
			end loop;
		end loop;
		wait until (rst = '0');

		-- PWR_SENSE gate: pins released until pcb_on, driven after
		wait for 2 us;
		chk.check(vga_t = "11111111111111", "VGA pins high-Z while pcb_on = 0");
		pcb_on <= '1';
		wait for 10 * PERIOD_PIX;
		chk.check(vga_t = "00000000000000", "VGA pins driven after pcb_on");

		-- Settings for frame k + 1 are set during frame k (they are taken
		-- at the next vblank; the front buffer at the next line-0 fetch)
		for k in 1 to LAST_FRAME - 1 loop
			wait until (mon_frames = k) and (mon_v = 10);
			front <= '1' when (CFG(k + 1).front = 1) else '0';
			pattern <= std_logic_vector(to_unsigned(CFG(k + 1).pattern, 3));
			tint <= std_logic_vector(to_unsigned(CFG(k + 1).tint, 2));
			blank <= '1' when CFG(k + 1).blank else '0';
			if (k = 1) then
				-- Palette write: refused now (visible area), taken in vblank
				wait until rising_edge(clk_sys);
				chk.check(pal_ready = '0', "palette write refused during the frame");
				pal_addr <= std_logic_vector(to_unsigned(PAL_TEST_INDEX, 8));
				pal_data <= PAL_TEST_COLOR;
				pal_valid <= '1';
				loop
					wait until rising_edge(clk_sys);
					exit when (pal_ready = '1');
				end loop;
				-- The pins run 3 pixels behind the internal raster, so the
				-- monitor is at the end of line 479 when vblank starts
				chk.check(not mon_visible, "palette write accepted in vblank");
				pal_valid <= '0';
			end if;
		end loop;
		wait until (mon_frames = LAST_FRAME + 1);

		chk.check(mon_errors = 0, "VGA timing errors: " & integer'image(mon_errors));
		chk.check(sram_errors = 0, "SRAM timing errors: " & integer'image(sram_errors));
		chk.check(overruns = 0, "line fetch overruns: " & integer'image(overruns));
		done <= true;
		tb_finish("tb_display", chk.checks, chk.errors);
		wait;
	end process;
end arch;

--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    UART Debug Port Testbench
-- Module Name:    tb_debug_port
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Self-checking testbench for debug_port at BAUD with
--                 the real SRAM path behind master 3 (sram_arbiter,
--                 sram_controller, sram_model) and a PC-side UART. Tests:
--                 ping, echo, status register read, control register
--                 write and read back (and ctrl_o), unused register, 40-byte
--                 SRAM write and read back (also via the model's back
--                 door), unknown command, and a command abandoned half-way
--                 (dropped after TIMEOUT_MS = 1 ms; the next ping works).
--                 Frame stream ('V', FRAME_PIXELS = 1024 to keep it short,
--                 shadow split after pixel 600 so both shadow areas are
--                 used; both framebuffers preloaded through the model's
--                 back door with long runs, runs over 255, runs of 1 to 3,
--                 ESC-valued pixels and single values):
--                 - header fields: 'F', frame number, pixel count, flags
--                   (RLE, blank, delta, pattern), tint, palette count
--                 - data bytes equal a reference encoder's byte for byte
--                   (key and delta frames), decode back to the front
--                   buffer (skips from the previous image), the pixel sum
--                   matches, and the shadow holds the frame afterwards
--                 - the first frame follows 'V' at once as a key frame;
--                   three front changes while a command is pending give one
--                   delta frame numbered +3 (two skipped) from the new front
--                   buffer; two more give +5 with nothing changed (only skip
--                   tokens); no frame without a change
--                 - pixels changed between frames give short skips sent as
--                   literals, ESC-valued ones included
--                 - a register read sent during a frame: the frame arrives
--                   whole and the reply follows it
--                 - 'V' 1 while streaming: the next frame is a key frame
--                 - 'V' 0 during a frame: the frame ends, then 'K', then no
--                   more frames
--                 RUN_VARIANTS: BAUD=1000000 BAUD=4000000 BAUD=12000000
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164, IEEE.numeric_std, tb_pkg,
--                 sram_model, debug_port, uart_rx, uart_tx, sram_arbiter,
--                 sram_controller
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - Procedure-based checks instead of a protected type
-- Revision 1.02 - BAUD generic, frame stream tests
-- Revision 1.03 - Delta frames, 12 Mbaud
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.tb_pkg.all;
use work.sram_model_pkg.all;
use work.hw_pkg.all;

entity tb_debug_port is
	generic(
		BAUD: natural := 12_000_000 -- UART rate of the port and the PC side
	);
end tb_debug_port;

architecture arch of tb_debug_port is
	component debug_port is
		generic(
			CLK_HZ: natural := 100_000_000;
			BAUD: natural := 12_000_000;
			TIMEOUT_MS: natural := 100;
			CTRL_INIT: std_logic_vector(8 * 32 - 1 downto 0) := (others => '0');
			FRAME_PIXELS: positive := 76_800;
			SHADOW0_BASE: natural := VIEW0_BASE;
			SHADOW0_BYTES: natural := VIEW0_BYTES;
			SHADOW1_BASE: natural := VIEW1_BASE
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			rx_i: in std_logic;
			tx_o: out std_logic;
			status_i: in std_logic_vector(32 * 32 - 1 downto 0);
			ctrl_o: out std_logic_vector(8 * 32 - 1 downto 0);
			front_i: in std_logic;
			view_i: in std_logic_vector(7 downto 0);
			pal_count_i: in std_logic_vector(7 downto 0);
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

	constant PERIOD: time := 10 ns;
	constant BIT_TIME: time := 1 sec / BAUD;
	constant T_OUT: time := 3.5 ns; -- FPGA clock-to-out plus board trace
	constant NPIX: natural := 1024; -- Pixels per streamed frame here
	constant SPLIT: natural := 600; -- Pixels in the first shadow area here
	type image_t is array (0 to NPIX - 1) of natural;
	constant RING: natural := 8192; -- Received bytes kept (a frame is at most 3 * NPIX + 11)
	type bytes_t is array (0 to RING - 1) of std_logic_vector(7 downto 0);

	-- Test image of framebuffer fb (0 or 1), pixel i: a 300-pixel run (split
	-- at 255), single values, ESC (255) twice and once, a 2-run, a 3-run,
	-- then runs of 16
	function pix(fb: natural; i: natural) return natural is
	begin
		if (i < 300) then
			return 7 + fb;
		elsif (i < 400) then
			return (i * 37 + fb) mod 255;
		elsif (i < 402) then
			return 255;
		elsif (i = 402) then
			return 9;
		elsif (i < 405) then
			return 10;
		elsif (i < 408) then
			return 11;
		elsif (i = 408) then
			return 255;
		end if;
		return ((i / 16) * 5 + 3 * fb) mod 255;
	end function;

	signal clk, clk_rd: std_logic := '0';
	signal rst: std_logic := '1';
	signal done: boolean := false;
	signal pc_tx: std_logic := '1'; -- PC to FPGA
	signal fpga_tx: std_logic; -- FPGA to PC
	signal status: std_logic_vector(32 * 32 - 1 downto 0);
	signal ctrl: std_logic_vector(8 * 32 - 1 downto 0);
	signal rx_count, tx_count: std_logic_vector(15 downto 0);
	signal replies: bytes_t;
	signal nreplies: natural := 0;
	signal rx_checks, rx_errors: natural := 0; -- PC-side receiver check counts
	signal front: std_logic := '0';
	signal view: std_logic_vector(7 downto 0) := x"2E"; -- Blank, pattern 3, tint 2
	signal pal_count: std_logic_vector(7 downto 0) := x"5A";

	signal g_req, g_we: std_logic;
	signal g_addr: std_logic_vector(18 downto 0);
	signal g_wdata: std_logic_vector(7 downto 0);
	signal m_gnt, m_rvalid: std_logic_vector(3 downto 0);
	signal m_rdata: std_logic_vector(7 downto 0);
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

	-- PC side: send one 8N1 byte
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
begin
	-- Status word w = w * 0x01010101 (easy to recognize)
	status_words: for w in 0 to 31 generate
		status(32 * w + 31 downto 32 * w) <= std_logic_vector(to_unsigned(w * 16#01010101# mod 2 ** 30, 32));
	end generate;

	dut: debug_port
		generic map (
			BAUD => BAUD,
			TIMEOUT_MS => 1,
			CTRL_INIT => (others => '0'),
			FRAME_PIXELS => NPIX,
			SHADOW0_BYTES => SPLIT
		)
		port map (
			clk_i => clk,
			rst_i => rst,
			rx_i => pc_tx,
			tx_o => fpga_tx,
			status_i => status,
			ctrl_o => ctrl,
			front_i => front,
			view_i => view,
			pal_count_i => pal_count,
			m_req_o => g_req,
			m_we_o => g_we,
			m_addr_o => g_addr,
			m_wdata_o => g_wdata,
			m_gnt_i => m_gnt(3),
			m_rvalid_i => m_rvalid(3),
			m_rdata_i => m_rdata,
			rx_count_o => rx_count,
			tx_count_o => tx_count
		);

	arb: sram_arbiter
		port map (
			clk_i => clk,
			rst_i => rst,
			m_req_i => g_req & "000",
			m_we_i => g_we & "000",
			m_addr_i => g_addr & (3 * 19 - 1 downto 0 => '0'),
			m_wdata_i => g_wdata & x"000000",
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

	ctrl_sram: sram_controller
		port map (
			clk_i => clk,
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

	process
	begin
		if (done) then
			wait;
		end if;
		clk <= '0';
		wait for PERIOD / 2;
		clk <= '1';
		wait for PERIOD / 2;
	end process;

	clk_rd <= transport clk after 1.04 ns; -- The MMCM's +37.5 deg SRAM read clock

	process
	begin
		rst <= '1';
		wait for 10.5 * PERIOD;
		rst <= '0';
		wait;
	end process;

	-- PC side receiver: sample each bit in its middle
	process
		variable b: std_logic_vector(7 downto 0);
		variable checks, errors: natural := 0;
	begin
		wait until falling_edge(fpga_tx);
		wait for BIT_TIME / 2;
		check(fpga_tx = '0', "start bit", checks, errors);
		for i in 0 to 7 loop
			wait for BIT_TIME;
			b(i) := fpga_tx;
		end loop;
		wait for BIT_TIME;
		check(fpga_tx = '1', "stop bit", checks, errors);
		rx_checks <= checks;
		rx_errors <= errors;
		replies(nreplies mod RING) <= b;
		nreplies <= nreplies + 1;
	end process;

	-- Stimulus and checks
	process
		variable first: natural;
		variable ok: boolean;
		variable checks, errors: natural := 0;

		-- Wait for n more reply bytes (or give up after a long time)
		procedure expect(n: natural; msg: string) is
		begin
			wait until (nreplies >= first + n) for 2 ms;
			check(nreplies >= first + n, msg & ": got " & integer'image(nreplies - first) &
				" of " & integer'image(n) & " reply bytes", checks, errors);
		end procedure;

		impure function reply(i: natural) return std_logic_vector is
		begin
			return replies((first + i) mod RING);
		end function;

		variable exp: bytes_t; -- Reference encoder output
		variable nexp: natural; -- Its length
		variable fnum, fnum0: natural; -- Frame numbers from headers
		variable lost: boolean; -- A stream byte never came
		variable prev: image_t; -- The last frame sent (what the PC shows)

		-- Byte k after first as a number, waiting for it if needed (0 once a byte is lost)
		procedure get(k: natural; b: out natural) is
		begin
			if ((not lost) and (nreplies <= first + k)) then
				wait until (nreplies > first + k) for 5 ms;
			end if;
			if (nreplies <= first + k) then
				lost := true;
				b := 0;
			else
				b := to_integer(unsigned(replies((first + k) mod RING)));
			end if;
		end procedure;

		-- Pixel i of framebuffer fb, from the SRAM model
		impure function img(fb: natural; i: natural) return natural is
		begin
			if (fb = 1) then
				return to_integer(unsigned(sram_mem.read(FB1_BASE + i)));
			end if;
			return to_integer(unsigned(sram_mem.read(FB0_BASE + i)));
		end function;

		-- Shadow address of pixel i (the DUT's two areas)
		function shadow_at(i: natural) return natural is
		begin
			if (i < SPLIT) then
				return VIEW0_BASE + i;
			end if;
			return VIEW1_BASE + i - SPLIT;
		end function;

		procedure put(b: natural) is
		begin
			exp(nexp) := std_logic_vector(to_unsigned(b, 8));
			nexp := nexp + 1;
		end procedure;

		-- One literal pixel: the value, or ESC 1 ESC
		procedure put_lit(v: natural) is
		begin
			if (v = 255) then
				put(255);
				put(1);
				put(255);
			else
				put(v);
			end if;
		end procedure;

		-- Append the bytes of one finished run to exp (the RTL's rule)
		procedure flush(skip: boolean; v: natural; h2: natural; n: natural) is
		begin
			if (skip and (n >= 3)) then
				put(255);
				put(0);
				put(n);
			elsif (skip) then
				put_lit(v);
				if (n = 2) then
					put_lit(h2);
				end if;
			elsif ((n >= 3) or (v = 255)) then
				put(255);
				put(n);
				put(v);
			else
				for j in 1 to n loop
					put(v);
				end loop;
			end if;
		end procedure;

		-- Reference encoder: the data bytes of framebuffer fb into exp, as a
		-- delta frame against prev or as a key frame
		procedure ref_encode(fb: natural; delta: boolean) is
			variable rv, rl, v, h2: natural;
			variable rs, same: boolean;
		begin
			nexp := 0;
			rv := 0;
			rl := 0;
			h2 := 0;
			rs := false;
			for i in 0 to NPIX - 1 loop
				v := img(fb, i);
				same := delta and (v = prev(i));
				if ((rl /= 0) and (not rs) and (v = rv) and (rl < 255)) then
					rl := rl + 1;
				elsif ((rl /= 0) and rs and same and (rl < 255)) then
					if (rl = 1) then
						h2 := v;
					end if;
					rl := rl + 1;
				else
					if (rl /= 0) then
						flush(rs, rv, h2, rl);
					end if;
					rs := same;
					rv := v;
					rl := 1;
				end if;
			end loop;
			flush(rs, rv, h2, rl);
		end procedure;

		-- Read the frame that starts at byte first, check it against framebuffer
		-- fb (a delta frame against prev, or a key frame), put its number in
		-- fnum, move first past it, and make it the new prev
		procedure check_frame(fb: natural; delta: boolean; msg: string) is
			variable b, n, v, k, count, sum, bad, mism, flags: natural;
		begin
			lost := false;
			get(0, b);
			check(b = 16#46#, msg & ": header starts with F", checks, errors);
			get(1, b);
			get(2, n);
			fnum := b + 256 * n;
			get(3, b);
			get(4, n);
			get(5, v);
			check(b + 256 * n + 65536 * v = NPIX, msg & ": pixel count", checks, errors);
			get(6, b);
			flags := 16 * to_integer(unsigned(view(4 downto 2))) + 2 * to_integer(unsigned(view(5 downto 5))) + 1;
			if (delta) then
				flags := flags + 4;
			end if;
			check(b = flags, msg & ": flags (RLE, blank, delta, pattern) " & integer'image(b), checks, errors);
			get(7, b);
			check(b = to_integer(unsigned(view(1 downto 0))), msg & ": tint", checks, errors);
			get(8, b);
			check(b = to_integer(unsigned(pal_count)), msg & ": palette count", checks, errors);
			-- Byte for byte against the reference encoder
			ref_encode(fb, delta);
			mism := 0;
			for j in 0 to nexp - 1 loop
				get(9 + j, b);
				if (b /= to_integer(unsigned(exp(j)))) then
					mism := mism + 1;
				end if;
			end loop;
			check(mism = 0, msg & ": data bytes equal the reference encoder (" & integer'image(mism) &
				" of " & integer'image(nexp) & " differ)", checks, errors);
			-- Decode the same bytes back into pixels (ESC 0 n: n pixels from prev)
			k := 9;
			count := 0;
			bad := 0;
			sum := 0;
			while ((count < NPIX) and (k < 9 + 3 * NPIX) and (not lost)) loop
				get(k, b);
				k := k + 1;
				if (b = 255) then
					get(k, n);
					get(k + 1, v);
					k := k + 2;
					if (n = 0) then
						for j in 1 to v loop
							if (count < NPIX) then
								if (prev(count) /= img(fb, count)) then
									bad := bad + 1;
								end if;
								sum := (sum + prev(count)) mod 65536;
							end if;
							count := count + 1;
						end loop;
					end if;
				else
					n := 1;
					v := b;
				end if;
				for j in 1 to n loop
					if ((count < NPIX) and (v /= img(fb, count))) then
						bad := bad + 1;
					end if;
					count := count + 1;
					sum := (sum + v) mod 65536;
				end loop;
			end loop;
			check((count = NPIX) and (bad = 0), msg & ": decodes to the framebuffer (" &
				integer'image(count) & " pixels, " & integer'image(bad) & " wrong)", checks, errors);
			check(k = 9 + nexp, msg & ": data length", checks, errors);
			get(k, b);
			get(k + 1, n);
			check(b + 256 * n = sum, msg & ": pixel sum", checks, errors);
			check(not lost, msg & ": every byte arrived", checks, errors);
			first := first + k + 2;
			-- The PC now shows this frame, and so must the shadow
			wait for 2 us; -- The last shadow writes leave the DUT
			bad := 0;
			for i in 0 to NPIX - 1 loop
				prev(i) := img(fb, i);
				if (to_integer(unsigned(sram_mem.read(shadow_at(i)))) /= prev(i)) then
					bad := bad + 1;
				end if;
			end loop;
			check(bad = 0, msg & ": shadow holds the frame (" & integer'image(bad) & " wrong)",
				checks, errors);
		end procedure;
	begin
		wait until (rst = '0');
		wait for 2 us;

		-- Ping
		first := nreplies;
		pc_send(pc_tx, x"50");
		expect(1, "ping");
		check(reply(0) = x"4B", "ping replies K", checks, errors);

		-- Echo
		first := nreplies;
		pc_send(pc_tx, x"45");
		pc_send(pc_tx, x"A5");
		expect(1, "echo");
		check(reply(0) = x"A5", "echo returns the byte", checks, errors);

		-- Read status register 5: 0x05050505, little endian
		first := nreplies;
		pc_send(pc_tx, x"52");
		pc_send(pc_tx, x"05");
		expect(4, "read reg 5");
		check((reply(0) & reply(1) & reply(2) & reply(3)) = x"05050505", "status reg 5 value",
			checks, errors);

		-- Write control register 33, read it back
		first := nreplies;
		-- 'W', register 0x21, then the 32-bit value least significant byte first
		pc_send(pc_tx, x"57");
		pc_send(pc_tx, x"21");
		pc_send(pc_tx, x"78");
		pc_send(pc_tx, x"56");
		pc_send(pc_tx, x"34");
		pc_send(pc_tx, x"12");
		expect(1, "write reg 33");
		check(reply(0) = x"4B", "write replies K", checks, errors);
		check(ctrl(63 downto 32) = x"12345678", "ctrl word 1 written", checks, errors);
		first := nreplies;
		pc_send(pc_tx, x"52");
		pc_send(pc_tx, x"21");
		expect(4, "read reg 33");
		check((reply(3) & reply(2) & reply(1) & reply(0)) = x"12345678", "reg 33 reads back",
			checks, errors);

		-- Unused register reads as 0
		first := nreplies;
		pc_send(pc_tx, x"52");
		pc_send(pc_tx, x"40");
		expect(4, "read reg 64");
		check((reply(0) & reply(1) & reply(2) & reply(3)) = x"00000000", "unused register is 0",
			checks, errors);

		-- SRAM write: 40 bytes at 0x41230
		first := nreplies;
		-- 'S', then address and length, 3 bytes each, least significant first, then the data
		pc_send(pc_tx, x"53");
		pc_send(pc_tx, x"30");
		pc_send(pc_tx, x"12");
		pc_send(pc_tx, x"04");
		pc_send(pc_tx, x"28");
		pc_send(pc_tx, x"00");
		pc_send(pc_tx, x"00");
		for i in 0 to 39 loop
			pc_send(pc_tx, std_logic_vector(to_unsigned(200 - 3 * i, 8)));
		end loop;
		expect(1, "SRAM write");
		check(reply(0) = x"4B", "SRAM write replies K", checks, errors);
		ok := true;
		for i in 0 to 39 loop
			if (sram_mem.read(16#41230# + i) /= std_logic_vector(to_unsigned(200 - 3 * i, 8))) then
				ok := false;
			end if;
		end loop;
		check(ok, "SRAM holds the 40 written bytes", checks, errors);

		-- SRAM read back
		first := nreplies;
		pc_send(pc_tx, x"4D");
		pc_send(pc_tx, x"30");
		pc_send(pc_tx, x"12");
		pc_send(pc_tx, x"04");
		pc_send(pc_tx, x"28");
		pc_send(pc_tx, x"00");
		pc_send(pc_tx, x"00");
		expect(40, "SRAM read");
		ok := true;
		for i in 0 to 39 loop
			if (reply(i) /= std_logic_vector(to_unsigned(200 - 3 * i, 8))) then
				ok := false;
			end if;
		end loop;
		check(ok, "SRAM read returns the 40 bytes", checks, errors);

		-- Unknown command
		first := nreplies;
		pc_send(pc_tx, x"5A");
		expect(1, "unknown command");
		check(reply(0) = x"3F", "unknown command replies ?", checks, errors);

		-- Abandoned command: 'W' and two bytes, then silence past the
		-- timeout; the next ping must work
		first := nreplies;
		pc_send(pc_tx, x"57");
		pc_send(pc_tx, x"21");
		pc_send(pc_tx, x"00");
		wait for 1.5 ms;
		check(nreplies = first, "no reply to an abandoned command", checks, errors);
		pc_send(pc_tx, x"50");
		expect(1, "ping after timeout");
		check(reply(0) = x"4B", "ping works after a dropped command", checks, errors);
		check(ctrl(63 downto 32) = x"12345678", "abandoned write changed nothing", checks, errors);

		-- Every byte the PC side sent above
		check(unsigned(rx_count) = 74, "rx byte count " & integer'image(to_integer(unsigned(rx_count))),
			checks, errors);
		check(unsigned(tx_count) = nreplies, "tx byte count", checks, errors);

		------------------------------------------------------------------
		-- Frame stream
		------------------------------------------------------------------
		for i in 0 to NPIX - 1 loop
			sram_mem.write(FB0_BASE + i, std_logic_vector(to_unsigned(pix(0, i), 8)));
			sram_mem.write(FB1_BASE + i, std_logic_vector(to_unsigned(pix(1, i), 8)));
		end loop;
		front <= '1'; -- Front change 1, while the stream is off
		wait for 1 us;

		-- 'V' 1: 'K', then a key frame of the front buffer at once
		first := nreplies;
		pc_send(pc_tx, x"56");
		pc_send(pc_tx, x"01");
		expect(1, "stream on");
		check(reply(0) = x"4B", "'V' 1 replies K", checks, errors);
		first := first + 1;
		check_frame(1, false, "first frame (key)");
		fnum0 := fnum;
		check(fnum0 = 1, "first frame number counts the front change before it", checks, errors);

		-- No front change, no frame
		wait for 300 * BIT_TIME;
		check(nreplies = first, "no frame without a front change", checks, errors);

		-- Front changes while the port waits for an echo argument (commands
		-- come first, so no frame starts yet; pixels are read from the live
		-- front buffer, so changing it during a frame would tear the picture):
		-- three changes give one delta frame numbered +3 (two skipped, never
		-- waited for) from FB0; two more give +5, nothing changed
		pc_send(pc_tx, x"45");
		wait for BIT_TIME + 200 ns; -- The port has taken the command byte
		front <= '0';
		wait for 50 ns;
		front <= '1';
		wait for 50 ns;
		front <= '0';
		pc_send(pc_tx, x"3C");
		expect(1, "echo during front changes");
		check(reply(0) = x"3C", "echo returns the byte", checks, errors);
		first := first + 1;
		check_frame(0, true, "frame after three changes");
		check(fnum = fnum0 + 3, "its number is +3 (two frames skipped)", checks, errors);
		pc_send(pc_tx, x"45");
		wait for BIT_TIME + 200 ns;
		front <= '1';
		wait for 50 ns;
		front <= '0';
		pc_send(pc_tx, x"3D");
		expect(1, "echo during two front changes");
		first := first + 1;
		check_frame(0, true, "frame with nothing changed");
		check(fnum = fnum0 + 5, "its number is +5", checks, errors);
		check(nexp = 3 * ((NPIX + 254) / 255), "nothing changed: only skip tokens, " &
			integer'image(nexp) & " bytes", checks, errors);
		wait for 300 * BIT_TIME;
		check(nreplies = first, "no further frames", checks, errors);

		-- Change FB1 so that the unchanged pixels 400..408 (255, 255, 9, 10,
		-- 10, 11, 11, 11, 255 in both buffers) split into skips of 2, 1, 1
		-- and 2 pixels, sent as literals (ESC 1 ESC for the 255s)
		sram_mem.write(FB1_BASE + 402, x"4D");
		sram_mem.write(FB1_BASE + 404, x"4E");
		sram_mem.write(FB1_BASE + 406, x"4F");

		-- A register read sent during a frame: the frame arrives whole, then the reply
		front <= '1';
		wait until (nreplies >= first + 12) for 5 ms;
		pc_send(pc_tx, x"52");
		pc_send(pc_tx, x"05");
		check_frame(1, true, "frame with a command inside");
		check(fnum = fnum0 + 6, "its number is +6", checks, errors);
		expect(4, "read reg 5 during a frame");
		check((reply(0) & reply(1) & reply(2) & reply(3)) = x"05050505", "reply follows the frame",
			checks, errors);
		first := first + 4;

		-- 'V' 1 while streaming: 'K', then a key frame at once
		pc_send(pc_tx, x"56");
		pc_send(pc_tx, x"01");
		expect(1, "key frame request");
		check(reply(0) = x"4B", "'V' 1 again replies K", checks, errors);
		first := first + 1;
		check_frame(1, false, "requested key frame");

		-- 'V' 0 during a frame: the frame ends, then 'K', then no more frames
		front <= '0';
		wait until (nreplies >= first + 12) for 5 ms;
		pc_send(pc_tx, x"56");
		pc_send(pc_tx, x"00");
		check_frame(0, true, "frame with a stop inside");
		expect(1, "stream off");
		check(reply(0) = x"4B", "'V' 0 replies K after the frame", checks, errors);
		first := first + 1;
		front <= '1';
		wait for 50 ns;
		front <= '0';
		wait for 300 * BIT_TIME;
		check(nreplies = first, "no frames once the stream is off", checks, errors);

		check(unsigned(tx_count) = nreplies mod 65536, "tx byte count with the stream", checks, errors);
		check(sram_errors = 0, "SRAM model timing errors", checks, errors);
		done <= true;
		wait for 1 ns; -- The other processes' last counts reach their signals a delta later
		tb_finish("tb_debug_port", checks + rx_checks, errors + rx_errors);
		wait;
	end process;
end arch;

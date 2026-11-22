--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    UART Debug Port
-- Module Name:    debug_port
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    UART debug port and its command set
--                 (PC side: tools/uart/debug_uart.py, live_view.py). 8N1
--                 at BAUD. Multi-byte numbers are little endian.
--                   'P'                      ping      -> 'K'
--                   'E' b                    echo      -> b
--                   'R' n                    read reg  -> 4 bytes
--                   'W' n d0 d1 d2 d3        write reg -> 'K'
--                   'M' a0 a1 a2 l0 l1 l2    read SRAM -> l bytes
--                   'S' a0 a1 a2 l0 l1 l2    write SRAM, then l data
--                                            bytes     -> 'K'
--                   'V' b                    stream on (b bit 0 = 1; the
--                                            next frame is a key frame)
--                                            or off    -> 'K'
--                   anything else                      -> '?'
--                 Registers 0..31: status_i words (read only, as the
--                 bring-up page); 32..39: ctrl_o words (read/write, reset
--                 to CTRL_INIT); others read 0. Length 0 means 2^24.
--                 Commands reach the SRAM one byte at a time (the UART is
--                 the bottleneck). A command with no byte for TIMEOUT_MS
--                 is dropped so the port never hangs.
--                 Frame stream: while on, a frame is sent at once and
--                 then after every front buffer change (front_i toggles),
--                 between commands:
--                   'F', frame number (2 bytes, counts front_i changes),
--                   pixel count (3 bytes, FRAME_PIXELS), flags (bit 0
--                   RLE = 1, bit 1 blank, bit 2 delta, bits 6:4 pattern),
--                   tint (1:0), palette change count, data, 16-bit sum of
--                   all pixels of the frame (2 bytes).
--                 Data: a byte other than ESC (0xFF) is one pixel; ESC n v
--                 (n = 1..255) is n pixels of value v; ESC 0 n is n pixels
--                 unchanged since the previous frame sent (delta frames
--                 only). Runs of 3 or more and every ESC-valued pixel use
--                 the 3-byte forms. 255 is the sprite transparent index,
--                 so it is rare in a frame.
--                 Delta frames: the last frame sent is kept in SRAM (the
--                 shadow, SHADOW0/1_*); a pixel equal to its shadow value
--                 is "unchanged". The first frame after 'V' 1 is a key
--                 frame (every pixel sent, the whole shadow rewritten);
--                 the PC asks for another with 'V' 1 when a sum fails.
--                 Pixel reader (second process): runs ahead of the
--                 encoder through a 31-entry FIFO. Per pixel it reads the
--                 front buffer, then the shadow; when they differ (or in
--                 a key frame) it queues a shadow write. Its request
--                 stays high while it has work, so the arbiter lets it
--                 keep the bus for bursts (up to 8 reads in flight).
--                 Each pixel is read from the buffer that is front at that
--                 moment, so it always comes from a finished frame (the
--                 picture can tear, never show a half-drawn frame).
--                 Swaps during a frame are counted, not waited for: the
--                 game never stalls, frames are skipped instead.
--                 Bytes received while a frame is going out wait in a
--                 31-byte FIFO; their replies follow the frame.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 uart_rx, uart_tx, sync_fifo
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - Plain signals instead of records; one-process state machine
-- Revision 1.02 - Frame stream ('V'), receive FIFO
-- Revision 1.03 - Pixel reader with bursts, delta frames against a shadow copy
-- Additional Comments:
--                 Stream bytes per frame: 11 + data (at most
--                 3 * FRAME_PIXELS, typically far fewer). The shadow
--                 areas must hold FRAME_PIXELS bytes together and are
--                 rewritten by every frame sent.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;

entity debug_port is
	generic(
		CLK_HZ: natural := 100_000_000; -- System clock
		BAUD: natural := 12_000_000; -- UART rate (CLK_HZ / BAUD at least 8)
		TIMEOUT_MS: natural := 100; -- Drop a half-received command after this
		CTRL_INIT: std_logic_vector(8 * 32 - 1 downto 0) := (others => '0'); -- Control reset values
		FRAME_PIXELS: positive := 76_800; -- Pixels per streamed frame (320 x 240)
		SHADOW0_BASE: natural := VIEW0_BASE; -- Shadow: pixels 0 .. SHADOW0_BYTES - 1
		SHADOW0_BYTES: natural := VIEW0_BYTES;
		SHADOW1_BASE: natural := VIEW1_BASE -- Shadow: the remaining pixels
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		rx_i: in std_logic; -- UART from the PC (raw pin)
		tx_o: out std_logic; -- UART to the PC
		status_i: in std_logic_vector(32 * 32 - 1 downto 0); -- Registers 0..31
		ctrl_o: out std_logic_vector(8 * 32 - 1 downto 0); -- Registers 32..39
		-- Frame stream sources
		front_i: in std_logic; -- Front buffer (FB1 when '1'); a change is a new frame
		view_i: in std_logic_vector(7 downto 0); -- Display settings: 1:0 tint, 4:2 pattern, 5 blank
		pal_count_i: in std_logic_vector(7 downto 0); -- Palette writes so far
		-- SRAM arbiter master port
		m_req_o: out std_logic;
		m_we_o: out std_logic;
		m_addr_o: out std_logic_vector(18 downto 0);
		m_wdata_o: out std_logic_vector(7 downto 0);
		m_gnt_i: in std_logic;
		m_rvalid_i: in std_logic;
		m_rdata_i: in std_logic_vector(7 downto 0);
		-- Byte counters for the status page
		rx_count_o: out std_logic_vector(15 downto 0);
		tx_count_o: out std_logic_vector(15 downto 0)
	);
end debug_port;

architecture arch of debug_port is
	component uart_rx is
		generic(
			CLK_HZ: natural := 100_000_000;
			BAUD: natural := 1_000_000
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			rx_i: in std_logic;
			data_o: out std_logic_vector(7 downto 0);
			valid_o: out std_logic;
			frame_err_o: out std_logic
		);
	end component;
	component uart_tx is
		generic(
			CLK_HZ: natural := 100_000_000;
			BAUD: natural := 1_000_000
		);
		port(
			clk_i: in std_logic;
			rst_i: in std_logic;
			data_i: in std_logic_vector(7 downto 0);
			valid_i: in std_logic;
			ready_o: out std_logic;
			tx_o: out std_logic
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

	constant TIMEOUT_CYCLES: natural := (CLK_HZ / 1000) * TIMEOUT_MS;
	constant ESC: std_logic_vector(7 downto 0) := x"FF"; -- Escape byte of the stream data
	constant MAX_RUN: natural := 255; -- Longest run one 3-byte form holds
	-- Pixel reader limits: reads in flight, pixel FIFO and write queue levels
	-- (pixel FIFO holds 31: 24 + 4 pixels in flight + 1 being pushed; write
	-- queue holds 7: 3 + one write per pixel in flight)
	constant MAX_INFLIGHT: natural := 8;
	constant PIX_LIMIT: natural := 24;
	constant WQ_LIMIT: natural := 3;

	type dbg_state_type is (
		DBG_IDLE, -- Wait for a command byte or a frame to stream
		DBG_ARGS, -- Collect argument bytes
		DBG_EXEC, -- Act on a complete command
		DBG_SEND, -- Send 1 to 4 bytes of word, low byte first
		DBG_MREAD_REQ, -- SRAM read: request one byte
		DBG_MREAD_WAIT, -- SRAM read: wait for the data
		DBG_MREAD_SEND, -- SRAM read: send it
		DBG_SWRITE_DATA, -- SRAM write: wait for a data byte
		DBG_SWRITE_REQ, -- SRAM write: write it
		DBG_V_HEAD, -- Stream: send the 9 header bytes
		DBG_V_NEXT, -- Stream: take the next pixel from the reader, or flush the last run
		DBG_V_EMIT, -- Stream: send the 1 to 6 bytes of a finished run
		DBG_V_TAIL, -- Stream: send the 2-byte pixel sum
		DBG_V_DONE -- Stream: wait for the reader's last shadow writes
	);
	signal dbg_state: dbg_state_type := DBG_IDLE;

	signal cmd: std_logic_vector(7 downto 0) := (others => '0');
	signal args: std_logic_vector(47 downto 0) := (others => '0'); -- Argument bytes, first byte in 7:0
	signal nargs: natural range 0 to 6 := 0; -- Arguments still to receive
	signal argi: natural range 0 to 6 := 0; -- Next argument byte position
	signal word: std_logic_vector(31 downto 0) := (others => '0'); -- Bytes to send
	signal nsend: natural range 0 to 4 := 0; -- Bytes still to send
	signal addr: unsigned(18 downto 0) := (others => '0');
	signal len: unsigned(23 downto 0) := (others => '0'); -- Bytes left, minus 1
	signal data: std_logic_vector(7 downto 0) := (others => '0');
	signal ctrl: std_logic_vector(8 * 32 - 1 downto 0) := CTRL_INIT;
	signal timer: natural range 0 to TIMEOUT_CYCLES := 0;
	signal rx_count: unsigned(15 downto 0) := (others => '0');
	signal tx_count: unsigned(15 downto 0) := (others => '0');
	signal rx_data: std_logic_vector(7 downto 0);
	signal rx_valid: std_logic;
	signal tx_data: std_logic_vector(7 downto 0);
	signal tx_valid: std_logic;
	signal tx_ready: std_logic;
	-- Receive FIFO head: the next unread command byte
	signal rx_avail: std_logic;
	signal rx_byte: std_logic_vector(7 downto 0);
	signal rx_pop: std_logic;

	-- Frame stream (encoder side)
	signal stream_on: std_logic := '0';
	signal key: std_logic := '0'; -- The next frame is a key frame
	signal fkey: std_logic := '0'; -- The frame going out is a key frame
	signal frame_go: std_logic := '0'; -- Pulse: start the pixel reader
	signal front_seen: std_logic := '0'; -- front_i one clock ago (change detect)
	signal frame_due: std_logic := '0'; -- A frame should go out (new front, or stream just on)
	signal frame_num: unsigned(15 downto 0) := (others => '0'); -- Front buffer changes so far
	signal vbytes: std_logic_vector(71 downto 0) := (others => '0'); -- Stream bytes to send, low first
	signal vcount: natural range 0 to 9 := 0; -- Stream bytes still to send
	signal vlast: std_logic := '0'; -- The run in vbytes is the frame's last
	signal pos: unsigned(16 downto 0) := (others => '0'); -- Pixels taken so far
	signal run_skip: std_logic := '0'; -- The open run is unchanged pixels (else one value)
	signal run_val: std_logic_vector(7 downto 0) := (others => '0'); -- Its value (first pixel of a skip run)
	signal run_h2: std_logic_vector(7 downto 0) := (others => '0'); -- Second pixel of a skip run
	signal run_len: unsigned(7 downto 0) := (others => '0'); -- Its length (0 = none yet)
	signal sum: unsigned(15 downto 0) := (others => '0'); -- Pixel sum, mod 2^16

	-- Pixel reader
	signal rd_busy: std_logic := '0'; -- Reading the frame (until its last shadow write)
	signal rd_pos: unsigned(16 downto 0) := (others => '0'); -- Next pixel to request
	signal rd_half: std_logic := '0'; -- Next read: '0' front buffer, '1' shadow
	signal rd_saddr: unsigned(18 downto 0) := (others => '0'); -- Shadow address of pixel rd_pos
	signal rd_ret_pos: unsigned(16 downto 0) := (others => '0'); -- Pixel of the next returned pair
	signal rd_ret_saddr: unsigned(18 downto 0) := (others => '0'); -- Its shadow address
	signal rd_ret_half: std_logic := '0'; -- Next returned byte: '0' front, '1' shadow
	signal rd_inflight: natural range 0 to MAX_INFLIGHT := 0; -- Reads granted, data not back
	signal rd_p: std_logic_vector(7 downto 0) := (others => '0'); -- Front value of the returning pair
	signal rd_can_read: std_logic;
	signal rd_req: std_logic;
	signal rd_we: std_logic;
	signal rd_gnt: std_logic;
	signal rd_rvalid: std_logic;
	signal rd_addr: unsigned(18 downto 0);
	signal pix_push: std_logic := '0';
	signal pix_in: std_logic_vector(8 downto 0) := (others => '0'); -- Pixel & changed
	signal pix_avail: std_logic;
	signal pix_out: std_logic_vector(8 downto 0);
	signal pix_pop: std_logic;
	signal pix_level: std_logic_vector(4 downto 0);
	signal wq_push: std_logic := '0';
	signal wq_in: std_logic_vector(26 downto 0) := (others => '0'); -- Shadow address & value
	signal wq_valid: std_logic;
	signal wq_out: std_logic_vector(26 downto 0);
	signal wq_level: std_logic_vector(2 downto 0);
	signal main_port: std_logic; -- The command side has the SRAM port this cycle

	-- Shadow address of pixel n + 1, given a = that of pixel n (registered,
	-- so the address path to the arbiter has no adder)
	function next_saddr(a: unsigned(18 downto 0); n: unsigned(16 downto 0)) return unsigned is
	begin
		if (n = SHADOW0_BYTES - 1) then
			return to_unsigned(SHADOW1_BASE, 19);
		end if;
		return a + 1;
	end function;

	-- One literal pixel: the value itself, or ESC 1 ESC for the escape value
	function lit_bytes(v: std_logic_vector(7 downto 0)) return std_logic_vector is
	begin
		if (v = ESC) then
			return ESC & x"01" & ESC;
		end if;
		return x"0000" & v;
	end function;

	-- Bytes of a finished run, first byte in 7:0. Value run: ESC n v for 3 or
	-- more or the escape value, else the value once or twice. Skip run: ESC 0
	-- n for 3 or more, else its one or two pixels as literals (v, then h2).
	function run_bytes(skip: std_logic; v: std_logic_vector(7 downto 0);
		h2: std_logic_vector(7 downto 0); n: unsigned(7 downto 0)) return std_logic_vector is
		variable b: std_logic_vector(71 downto 0);
	begin
		b := (others => '0');
		if (skip = '0') then
			if ((n >= 3) or (v = ESC)) then
				b(23 downto 0) := v & std_logic_vector(n) & ESC;
			else
				b(15 downto 0) := v & v;
			end if;
		elsif (n >= 3) then
			b(23 downto 0) := std_logic_vector(n) & x"00" & ESC;
		else
			b(23 downto 0) := lit_bytes(v);
			if (v = ESC) then
				b(47 downto 24) := lit_bytes(h2);
			else
				b(31 downto 8) := lit_bytes(h2);
			end if;
		end if;
		return b;
	end function;

	-- How many of run_bytes to send
	function run_count(skip: std_logic; v: std_logic_vector(7 downto 0);
		h2: std_logic_vector(7 downto 0); n: unsigned(7 downto 0)) return natural is
		variable c: natural;
	begin
		if ((n >= 3) or ((skip = '0') and (v = ESC))) then
			return 3;
		elsif (skip = '0') then
			return to_integer(n);
		end if;
		c := 1;
		if (v = ESC) then
			c := 3;
		end if;
		if (n = 2) then
			if (h2 = ESC) then
				c := c + 3;
			else
				c := c + 1;
			end if;
		end if;
		return c;
	end function;
begin
	rx: uart_rx
		generic map (
			CLK_HZ => CLK_HZ,
			BAUD => BAUD
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			rx_i => rx_i,
			data_o => rx_data,
			valid_o => rx_valid,
			frame_err_o => open
		);

	-- 2^5 - 1 = 31 bytes: a few whole commands can wait out one frame. A
	-- byte that finds the FIFO full is lost (only while a frame streams).
	rx_fifo: sync_fifo
		generic map (
			WIDTH => 8,
			DEPTH_BITS => 5
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			in_valid_i => rx_valid,
			in_ready_o => open,
			in_data_i => rx_data,
			out_valid_o => rx_avail,
			out_ready_i => rx_pop,
			out_data_o => rx_byte,
			level_o => open
		);

	tx: uart_tx
		generic map (
			CLK_HZ => CLK_HZ,
			BAUD => BAUD
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			data_i => tx_data,
			valid_i => tx_valid,
			ready_o => tx_ready,
			tx_o => tx_o
		);

	-- Pixels from the reader to the encoder: value (8:1) and changed (0)
	pix_fifo: sync_fifo
		generic map (
			WIDTH => 9,
			DEPTH_BITS => 5
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			in_valid_i => pix_push,
			in_ready_o => open,
			in_data_i => pix_in,
			out_valid_o => pix_avail,
			out_ready_i => pix_pop,
			out_data_o => pix_out,
			level_o => pix_level
		);

	-- Shadow writes waiting for the bus: address (26:8) and value (7:0)
	write_queue: sync_fifo
		generic map (
			WIDTH => 27,
			DEPTH_BITS => 3
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			in_valid_i => wq_push,
			in_ready_o => open,
			in_data_i => wq_in,
			out_valid_o => wq_valid,
			out_ready_i => rd_gnt,
			out_data_o => wq_out,
			level_o => wq_level
		);

	------------------------------------------------------------------
	-- Command and encoder state machine
	------------------------------------------------------------------
	process(clk_i, rst_i)
		variable n: natural range 0 to 255; -- Register number of 'R' and 'W'
		variable p: std_logic_vector(7 downto 0); -- Pixel taken from the reader
		variable same: boolean; -- It is unchanged since the previous frame sent
	begin
		if (rst_i = '1') then
			dbg_state <= DBG_IDLE;
			cmd <= (others => '0');
			args <= (others => '0');
			nargs <= 0;
			argi <= 0;
			word <= (others => '0');
			nsend <= 0;
			addr <= (others => '0');
			len <= (others => '0');
			data <= (others => '0');
			ctrl <= CTRL_INIT;
			timer <= 0;
			rx_count <= (others => '0');
			tx_count <= (others => '0');
			stream_on <= '0';
			key <= '0';
			fkey <= '0';
			frame_go <= '0';
			front_seen <= '0';
			frame_due <= '0';
			frame_num <= (others => '0');
			vbytes <= (others => '0');
			vcount <= 0;
			vlast <= '0';
			pos <= (others => '0');
			run_skip <= '0';
			run_val <= (others => '0');
			run_h2 <= (others => '0');
			run_len <= (others => '0');
			sum <= (others => '0');
		elsif rising_edge(clk_i) then
			frame_go <= '0';
			if (rx_valid = '1') then
				rx_count <= rx_count + 1;
			end if;
			if ((tx_ready = '1') and (tx_valid = '1')) then
				tx_count <= tx_count + 1;
			end if;

			case dbg_state is
				when DBG_IDLE =>
					-- Commands first, so a reply never waits more than one frame
					timer <= 0;
					if (rx_avail = '1') then
						cmd <= rx_byte;
						argi <= 0;
						case rx_byte is
							when x"45" | x"52" | x"56" => -- 'E', 'R', 'V'
								nargs <= 1;
								dbg_state <= DBG_ARGS;
							when x"57" => -- 'W'
								nargs <= 5;
								dbg_state <= DBG_ARGS;
							when x"4D" | x"53" => -- 'M', 'S'
								nargs <= 6;
								dbg_state <= DBG_ARGS;
							when others => -- 'P' and unknown commands need no arguments
								dbg_state <= DBG_EXEC;
						end case;
					elsif ((stream_on = '1') and (frame_due = '1')) then
						-- Header, first byte in 7:0: 'F', frame number, pixel
						-- count, flags, tint, palette count
						vbytes <= pal_count_i & "000000" & view_i(1 downto 0) &
							'0' & view_i(4 downto 2) & '0' & (not key) & view_i(5) & '1' &
							std_logic_vector(to_unsigned(FRAME_PIXELS, 24)) &
							std_logic_vector(frame_num) & x"46";
						vcount <= 9;
						vlast <= '0';
						fkey <= key;
						key <= '0';
						frame_go <= '1';
						frame_due <= '0'; -- A front change from here on asks for the next frame
						pos <= (others => '0');
						run_len <= (others => '0');
						sum <= (others => '0');
						dbg_state <= DBG_V_HEAD;
					end if;

				when DBG_ARGS =>
					-- Each byte restarts the timeout; none for TIMEOUT_CYCLES drops the command
					if (rx_avail = '1') then
						timer <= 0;
						args(8 * argi + 7 downto 8 * argi) <= rx_byte;
						argi <= argi + 1;
						if (nargs = 1) then
							dbg_state <= DBG_EXEC;
						end if;
						nargs <= nargs - 1;
					elsif (timer = TIMEOUT_CYCLES) then
						dbg_state <= DBG_IDLE;
					else
						timer <= timer + 1;
					end if;

				when DBG_EXEC =>
					-- Arguments: register n in byte 0 (W value in bytes 1..4); M and S
					-- take address in bytes 0..2 and length in bytes 3..5
					n := to_integer(unsigned(args(7 downto 0)));
					nsend <= 1;
					dbg_state <= DBG_SEND;
					addr <= unsigned(args(18 downto 0));
					len <= unsigned(args(47 downto 24)) - 1;
					case cmd is
						when x"50" => -- 'P'
							word <= x"0000004B"; -- 'K'
						when x"45" => -- 'E'
							word <= x"000000" & args(7 downto 0);
						when x"52" => -- 'R': status words, control words, else 0
							if (n < 32) then
								word <= status_i(32 * n + 31 downto 32 * n);
							elsif (n < 40) then
								word <= ctrl(32 * (n - 32) + 31 downto 32 * (n - 32));
							else
								word <= x"00000000";
							end if;
							nsend <= 4;
						when x"57" => -- 'W'
							if ((n >= 32) and (n < 40)) then
								ctrl(32 * (n - 32) + 31 downto 32 * (n - 32)) <= args(39 downto 8);
							end if;
							word <= x"0000004B";
						when x"4D" => -- 'M'
							dbg_state <= DBG_MREAD_REQ;
						when x"53" => -- 'S'
							timer <= 0;
							dbg_state <= DBG_SWRITE_DATA;
						when x"56" => -- 'V': on sends a key frame at once
							stream_on <= args(0);
							frame_due <= args(0);
							key <= args(0);
							word <= x"0000004B";
						when others =>
							word <= x"0000003F"; -- '?'
					end case;

				when DBG_SEND =>
					if (tx_ready = '1') then
						word <= x"00" & word(31 downto 8);
						if (nsend = 1) then
							dbg_state <= DBG_IDLE;
						end if;
						nsend <= nsend - 1;
					end if;

				when DBG_MREAD_REQ =>
					if (m_gnt_i = '1') then
						dbg_state <= DBG_MREAD_WAIT;
					end if;

				when DBG_MREAD_WAIT =>
					if (m_rvalid_i = '1') then
						data <= m_rdata_i;
						dbg_state <= DBG_MREAD_SEND;
					end if;

				when DBG_MREAD_SEND =>
					if (tx_ready = '1') then
						addr <= addr + 1;
						len <= len - 1;
						if (len = 0) then
							dbg_state <= DBG_IDLE;
						else
							dbg_state <= DBG_MREAD_REQ;
						end if;
					end if;

				when DBG_SWRITE_DATA =>
					-- Same timeout as DBG_ARGS
					if (rx_avail = '1') then
						timer <= 0;
						data <= rx_byte;
						dbg_state <= DBG_SWRITE_REQ;
					elsif (timer = TIMEOUT_CYCLES) then
						dbg_state <= DBG_IDLE;
					else
						timer <= timer + 1;
					end if;

				when DBG_SWRITE_REQ =>
					if (m_gnt_i = '1') then
						addr <= addr + 1;
						len <= len - 1;
						timer <= 0;
						if (len = 0) then
							word <= x"0000004B";
							nsend <= 1;
							dbg_state <= DBG_SEND;
						else
							dbg_state <= DBG_SWRITE_DATA;
						end if;
					end if;

				when DBG_V_HEAD =>
					if (tx_ready = '1') then
						vbytes <= x"00" & vbytes(71 downto 8);
						if (vcount = 1) then
							dbg_state <= DBG_V_NEXT;
						end if;
						vcount <= vcount - 1;
					end if;

				when DBG_V_NEXT =>
					if (pos = FRAME_PIXELS) then
						-- Every pixel taken: send the open run, then the sum
						vbytes <= run_bytes(run_skip, run_val, run_h2, run_len);
						vcount <= run_count(run_skip, run_val, run_h2, run_len);
						vlast <= '1';
						dbg_state <= DBG_V_EMIT;
					elsif (pix_avail = '1') then
						p := pix_out(8 downto 1);
						same := (pix_out(0) = '0');
						sum <= sum + unsigned(p);
						pos <= pos + 1;
						if ((run_len /= 0) and (run_skip = '0') and (p = run_val) and (run_len < MAX_RUN)) then
							-- Same value as the open value run (changed or not: the PC
							-- gets the same pixel either way)
							run_len <= run_len + 1;
						elsif ((run_len /= 0) and (run_skip = '1') and same and (run_len < MAX_RUN)) then
							if (run_len = 1) then
								run_h2 <= p;
							end if;
							run_len <= run_len + 1;
						else
							-- The open run ends: send it; this pixel starts the next
							if (run_len /= 0) then
								vbytes <= run_bytes(run_skip, run_val, run_h2, run_len);
								vcount <= run_count(run_skip, run_val, run_h2, run_len);
								dbg_state <= DBG_V_EMIT;
							end if;
							if (same) then
								run_skip <= '1';
							else
								run_skip <= '0';
							end if;
							run_val <= p;
							run_len <= to_unsigned(1, 8);
						end if;
					end if;

				when DBG_V_EMIT =>
					if (tx_ready = '1') then
						vbytes <= x"00" & vbytes(71 downto 8);
						if (vcount = 1) then
							if (vlast = '1') then
								vbytes <= x"00000000000000" & std_logic_vector(sum);
								vcount <= 2;
								dbg_state <= DBG_V_TAIL;
							else
								dbg_state <= DBG_V_NEXT;
							end if;
						else
							vcount <= vcount - 1;
						end if;
					end if;

				when DBG_V_TAIL =>
					if (tx_ready = '1') then
						vbytes <= x"00" & vbytes(71 downto 8);
						if (vcount = 1) then
							dbg_state <= DBG_V_DONE;
						end if;
						vcount <= vcount - 1;
					end if;

				when DBG_V_DONE =>
					-- The SRAM port is the reader's until its last shadow write
					if (rd_busy = '0') then
						dbg_state <= DBG_IDLE;
					end if;

				when others =>
					null;
			end case;

			-- A front buffer change is a new frame to stream (last, so it wins
			-- over the clear when a frame starts)
			front_seen <= front_i;
			if (front_i /= front_seen) then
				frame_num <= frame_num + 1;
				frame_due <= '1';
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- Pixel reader: front and shadow reads into pix_fifo, shadow writes
	-- through write_queue. Read data returns in request order.
	------------------------------------------------------------------
	process(clk_i, rst_i)
		variable granted_read: boolean;
		variable returned: boolean;
		variable changed: std_logic;
	begin
		if (rst_i = '1') then
			rd_busy <= '0';
			rd_pos <= (others => '0');
			rd_saddr <= (others => '0');
			rd_half <= '0';
			rd_ret_pos <= (others => '0');
			rd_ret_saddr <= (others => '0');
			rd_ret_half <= '0';
			rd_inflight <= 0;
			rd_p <= (others => '0');
			pix_push <= '0';
			pix_in <= (others => '0');
			wq_push <= '0';
			wq_in <= (others => '0');
		elsif rising_edge(clk_i) then
			pix_push <= '0';
			wq_push <= '0';
			granted_read := (rd_gnt = '1') and (rd_we = '0');
			returned := (rd_rvalid = '1');
			if (frame_go = '1') then
				rd_busy <= '1';
				rd_pos <= (others => '0');
				rd_saddr <= to_unsigned(SHADOW0_BASE, 19);
				rd_half <= '0';
				rd_ret_pos <= (others => '0');
				rd_ret_saddr <= to_unsigned(SHADOW0_BASE, 19);
				rd_ret_half <= '0';
			else
				if (granted_read) then
					if (rd_half = '1') then
						rd_pos <= rd_pos + 1;
						rd_saddr <= next_saddr(rd_saddr, rd_pos);
					end if;
					rd_half <= not rd_half;
				end if;
				if (returned) then
					if (rd_ret_half = '0') then
						rd_p <= m_rdata_i;
					else
						-- Pair complete: front value rd_p, shadow value m_rdata_i
						changed := fkey;
						if (m_rdata_i /= rd_p) then
							changed := '1';
						end if;
						pix_in <= rd_p & changed;
						pix_push <= '1';
						if (changed = '1') then
							wq_in <= std_logic_vector(rd_ret_saddr) & rd_p;
							wq_push <= '1';
						end if;
						rd_ret_pos <= rd_ret_pos + 1;
						rd_ret_saddr <= next_saddr(rd_ret_saddr, rd_ret_pos);
					end if;
					rd_ret_half <= not rd_ret_half;
				end if;
				-- Done when every pixel is requested and back and every shadow write is out
				if ((rd_busy = '1') and (rd_pos = FRAME_PIXELS) and (rd_inflight = 0) and
						(wq_push = '0') and (wq_valid = '0') and (unsigned(wq_level) = 0)) then
					rd_busy <= '0';
				end if;
			end if;
			if (granted_read and (not returned)) then
				rd_inflight <= rd_inflight + 1;
			elsif (returned and (not granted_read)) then
				rd_inflight <= rd_inflight - 1;
			end if;
		end if;
	end process;

	-- Reader request: a queued shadow write first, else the next read while
	-- there is room for its data and its possible write
	rd_can_read <= '1' when ((rd_busy = '1') and (rd_pos /= FRAME_PIXELS) and
		(rd_inflight < MAX_INFLIGHT) and (unsigned(pix_level) < PIX_LIMIT) and
		(unsigned(wq_level) < WQ_LIMIT) and (wq_push = '0')) else '0';
	rd_we <= wq_valid;
	rd_req <= wq_valid or rd_can_read;
	rd_addr <= unsigned(wq_out(26 downto 8)) when (wq_valid = '1') else
		rd_saddr when (rd_half = '1') else
		to_unsigned(FB1_BASE, 19) + resize(rd_pos, 19) when (front_i = '1') else
		to_unsigned(FB0_BASE, 19) + resize(rd_pos, 19);
	rd_gnt <= m_gnt_i when (main_port = '0') else '0';
	rd_rvalid <= m_rvalid_i when (rd_inflight /= 0) else '0';

	-- SRAM port: the command side in its SRAM states, else the reader
	main_port <= '1' when ((dbg_state = DBG_MREAD_REQ) or (dbg_state = DBG_SWRITE_REQ)) else '0';
	m_req_o <= '1' when (main_port = '1') else rd_req;
	m_we_o <= '1' when (dbg_state = DBG_SWRITE_REQ) else
		'0' when (main_port = '1') else
		rd_we;
	m_addr_o <= std_logic_vector(addr) when (main_port = '1') else std_logic_vector(rd_addr);
	m_wdata_o <= data when (main_port = '1') else wq_out(7 downto 0);

	-- Outputs
	rx_pop <= rx_avail when ((dbg_state = DBG_IDLE) or (dbg_state = DBG_ARGS) or
		(dbg_state = DBG_SWRITE_DATA)) else '0';
	pix_pop <= pix_avail when ((dbg_state = DBG_V_NEXT) and (pos /= FRAME_PIXELS)) else '0';
	tx_data <= word(7 downto 0) when (dbg_state = DBG_SEND) else
		data when (dbg_state = DBG_MREAD_SEND) else
		vbytes(7 downto 0);
	tx_valid <= '1' when ((dbg_state = DBG_SEND) or (dbg_state = DBG_MREAD_SEND) or
		(dbg_state = DBG_V_HEAD) or (dbg_state = DBG_V_EMIT) or (dbg_state = DBG_V_TAIL)) else '0';
	ctrl_o <= ctrl;
	rx_count_o <= std_logic_vector(rx_count);
	tx_count_o <= std_logic_vector(tx_count);
end arch;

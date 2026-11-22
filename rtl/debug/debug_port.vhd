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
--                   'V' b                    stream on (b bit 0 = 1)
--                                            or off    -> 'K'
--                   anything else                      -> '?'
--                 Registers 0..31: status_i words (read only, as the
--                 bring-up page); 32..39: ctrl_o words (read/write, reset
--                 to CTRL_INIT); others read 0. Length 0 means 2^24.
--                 SRAM goes through an arbiter master port one byte at a
--                 time (the UART is the bottleneck). A command with no
--                 byte for TIMEOUT_MS is dropped so the port never hangs.
--                 Frame stream: while on, a frame is sent at once and
--                 then after every front buffer change (front_i toggles),
--                 between commands:
--                   'F', frame number (2 bytes, counts front_i changes),
--                   pixel count (3 bytes, FRAME_PIXELS), flags (bit 0
--                   RLE = 1, bit 1 blank, bits 6:4 pattern), tint (1:0),
--                   palette change count, RLE data, 16-bit sum of all
--                   pixels (2 bytes).
--                 RLE: a byte other than ESC (0xFF) is one pixel; ESC n v
--                 is n pixels of value v (n = 1..255). Runs of 3 or more,
--                 and every ESC-valued pixel, use the 3-byte form. 255 is
--                 the sprite transparent index, so it is rare in a frame.
--                 Each pixel is read from the buffer that is front at that
--                 moment, so it always comes from a finished frame (the
--                 picture can tear, never show a half-drawn frame).
--                 Swaps during a frame are counted, not waited for: the
--                 game never stalls, frames are skipped instead.
--                 Bytes received while a frame is going out wait in a
--                 31-byte FIFO; their replies follow the frame.
--                 One clocked state machine; UART and SRAM handshake
--                 outputs are decoded from the state.
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
-- Additional Comments:
--                 Stream bytes per frame: 11 + RLE data (at most
--                 3 * FRAME_PIXELS, typically far fewer).
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;

entity debug_port is
	generic(
		CLK_HZ: natural := 100_000_000; -- System clock
		BAUD: natural := 4_000_000; -- UART rate (CLK_HZ / BAUD at least 16)
		TIMEOUT_MS: natural := 100; -- Drop a half-received command after this
		CTRL_INIT: std_logic_vector(8 * 32 - 1 downto 0) := (others => '0'); -- Control reset values
		FRAME_PIXELS: positive := 76_800 -- Pixels per streamed frame (320 x 240)
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
	constant ESC: std_logic_vector(7 downto 0) := x"FF"; -- RLE escape byte
	constant MAX_RUN: natural := 255; -- Longest run one ESC n v holds

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
		DBG_V_NEXT, -- Stream: read the next pixel, or flush the last run
		DBG_V_REQ, -- Stream: request one pixel from the front buffer
		DBG_V_WAIT, -- Stream: wait for it, extend the run or end it
		DBG_V_EMIT, -- Stream: send the 1 to 3 bytes of a finished run
		DBG_V_TAIL -- Stream: send the 2-byte pixel sum
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

	-- Frame stream
	signal stream_on: std_logic := '0';
	signal front_seen: std_logic := '0'; -- front_i one clock ago (change detect)
	signal frame_due: std_logic := '0'; -- A frame should go out (new front, or stream just on)
	signal frame_num: unsigned(15 downto 0) := (others => '0'); -- Front buffer changes so far
	signal vbytes: std_logic_vector(71 downto 0) := (others => '0'); -- Stream bytes to send, low first
	signal vcount: natural range 0 to 9 := 0; -- Stream bytes still to send
	signal vlast: std_logic := '0'; -- The run in vbytes is the frame's last
	signal pos: unsigned(16 downto 0) := (others => '0'); -- Pixels read so far
	signal run_val: std_logic_vector(7 downto 0) := (others => '0'); -- Value of the open run
	signal run_len: unsigned(7 downto 0) := (others => '0'); -- Its length (0 = none yet)
	signal sum: unsigned(15 downto 0) := (others => '0'); -- Pixel sum, mod 2^16

	-- Bytes of a finished run, first byte in 7:0: ESC n v for a run of 3 or
	-- more or an ESC-valued pixel, else the value once or twice. Pair with
	-- run_bytes_n for how many to send.
	function run_bytes(v: std_logic_vector(7 downto 0); n: unsigned(7 downto 0))
		return std_logic_vector is
	begin
		if ((n >= 3) or (v = ESC)) then
			return x"000000000000" & v & std_logic_vector(n) & ESC;
		end if;
		return x"00000000000000" & v & v;
	end function;

	function run_bytes_n(v: std_logic_vector(7 downto 0); n: unsigned(7 downto 0))
		return natural is
	begin
		if ((n >= 3) or (v = ESC)) then
			return 3;
		end if;
		return to_integer(n);
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

	process(clk_i, rst_i)
		variable n: natural range 0 to 255; -- Register number of 'R' and 'W'
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
			front_seen <= '0';
			frame_due <= '0';
			frame_num <= (others => '0');
			vbytes <= (others => '0');
			vcount <= 0;
			vlast <= '0';
			pos <= (others => '0');
			run_val <= (others => '0');
			run_len <= (others => '0');
			sum <= (others => '0');
		elsif rising_edge(clk_i) then
			if (rx_valid = '1') then
				rx_count <= rx_count + 1;
			end if;
			-- tx_valid is high in these states, so tx_ready here means a byte was taken
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
							'0' & view_i(4 downto 2) & "00" & view_i(5) & '1' &
							std_logic_vector(to_unsigned(FRAME_PIXELS, 24)) &
							std_logic_vector(frame_num) & x"46";
						vcount <= 9;
						vlast <= '0';
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
						when x"56" => -- 'V': the first frame goes out at once
							stream_on <= args(0);
							frame_due <= args(0);
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
						-- Every pixel read: send the open run, then the sum
						vbytes <= run_bytes(run_val, run_len);
						vcount <= run_bytes_n(run_val, run_len);
						vlast <= '1';
						dbg_state <= DBG_V_EMIT;
					else
						-- Address from the buffer that is front right now
						if (front_i = '1') then
							addr <= to_unsigned(FB1_BASE, 19) + resize(pos, 19);
						else
							addr <= to_unsigned(FB0_BASE, 19) + resize(pos, 19);
						end if;
						dbg_state <= DBG_V_REQ;
					end if;

				when DBG_V_REQ =>
					if (m_gnt_i = '1') then
						dbg_state <= DBG_V_WAIT;
					end if;

				when DBG_V_WAIT =>
					if (m_rvalid_i = '1') then
						sum <= sum + unsigned(m_rdata_i);
						pos <= pos + 1;
						run_val <= m_rdata_i;
						if ((run_len /= 0) and ((m_rdata_i /= run_val) or (run_len = MAX_RUN))) then
							-- The open run ends: send it, this pixel starts the next
							vbytes <= run_bytes(run_val, run_len);
							vcount <= run_bytes_n(run_val, run_len);
							run_len <= to_unsigned(1, 8);
							dbg_state <= DBG_V_EMIT;
						else
							run_len <= run_len + 1;
							dbg_state <= DBG_V_NEXT;
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
							dbg_state <= DBG_IDLE;
						end if;
						vcount <= vcount - 1;
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

	-- Outputs
	rx_pop <= rx_avail when ((dbg_state = DBG_IDLE) or (dbg_state = DBG_ARGS) or
		(dbg_state = DBG_SWRITE_DATA)) else '0';
	tx_data <= word(7 downto 0) when (dbg_state = DBG_SEND) else
		data when (dbg_state = DBG_MREAD_SEND) else
		vbytes(7 downto 0);
	tx_valid <= '1' when ((dbg_state = DBG_SEND) or (dbg_state = DBG_MREAD_SEND) or
		(dbg_state = DBG_V_HEAD) or (dbg_state = DBG_V_EMIT) or (dbg_state = DBG_V_TAIL)) else '0';
	m_req_o <= '1' when ((dbg_state = DBG_MREAD_REQ) or (dbg_state = DBG_SWRITE_REQ) or
		(dbg_state = DBG_V_REQ)) else '0';
	m_we_o <= '1' when (dbg_state = DBG_SWRITE_REQ) else '0';
	m_addr_o <= std_logic_vector(addr);
	m_wdata_o <= data;
	ctrl_o <= ctrl;
	rx_count_o <= std_logic_vector(rx_count);
	tx_count_o <= std_logic_vector(tx_count);
end arch;

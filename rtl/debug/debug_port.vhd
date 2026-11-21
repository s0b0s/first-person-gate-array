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
--                 (PC side: tools/uart/debug_uart.py). 8N1 at
--                 BAUD. Multi-byte numbers are little endian.
--                   'P'                      ping      -> 'K'
--                   'E' b                    echo      -> b
--                   'R' n                    read reg  -> 4 bytes
--                   'W' n d0 d1 d2 d3        write reg -> 'K'
--                   'M' a0 a1 a2 l0 l1 l2    read SRAM -> l bytes
--                   'S' a0 a1 a2 l0 l1 l2    write SRAM, then l data
--                                            bytes     -> 'K'
--                   anything else                      -> '?'
--                 Registers 0..31 are the status words on status_i (read
--                 only, the same words as the bring-up page); 32..39 are
--                 control words on ctrl_o (read/write, reset to
--                 CTRL_INIT); others read as 0. A length of 0 means 2^24.
--                 SRAM access goes through an arbiter master port, one
--                 byte at a time (the UART is the bottleneck: 10 us per
--                 byte at 1 Mbaud, an SRAM access is 20 ns).
--                 A command that stops half-way (no byte for TIMEOUT_MS)
--                 is dropped so the port never hangs.
--                 Coding: one clocked process for the state machine and
--                 its registers; the UART and SRAM
--                 handshake outputs are decoded from the state.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 uart_rx, uart_tx
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - Plain signals instead of records; one-process state machine
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;

entity debug_port is
	generic(
		CLK_HZ: natural := 100_000_000; -- System clock
		BAUD: natural := 1_000_000; -- UART rate
		TIMEOUT_MS: natural := 100; -- Drop a half-received command after this
		CTRL_INIT: std_logic_vector(8 * 32 - 1 downto 0) := (others => '0') -- Control reset values
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		rx_i: in std_logic; -- UART from the PC (raw pin)
		tx_o: out std_logic; -- UART to the PC
		status_i: in std_logic_vector(32 * 32 - 1 downto 0); -- Registers 0..31
		ctrl_o: out std_logic_vector(8 * 32 - 1 downto 0); -- Registers 32..39
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

	constant TIMEOUT_CYCLES: natural := (CLK_HZ / 1000) * TIMEOUT_MS;

	type dbg_state_type is (
		DBG_IDLE, -- Wait for a command byte
		DBG_ARGS, -- Collect argument bytes
		DBG_EXEC, -- Act on a complete command
		DBG_SEND, -- Send 1 to 4 bytes of word, low byte first
		DBG_MREAD_REQ, -- SRAM read: request one byte
		DBG_MREAD_WAIT, -- SRAM read: wait for the data
		DBG_MREAD_SEND, -- SRAM read: send it
		DBG_SWRITE_DATA, -- SRAM write: wait for a data byte
		DBG_SWRITE_REQ -- SRAM write: write it
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
		elsif rising_edge(clk_i) then
			if (rx_valid = '1') then
				rx_count <= rx_count + 1;
			end if;
			-- tx_valid is high in these two states, so tx_ready here means a byte was taken
			if ((tx_ready = '1') and ((dbg_state = DBG_SEND) or (dbg_state = DBG_MREAD_SEND))) then
				tx_count <= tx_count + 1;
			end if;

			case dbg_state is
				when DBG_IDLE =>
					timer <= 0;
					if (rx_valid = '1') then
						cmd <= rx_data;
						argi <= 0;
						case rx_data is
							when x"45" | x"52" => -- 'E', 'R'
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
					end if;

				when DBG_ARGS =>
					-- Each byte restarts the timeout; none for TIMEOUT_CYCLES drops the command
					if (rx_valid = '1') then
						timer <= 0;
						args(8 * argi + 7 downto 8 * argi) <= rx_data;
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
					if (rx_valid = '1') then
						timer <= 0;
						data <= rx_data;
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

				when others =>
					null;
			end case;
		end if;
	end process;

	-- Outputs
	tx_data <= word(7 downto 0) when (dbg_state = DBG_SEND) else data;
	tx_valid <= '1' when ((dbg_state = DBG_SEND) or (dbg_state = DBG_MREAD_SEND)) else '0';
	m_req_o <= '1' when ((dbg_state = DBG_MREAD_REQ) or (dbg_state = DBG_SWRITE_REQ)) else '0';
	m_we_o <= '1' when (dbg_state = DBG_SWRITE_REQ) else '0';
	m_addr_o <= std_logic_vector(addr);
	m_wdata_o <= data;
	ctrl_o <= ctrl;
	rx_count_o <= std_logic_vector(rx_count);
	tx_count_o <= std_logic_vector(tx_count);
end arch;

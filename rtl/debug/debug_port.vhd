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
-- Description:    UART debug port, stage 0 command set
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
--                 Coding: two-segment style with all registers in one
--                 record r; the combinational process computes r_next.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 uart_rx, uart_tx
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

	type state_t is (
		S_IDLE, -- Wait for a command byte
		S_ARGS, -- Collect argument bytes
		S_EXEC, -- Act on a complete command
		S_SEND, -- Send 1 to 4 bytes of r.word, low byte first
		S_MREAD_REQ, -- SRAM read: request one byte
		S_MREAD_WAIT, -- SRAM read: wait for the data
		S_MREAD_SEND, -- SRAM read: send it
		S_SWRITE_DATA, -- SRAM write: wait for a data byte
		S_SWRITE_REQ -- SRAM write: write it
	);

	type regs_t is record
		state: state_t;
		cmd: std_logic_vector(7 downto 0);
		args: std_logic_vector(47 downto 0); -- Argument bytes, first byte in 7:0
		nargs: natural range 0 to 6; -- Arguments still to receive
		argi: natural range 0 to 6; -- Next argument byte position
		word: std_logic_vector(31 downto 0); -- Bytes to send
		nsend: natural range 0 to 4; -- Bytes still to send
		addr: unsigned(18 downto 0);
		len: unsigned(23 downto 0); -- Bytes left, minus 1
		data: std_logic_vector(7 downto 0);
		ctrl: std_logic_vector(8 * 32 - 1 downto 0);
		timer: natural range 0 to TIMEOUT_CYCLES;
		rx_count: unsigned(15 downto 0);
		tx_count: unsigned(15 downto 0);
	end record;

	constant REGS_INIT: regs_t := (
		state => S_IDLE,
		cmd => (others => '0'),
		args => (others => '0'),
		nargs => 0,
		argi => 0,
		word => (others => '0'),
		nsend => 0,
		addr => (others => '0'),
		len => (others => '0'),
		data => (others => '0'),
		ctrl => CTRL_INIT,
		timer => 0,
		rx_count => (others => '0'),
		tx_count => (others => '0')
	);

	signal r: regs_t := REGS_INIT;
	signal r_next: regs_t;
	signal rx_data: std_logic_vector(7 downto 0);
	signal rx_valid: std_logic;
	signal tx_data: std_logic_vector(7 downto 0);
	signal tx_valid: std_logic;
	signal tx_ready: std_logic;

	-- Register file read: status words, control words, else 0
	function read_reg(n: natural; status: std_logic_vector; ctrl: std_logic_vector)
		return std_logic_vector is
	begin
		if (n < 32) then
			return status(32 * n + 31 downto 32 * n);
		elsif (n < 40) then
			return ctrl(32 * (n - 32) + 31 downto 32 * (n - 32));
		else
			return x"00000000";
		end if;
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

	------------------------------------------------------------------
	-- Next state
	------------------------------------------------------------------
	process(r, rx_valid, rx_data, tx_ready, m_gnt_i, m_rvalid_i, m_rdata_i, status_i)
		variable v: regs_t;
		variable n: natural range 0 to 255;
	begin
		v := r;
		if (rx_valid = '1') then
			v.rx_count := r.rx_count + 1;
		end if;
		-- tx_valid is high in these two states, so tx_ready here means a byte was taken
		if ((tx_ready = '1') and ((r.state = S_SEND) or (r.state = S_MREAD_SEND))) then
			v.tx_count := r.tx_count + 1;
		end if;
		-- Timeout while waiting for argument or data bytes
		if ((r.state = S_ARGS) or (r.state = S_SWRITE_DATA)) then
			if (rx_valid = '1') then
				v.timer := 0;
			elsif (r.timer = TIMEOUT_CYCLES) then
				v.state := S_IDLE;
			else
				v.timer := r.timer + 1;
			end if;
		end if;

		case r.state is
			when S_IDLE =>
				v.timer := 0;
				if (rx_valid = '1') then
					v.cmd := rx_data;
					v.argi := 0;
					case rx_data is
						when x"45" | x"52" => -- 'E', 'R'
							v.nargs := 1;
							v.state := S_ARGS;
						when x"57" => -- 'W'
							v.nargs := 5;
							v.state := S_ARGS;
						when x"4D" | x"53" => -- 'M', 'S'
							v.nargs := 6;
							v.state := S_ARGS;
						when others => -- 'P' and unknown commands need no arguments
							v.state := S_EXEC;
					end case;
				end if;

			when S_ARGS =>
				if (rx_valid = '1') then
					v.args(8 * r.argi + 7 downto 8 * r.argi) := rx_data;
					v.argi := r.argi + 1;
					if (r.nargs = 1) then
						v.state := S_EXEC;
					end if;
					v.nargs := r.nargs - 1;
				end if;

			when S_EXEC =>
				-- Arguments: register n in byte 0 (W value in bytes 1..4); M and S
				-- take address in bytes 0..2 and length in bytes 3..5
				n := to_integer(unsigned(r.args(7 downto 0)));
				v.nsend := 1;
				v.state := S_SEND;
				v.addr := unsigned(r.args(18 downto 0));
				v.len := unsigned(r.args(47 downto 24)) - 1;
				case r.cmd is
					when x"50" => -- 'P'
						v.word := x"0000004B"; -- 'K'
					when x"45" => -- 'E'
						v.word := x"000000" & r.args(7 downto 0);
					when x"52" => -- 'R'
						v.word := read_reg(n, status_i, r.ctrl);
						v.nsend := 4;
					when x"57" => -- 'W'
						if ((n >= 32) and (n < 40)) then
							v.ctrl(32 * (n - 32) + 31 downto 32 * (n - 32)) := r.args(39 downto 8);
						end if;
						v.word := x"0000004B";
					when x"4D" => -- 'M'
						v.state := S_MREAD_REQ;
					when x"53" => -- 'S'
						v.timer := 0;
						v.state := S_SWRITE_DATA;
					when others =>
						v.word := x"0000003F"; -- '?'
				end case;

			when S_SEND =>
				if (tx_ready = '1') then
					v.word := x"00" & r.word(31 downto 8);
					if (r.nsend = 1) then
						v.state := S_IDLE;
					end if;
					v.nsend := r.nsend - 1;
				end if;

			when S_MREAD_REQ =>
				if (m_gnt_i = '1') then
					v.state := S_MREAD_WAIT;
				end if;

			when S_MREAD_WAIT =>
				if (m_rvalid_i = '1') then
					v.data := m_rdata_i;
					v.state := S_MREAD_SEND;
				end if;

			when S_MREAD_SEND =>
				if (tx_ready = '1') then
					v.addr := r.addr + 1;
					v.len := r.len - 1;
					if (r.len = 0) then
						v.state := S_IDLE;
					else
						v.state := S_MREAD_REQ;
					end if;
				end if;

			when S_SWRITE_DATA =>
				if (rx_valid = '1') then
					v.data := rx_data;
					v.state := S_SWRITE_REQ;
				end if;

			when S_SWRITE_REQ =>
				if (m_gnt_i = '1') then
					v.addr := r.addr + 1;
					v.len := r.len - 1;
					v.timer := 0;
					if (r.len = 0) then
						v.word := x"0000004B";
						v.nsend := 1;
						v.state := S_SEND;
					else
						v.state := S_SWRITE_DATA;
					end if;
				end if;
		end case;
		r_next <= v;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			r <= REGS_INIT;
		elsif rising_edge(clk_i) then
			r <= r_next;
		end if;
	end process;

	-- Outputs
	tx_data <= r.word(7 downto 0) when (r.state = S_SEND) else r.data;
	tx_valid <= '1' when ((r.state = S_SEND) or (r.state = S_MREAD_SEND)) else '0';
	m_req_o <= '1' when ((r.state = S_MREAD_REQ) or (r.state = S_SWRITE_REQ)) else '0';
	m_we_o <= '1' when (r.state = S_SWRITE_REQ) else '0';
	m_addr_o <= std_logic_vector(r.addr);
	m_wdata_o <= r.data;
	ctrl_o <= r.ctrl;
	rx_count_o <= std_logic_vector(r.rx_count);
	tx_count_o <= std_logic_vector(r.tx_count);
end arch;

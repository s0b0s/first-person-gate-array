--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    UART Receiver
-- Module Name:    uart_rx
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    UART receiver, 8N1 (8 data bits, no parity, 1 stop bit),
--                 LSB first.
--                 The line goes through a 3-stage synchronizer that powers
--                 up and resets to '1' (idle), so configuration does not
--                 look like a start bit. A falling edge to '0' starts a
--                 frame; the start bit is checked again half a bit later
--                 (a shorter glitch is ignored), then every data bit and
--                 the stop bit are sampled one bit period apart, in the
--                 middle of each bit. Counting system clocks per bit is
--                 CLK_HZ / BAUD times oversampling (100 at 1 Mbaud), well
--                 above the 10x the course asks for, and keeps the sample
--                 point within half a clock of the bit center.
--                 A low stop bit gives frame_err_o (no valid_o); the
--                 receiver then waits for the line to return high before
--                 it looks for a new start bit (a break holds it there).
--                 Clock domain: clk_i. Latency: valid_o one clock after
--                 the middle of the stop bit (plus 3 synchronizer clocks).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std,
--                 synchronizer
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 CLK_HZ / BAUD should be at least 16. The bit period is
--                 rounded to whole clocks; the error this adds (0.5% at
--                 115,200 baud from 100 MHz) is far inside the +/-5%
--                 tolerance of 8N1.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity uart_rx is
	generic(
		CLK_HZ: natural := 100_000_000; -- Clock frequency
		BAUD: natural := 1_000_000 -- Bit rate
	);
	port(
		clk_i: in std_logic; -- Clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		rx_i: in std_logic; -- Serial input (raw pin)
		data_o: out std_logic_vector(7 downto 0); -- Received byte
		valid_o: out std_logic; -- One-cycle pulse: data_o is new
		frame_err_o: out std_logic -- One-cycle pulse: stop bit was low
	);
end uart_rx;

architecture arch of uart_rx is
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
	-- Bit period rounded to the nearest clock
	constant BIT_CYCLES: natural := (CLK_HZ + BAUD / 2) / BAUD;
	constant HALF_CYCLES: natural := BIT_CYCLES / 2;

	type state_t is (S_IDLE, S_START, S_DATA, S_STOP, S_WAIT_IDLE);
	signal state: state_t := S_IDLE;
	signal state_next: state_t;
	signal count: natural range 0 to BIT_CYCLES - 1 := 0;
	signal count_next: natural range 0 to BIT_CYCLES - 1;
	signal bitn: natural range 0 to 7 := 0;
	signal bitn_next: natural range 0 to 7;
	signal shreg: std_logic_vector(7 downto 0) := (others => '0');
	signal shreg_next: std_logic_vector(7 downto 0);
	signal valid: std_logic := '0';
	signal valid_next: std_logic;
	signal frame_err: std_logic := '0';
	signal frame_err_next: std_logic;
	signal rx: std_logic;
begin
	sync_rx: synchronizer
		generic map (
			STAGES => 3,
			INIT => '1'
		)
		port map (
			clk_i => clk_i,
			rst_i => rst_i,
			async_i => rx_i,
			sync_o => rx
		);

	-- Next-state logic
	process(state, count, bitn, shreg, rx)
	begin
		state_next <= state;
		count_next <= count;
		bitn_next <= bitn;
		shreg_next <= shreg;
		valid_next <= '0';
		frame_err_next <= '0';
		case state is
			when S_IDLE =>
				-- Line high until now; a '0' is the leading edge of a start bit
				if (rx = '0') then
					state_next <= S_START;
					count_next <= HALF_CYCLES - 1;
				end if;
			when S_START =>
				if (count = 0) then
					if (rx = '0') then
						-- Middle of the start bit: from here on, whole bit periods
						state_next <= S_DATA;
						count_next <= BIT_CYCLES - 1;
						bitn_next <= 0;
					else
						state_next <= S_IDLE; -- Glitch, not a start bit
					end if;
				else
					count_next <= count - 1;
				end if;
			when S_DATA =>
				if (count = 0) then
					-- LSB first: shift in from the top
					shreg_next <= rx & shreg(7 downto 1);
					count_next <= BIT_CYCLES - 1;
					if (bitn = 7) then
						state_next <= S_STOP;
					else
						bitn_next <= bitn + 1;
					end if;
				else
					count_next <= count - 1;
				end if;
			when S_STOP =>
				if (count = 0) then
					if (rx = '1') then
						valid_next <= '1';
						state_next <= S_IDLE;
					else
						frame_err_next <= '1';
						state_next <= S_WAIT_IDLE;
					end if;
				else
					count_next <= count - 1;
				end if;
			when S_WAIT_IDLE =>
				if (rx = '1') then
					state_next <= S_IDLE;
				end if;
			when others =>
				state_next <= S_IDLE;
		end case;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			state <= S_IDLE;
			count <= 0;
			bitn <= 0;
			shreg <= (others => '0');
			valid <= '0';
			frame_err <= '0';
		elsif rising_edge(clk_i) then
			state <= state_next;
			count <= count_next;
			bitn <= bitn_next;
			shreg <= shreg_next;
			valid <= valid_next;
			frame_err <= frame_err_next;
		end if;
	end process;

	data_o <= shreg;
	valid_o <= valid;
	frame_err_o <= frame_err;
end arch;

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
-- Description:    UART receiver, 8N1, LSB first.
--                 The line passes a 3-stage synchronizer that resets to
--                 '1' (idle), so configuration does not look like a start
--                 bit. A falling edge starts a frame; the start bit is
--                 rechecked half a bit later (shorter glitches are
--                 ignored), then data and stop bits are sampled mid-bit,
--                 one bit period apart.
--                 Bit timing as in uart_tx: an accumulator adds
--                 N = BAUD / D each clock and a bit period ends where the
--                 sum would reach P = CLK_HZ / D (D = gcd(CLK_HZ, BAUD)), so
--                 CLK_HZ / BAUD need not be whole (12 Mbaud from 100 MHz:
--                 8.33 clocks). It starts at P / 2 on the falling edge, so
--                 the first tick is mid-start bit; every sample then lands
--                 within one clock of the bit center (the edge is seen up
--                 to one clock late; the synchronizer delays every edge
--                 alike).
--                 A low stop bit gives frame_err_o (no valid_o), then the
--                 receiver waits for the line to go high (a break holds it
--                 there).
--                 Clock domain: clk_i. Latency: valid_o one clock after
--                 mid-stop bit, plus 3 synchronizer clocks.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg,
--                 synchronizer
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - One-process state machine
-- Revision 1.02 - Fractional bit timing (accumulator)
-- Additional Comments:
--                 CLK_HZ / BAUD should be 8 or more (one clock of sampling
--                 error is then at most 1/8 of a bit).
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;

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
	constant N: natural := BAUD / gcd(CLK_HZ, BAUD); -- Accumulator step per clock
	constant P: natural := CLK_HZ / gcd(CLK_HZ, BAUD); -- One bit period in steps

	type rx_state_type is (RX_IDLE, RX_START, RX_DATA, RX_STOP, RX_WAIT);
	signal rx_state: rx_state_type := RX_IDLE;
	signal acc: natural range 0 to P - 1 := 0;
	signal tick: std_logic; -- This clock ends a bit period (the first one: half a bit)
	signal bitn: natural range 0 to 7 := 0;
	signal shreg: std_logic_vector(7 downto 0) := (others => '0');
	signal valid: std_logic := '0';
	signal frame_err: std_logic := '0';
	signal rx: std_logic;
begin
	tick <= '1' when (acc >= P - N) else '0';

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

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			rx_state <= RX_IDLE;
			acc <= 0;
			bitn <= 0;
			shreg <= (others => '0');
			valid <= '0';
			frame_err <= '0';
		elsif rising_edge(clk_i) then
			-- valid and frame_err are one-cycle pulses
			valid <= '0';
			frame_err <= '0';
			if (tick = '1') then
				acc <= acc + N - P;
			else
				acc <= acc + N;
			end if;
			case rx_state is
				when RX_IDLE =>
					-- Line high until now; a '0' is the leading edge of a start bit
					if (rx = '0') then
						acc <= P / 2; -- Half a bit to the middle of the start bit
						rx_state <= RX_START;
					end if;
				when RX_START =>
					if (tick = '1') then
						if (rx = '0') then
							-- Middle of the start bit: from here on, whole bit periods
							bitn <= 0;
							rx_state <= RX_DATA;
						else
							rx_state <= RX_IDLE; -- Glitch, not a start bit
						end if;
					end if;
				when RX_DATA =>
					if (tick = '1') then
						-- LSB first: shift in from the top
						shreg <= rx & shreg(7 downto 1);
						if (bitn = 7) then
							rx_state <= RX_STOP;
						else
							bitn <= bitn + 1;
						end if;
					end if;
				when RX_STOP =>
					if (tick = '1') then
						if (rx = '1') then
							valid <= '1';
							rx_state <= RX_IDLE;
						else
							frame_err <= '1';
							rx_state <= RX_WAIT; -- Wait for the line to go high again
						end if;
					end if;
				when RX_WAIT =>
					if (rx = '1') then
						rx_state <= RX_IDLE;
					end if;
				when others =>
					rx_state <= RX_IDLE;
			end case;
		end if;
	end process;

	data_o <= shreg;
	valid_o <= valid;
	frame_err_o <= frame_err;
end arch;

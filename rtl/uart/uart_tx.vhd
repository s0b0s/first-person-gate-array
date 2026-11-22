--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    UART Transmitter
-- Module Name:    uart_tx
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    UART transmitter, 8N1, LSB first. A byte is taken when
--                 valid_i and ready_o are both '1' and loaded into a
--                 10-bit frame register (stop, data, start) whose bit 0
--                 drives tx_o directly; it shifts right, filling with '1',
--                 once per bit period. ready_o rises in the last clock of
--                 the stop bit, so back-to-back bytes have no idle gap.
--                 Bit timing: CLK_HZ / BAUD need not be whole. With
--                 D = gcd(CLK_HZ, BAUD), N = BAUD / D and P = CLK_HZ / D, an
--                 accumulator adds N each clock; a bit ends in the clock
--                 where the sum would reach P, and P is taken off then, so
--                 bits are a mix of floor(P / N) and one more clocks and
--                 their edges stay within one clock of ideal (12 Mbaud
--                 from 100 MHz: N = 3,
--                 P = 25, bits of 9, 8, 8 clocks). The accumulator
--                 restarts with each byte.
--                 Clock domain: clk_i. Throughput: one byte per 10 bit
--                 periods (rounded up to a whole clock). tx_o falls one
--                 clock after the byte is taken.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - Fractional bit timing (accumulator)
-- Additional Comments:
--                 CLK_HZ / BAUD should be 4 or more.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;

entity uart_tx is
	generic(
		CLK_HZ: natural := 100_000_000; -- Clock frequency
		BAUD: natural := 1_000_000 -- Bit rate
	);
	port(
		clk_i: in std_logic; -- Clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		data_i: in std_logic_vector(7 downto 0); -- Byte to send
		valid_i: in std_logic; -- data_i holds a byte to send
		ready_o: out std_logic; -- Byte taken on a cycle with valid_i = '1'
		tx_o: out std_logic -- Serial output, idle '1'
	);
end uart_tx;

architecture arch of uart_tx is
	constant N: natural := BAUD / gcd(CLK_HZ, BAUD); -- Accumulator step per clock
	constant P: natural := CLK_HZ / gcd(CLK_HZ, BAUD); -- One bit period in steps
	signal frame: std_logic_vector(9 downto 0) := (others => '1');
	signal frame_next: std_logic_vector(9 downto 0);
	signal acc: natural range 0 to P - 1 := 0;
	signal acc_next: natural range 0 to P - 1;
	signal bits_left: natural range 0 to 10 := 0; -- Bit periods still to send
	signal bits_left_next: natural range 0 to 10;
	signal bit_end: std_logic; -- This clock is the last of a bit period
	signal ready: std_logic;
begin
	bit_end <= '1' when (acc >= P - N) else '0';

	-- Free when idle, or in the last clock of the stop bit
	ready <= '1' when ((bits_left = 0) or ((bits_left = 1) and (bit_end = '1'))) else '0';

	process(frame, acc, bits_left, ready, bit_end, valid_i, data_i)
	begin
		frame_next <= frame;
		acc_next <= acc;
		bits_left_next <= bits_left;
		if ((valid_i = '1') and (ready = '1')) then
			frame_next <= '1' & data_i & '0'; -- Stop, data LSB at bit 1, start
			acc_next <= 0;
			bits_left_next <= 10;
		elsif (bits_left /= 0) then
			if (bit_end = '1') then
				frame_next <= '1' & frame(9 downto 1);
				acc_next <= acc + N - P;
				bits_left_next <= bits_left - 1;
			else
				acc_next <= acc + N;
			end if;
		end if;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			frame <= (others => '1');
			acc <= 0;
			bits_left <= 0;
		elsif rising_edge(clk_i) then
			frame <= frame_next;
			acc <= acc_next;
			bits_left <= bits_left_next;
		end if;
	end process;

	ready_o <= ready;
	tx_o <= frame(0);
end arch;

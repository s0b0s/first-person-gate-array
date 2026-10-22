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
-- Description:    UART transmitter, 8N1, LSB first. A byte is taken on a
--                 clock where valid_i and ready_o are both '1'; it is
--                 loaded into a 10-bit frame register (stop, data, start)
--                 whose bit 0 drives the line directly, so tx_o comes
--                 straight from a flip-flop. The register shifts right
--                 (filling with '1', the idle level) once per bit period.
--                 ready_o is high again in the last clock of the stop
--                 bit, so a waiting byte follows with no idle gap.
--                 Clock domain: clk_i. Throughput: one byte per 10 bit
--                 periods. tx_o goes low one clock after the byte is taken.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 The bit period is CLK_HZ / BAUD rounded to whole clocks.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

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
	constant BIT_CYCLES: natural := (CLK_HZ + BAUD / 2) / BAUD;
	signal frame: std_logic_vector(9 downto 0) := (others => '1');
	signal frame_next: std_logic_vector(9 downto 0);
	signal count: natural range 0 to BIT_CYCLES - 1 := 0;
	signal count_next: natural range 0 to BIT_CYCLES - 1;
	signal bits_left: natural range 0 to 10 := 0; -- Bit periods still to send
	signal bits_left_next: natural range 0 to 10;
	signal ready: std_logic;
begin
	-- Free when idle, or in the last clock of the stop bit
	ready <= '1' when ((bits_left = 0) or ((bits_left = 1) and (count = 0))) else '0';

	process(frame, count, bits_left, ready, valid_i, data_i)
	begin
		frame_next <= frame;
		count_next <= count;
		bits_left_next <= bits_left;
		if ((valid_i = '1') and (ready = '1')) then
			frame_next <= '1' & data_i & '0'; -- Stop, data LSB at bit 1, start
			count_next <= BIT_CYCLES - 1;
			bits_left_next <= 10;
		elsif (bits_left /= 0) then
			if (count = 0) then
				frame_next <= '1' & frame(9 downto 1);
				count_next <= BIT_CYCLES - 1;
				bits_left_next <= bits_left - 1;
			else
				count_next <= count - 1;
			end if;
		end if;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			frame <= (others => '1');
			count <= 0;
			bits_left <= 0;
		elsif rising_edge(clk_i) then
			frame <= frame_next;
			count <= count_next;
			bits_left <= bits_left_next;
		end if;
	end process;

	ready_o <= ready;
	tx_o <= frame(0);
end arch;

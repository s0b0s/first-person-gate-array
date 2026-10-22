--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    I2S Transmitter
-- Module Name:    i2s_tx
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    I2S output to the Pmod I2S2 DAC (Cirrus CS4344,
--                 single-speed mode, MCLK / LRCK = 256). Every I2S clock
--                 is a bit of one free-running 11-bit counter cnt on the
--                 100 MHz system clock, so they keep exact ratios and
--                 need no extra clock domain:
--                   MCLK = cnt(2)   100 MHz / 8    = 12.5 MHz
--                   SCLK = cnt(4)   100 MHz / 32   = 3.125 MHz (64 x LRCK)
--                   LRCK = cnt(10)  100 MHz / 2048 = 48.828 kHz, '0' = left
--                 Each channel is 32 SCLK slots (cnt(9 downto 5)). A slot
--                 starts when cnt(4 downto 0) = 0, which is an SCLK
--                 falling edge, so SDIN and LRCK change on falling edges
--                 and the DAC samples on rising edges. I2S puts the MSB
--                 one SCLK after the LRCK edge: slot 0 is a zero, slots
--                 1..16 carry bits 15..0, slots 17..31 are zeros (16-bit
--                 samples, left-justified in the 24-bit word the DAC
--                 reads).
--                 left_i and right_i are taken together at the end of
--                 each frame (cnt = 2047); sample_req_o pulses on the next
--                 clock, leaving 2048 clocks to present the next pair.
--                 All four outputs are registered from the same counter
--                 value, so they leave the FPGA aligned (one clock after
--                 the counter).
--                 Clock domain: clk_i (system, 100 MHz). Throughput: one
--                 stereo sample per 2048 clocks.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 Rates assume a 100 MHz clock (100.75 MHz with the
--                 exact-VGA MMCM setting raises them by 0.75%).
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity i2s_tx is
	port(
		clk_i: in std_logic; -- System clock, 100 MHz
		rst_i: in std_logic; -- Asynchronous reset, active high
		left_i: in std_logic_vector(15 downto 0); -- Left sample, two's complement
		right_i: in std_logic_vector(15 downto 0); -- Right sample, two's complement
		sample_req_o: out std_logic; -- Pulse: inputs taken, present the next pair
		mclk_o: out std_logic; -- Master clock, 12.5 MHz
		lrck_o: out std_logic; -- Word select, '0' = left
		sclk_o: out std_logic; -- Bit clock, 3.125 MHz
		sdin_o: out std_logic -- Serial data, MSB first
	);
end i2s_tx;

architecture arch of i2s_tx is
	signal cnt: unsigned(10 downto 0) := (others => '0');
	signal left_q: std_logic_vector(15 downto 0) := (others => '0');
	signal right_q: std_logic_vector(15 downto 0) := (others => '0');
	signal req: std_logic := '0';
	signal sdin_bit: std_logic;
	-- Output registers
	signal mclk_r: std_logic := '0';
	signal lrck_r: std_logic := '0';
	signal sclk_r: std_logic := '0';
	signal sdin_r: std_logic := '0';
	attribute IOB: string;
	attribute IOB of mclk_r, lrck_r, sclk_r, sdin_r: signal is "TRUE";
begin
	-- Data bit for the slot cnt points at
	process(cnt, left_q, right_q)
		variable slot: natural range 0 to 31;
		variable word: std_logic_vector(15 downto 0);
	begin
		slot := to_integer(cnt(9 downto 5));
		if (cnt(10) = '0') then
			word := left_q;
		else
			word := right_q;
		end if;
		if ((slot >= 1) and (slot <= 16)) then
			sdin_bit <= word(16 - slot); -- Slot 1 carries bit 15, slot 16 bit 0
		else
			sdin_bit <= '0';
		end if;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			cnt <= (others => '0');
			left_q <= (others => '0');
			right_q <= (others => '0');
			req <= '0';
			mclk_r <= '0';
			lrck_r <= '0';
			sclk_r <= '0';
			sdin_r <= '0';
		elsif rising_edge(clk_i) then
			cnt <= cnt + 1;
			-- Take the next pair as the frame ends
			if (cnt = 2047) then
				left_q <= left_i;
				right_q <= right_i;
				req <= '1';
			else
				req <= '0';
			end if;
			mclk_r <= cnt(2);
			lrck_r <= cnt(10);
			sclk_r <= cnt(4);
			sdin_r <= sdin_bit;
		end if;
	end process;

	sample_req_o <= req;
	mclk_o <= mclk_r;
	lrck_o <= lrck_r;
	sclk_o <= sclk_r;
	sdin_o <= sdin_r;
end arch;

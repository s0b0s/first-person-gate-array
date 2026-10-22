--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Test Tone
-- Module Name:    tone_gen
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Stage-0 test tone: a sine at FREQ_HZ and quarter volume
--                 (peak 8192 of 32767) for the I2S output. A 32-bit phase
--                 accumulator advances once per output sample (step_i,
--                 from i2s_tx's sample_req_o); its top 8 bits index a
--                 256-entry sine table that is computed at elaboration
--                 with IEEE.math_real (no generated file needed).
--                   increment = FREQ_HZ x 2^32 / (CLK_HZ / 2048)
--                 (38,702,809 for 440 Hz at 48,828.125 samples per
--                 second; the frequency error is below 0.001 Hz).
--                 With 256 table entries the sine has steps of about
--                 1.4 deg; harmonics from that sit near 48 dB down, fine
--                 for a test tone.
--                 Clock domain: clk_i. sample_o changes one clock after
--                 step_i; it is 0 while enable_i = '0'.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std,
--                 IEEE.math_real
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 FREQ_HZ below about 24 kHz (the increment must stay
--                 below 2^31 to fit a VHDL natural).
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.math_real.all;

entity tone_gen is
	generic(
		CLK_HZ: natural := 100_000_000; -- System clock (sample rate = CLK_HZ / 2048)
		FREQ_HZ: natural := 440 -- Tone frequency
	);
	port(
		clk_i: in std_logic; -- Clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		enable_i: in std_logic; -- '0' = silence
		step_i: in std_logic; -- Advance one output sample
		sample_o: out std_logic_vector(15 downto 0) -- Two's complement sample
	);
end tone_gen;

architecture arch of tone_gen is
	constant AMPLITUDE: real := 8192.0; -- Quarter of full scale
	-- FREQ_HZ x 2^32 / sample rate, with sample rate = CLK_HZ / 2048
	constant INC: natural := natural(round(real(FREQ_HZ) * 4294967296.0 * 2048.0 /
		real(CLK_HZ)));

	type table_t is array (0 to 255) of signed(15 downto 0);
	function make_table return table_t is
		variable t: table_t;
	begin
		for i in 0 to 255 loop
			t(i) := to_signed(integer(round(AMPLITUDE * sin(MATH_2_PI * real(i) / 256.0))), 16);
		end loop;
		return t;
	end function;
	constant SINE: table_t := make_table;

	signal phase: unsigned(31 downto 0) := (others => '0');
	signal sample: signed(15 downto 0) := (others => '0');
begin
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			phase <= (others => '0');
			sample <= (others => '0');
		elsif rising_edge(clk_i) then
			if (enable_i = '0') then
				phase <= (others => '0');
				sample <= (others => '0');
			elsif (step_i = '1') then
				phase <= phase + to_unsigned(INC, 32);
				sample <= SINE(to_integer(phase(31 downto 24)));
			end if;
		end if;
	end process;

	sample_o <= std_logic_vector(sample);
end arch;

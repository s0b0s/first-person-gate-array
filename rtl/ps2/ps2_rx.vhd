--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    PS/2 Receiver
-- Module Name:    ps2_rx
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    PS/2 receiver (device to host). The device drives the
--                 clock (10 to 16.7 kHz) and changes data while the clock
--                 is high; the host takes one bit on every falling clock
--                 edge. A frame is 11 bits, first bit first:
--                   bit 0      start, always '0'
--                   bits 1..8  data, LSB first
--                   bit 9      odd parity (data and parity hold an odd
--                              number of ones)
--                   bit 10     stop, always '1'
--                 After the 11th bit exactly one output pulses for one
--                 cycle: valid_o (good byte on data_o), frame_err_o (bad
--                 start or stop bit) or parity_err_o. If a frame is
--                 started and no falling edge arrives for TIMEOUT_CYCLES
--                 (2 ms at 100 MHz, longer than any bit time), the bit
--                 counter restarts and timeout_o pulses, so a lost clock
--                 edge cannot shift every following byte.
--                 en_i = '0' (host disabled or transmitting) clears the
--                 frame and ignores the line.
--                 Clock domain: clk_i (system). fall_i and dat_i come
--                 from the host's synchronizers and glitch filter.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
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

entity ps2_rx is
	generic(
		TIMEOUT_CYCLES: positive := 200_000 -- Clocks without an edge that abort a frame
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		en_i: in std_logic; -- '0' clears the frame and ignores the line
		fall_i: in std_logic; -- One-cycle pulse on a filtered clock falling edge
		dat_i: in std_logic; -- Filtered data line level
		data_o: out std_logic_vector(7 downto 0); -- Received byte
		valid_o: out std_logic; -- Pulse: data_o holds a good byte
		parity_err_o: out std_logic; -- Pulse: parity check failed
		frame_err_o: out std_logic; -- Pulse: bad start or stop bit
		timeout_o: out std_logic -- Pulse: frame abandoned
	);
end ps2_rx;

architecture arch of ps2_rx is
	signal count: natural range 0 to 10 := 0; -- Bits received so far
	signal count_next: natural range 0 to 10;
	signal sh: std_logic_vector(10 downto 0) := (others => '1'); -- Newest bit at 10
	signal sh_next: std_logic_vector(10 downto 0);
	signal timer: natural range 0 to TIMEOUT_CYCLES - 1 := 0;
	signal timer_next: natural range 0 to TIMEOUT_CYCLES - 1;
	signal data: std_logic_vector(7 downto 0) := (others => '0');
	signal data_next: std_logic_vector(7 downto 0);
	signal valid, perr, ferr, tout: std_logic := '0';
	signal valid_next, perr_next, ferr_next, tout_next: std_logic;

	-- XOR of all bits (VHDL-93 has no unary reduction operators)
	function xor_bits(v: std_logic_vector) return std_logic is
		variable x: std_logic := '0';
	begin
		for i in v'range loop
			x := x xor v(i);
		end loop;
		return x;
	end function;
begin
	process(en_i, fall_i, dat_i, count, sh, timer, data)
		variable frame: std_logic_vector(10 downto 0);
	begin
		count_next <= count;
		sh_next <= sh;
		timer_next <= timer;
		data_next <= data;
		valid_next <= '0';
		perr_next <= '0';
		ferr_next <= '0';
		tout_next <= '0';
		frame := dat_i & sh(10 downto 1);
		if (en_i = '0') then
			count_next <= 0;
			timer_next <= 0;
		elsif (fall_i = '1') then
			-- Bits shift in from the top, so after 11 bits the start bit
			-- is at position 0 and the stop bit at position 10
			sh_next <= frame;
			timer_next <= 0;
			if (count = 10) then
				count_next <= 0;
				if ((frame(0) /= '0') or (frame(10) /= '1')) then
					ferr_next <= '1';
				elsif (xor_bits(frame(9 downto 1)) /= '1') then -- Data plus parity: odd number of ones
					perr_next <= '1';
				else
					valid_next <= '1';
					data_next <= frame(8 downto 1);
				end if;
			else
				count_next <= count + 1;
			end if;
		elsif (count /= 0) then
			if (timer = TIMEOUT_CYCLES - 1) then
				count_next <= 0;
				timer_next <= 0;
				tout_next <= '1';
			else
				timer_next <= timer + 1;
			end if;
		end if;
	end process;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			count <= 0;
			sh <= (others => '1');
			timer <= 0;
			data <= (others => '0');
			valid <= '0';
			perr <= '0';
			ferr <= '0';
			tout <= '0';
		elsif rising_edge(clk_i) then
			count <= count_next;
			sh <= sh_next;
			timer <= timer_next;
			data <= data_next;
			valid <= valid_next;
			perr <= perr_next;
			ferr <= ferr_next;
			tout <= tout_next;
		end if;
	end process;

	data_o <= data;
	valid_o <= valid;
	parity_err_o <= perr;
	frame_err_o <= ferr;
	timeout_o <= tout;
end arch;

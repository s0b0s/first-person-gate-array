--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    PS/2 Transmitter
-- Module Name:    ps2_tx
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    PS/2 transmitter (host to device). Even when the host
--                 sends, the device makes the clock; the host only asks
--                 for it:
--                   TX_INHIBIT  pull the clock low for INHIBIT_CYCLES
--                               (150 us), which stops the device and
--                               tells it a command is coming
--                   TX_START    also pull data low (the start bit) for
--                               RELEASE_CYCLES, then let the clock go
--                   TX_BITS     the device now clocks; after each falling
--                               edge (clock low, the device reads on the
--                               rising edge) present the next bit: falls
--                               1..8 data LSB first, 9 odd parity, 10
--                               release data (stop bit '1')
--                   TX_ACK_DATA wait for the device to pull data low
--                   TX_ACK_CLK  wait for its last falling clock edge
--                   TX_RELEASE  wait until both lines are high again
--                 then done_o pulses. If the whole exchange takes longer
--                 than TIMEOUT_CYCLES (20 ms), both lines are released
--                 and err_o pulses instead.
--                 Outputs are pull requests ('1' = drive the line low);
--                 the top level makes them open drain.
--                 Clock domain: clk_i (system). Command port: data_i is
--                 taken when valid_i and ready_o are both '1'.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - One-process state machine
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ps2_tx is
	generic(
		INHIBIT_CYCLES: positive := 15_000; -- Clock held low before the start bit
		RELEASE_CYCLES: positive := 1_000; -- Data low before the clock is released
		TIMEOUT_CYCLES: positive := 2_000_000 -- Whole exchange limit
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		en_i: in std_logic; -- '0' aborts and releases the lines
		data_i: in std_logic_vector(7 downto 0); -- Byte to send
		valid_i: in std_logic; -- Byte present
		ready_o: out std_logic; -- Idle, byte taken if valid_i
		fall_i: in std_logic; -- Pulse on a filtered clock falling edge
		clk_lvl_i: in std_logic; -- Filtered clock line level
		dat_lvl_i: in std_logic; -- Filtered data line level
		pull_clk_o: out std_logic; -- '1' = drive the clock line low
		pull_dat_o: out std_logic; -- '1' = drive the data line low
		busy_o: out std_logic; -- Transmission in progress
		done_o: out std_logic; -- Pulse: device acknowledged the byte
		err_o: out std_logic -- Pulse: timed out, lines released
	);
end ps2_tx;

architecture arch of ps2_tx is
	type tx_state_type is (TX_IDLE, TX_INHIBIT, TX_START, TX_BITS, TX_ACK_DATA, TX_ACK_CLK,
		TX_RELEASE);
	signal tx_state: tx_state_type := TX_IDLE;
	signal timer: natural range 0 to TIMEOUT_CYCLES := 0; -- Clocks since the byte was taken
	signal bitn: natural range 0 to 9 := 0; -- Falling edges seen in TX_BITS
	-- Bits 7:0 data, bit 8 odd parity
	signal sh: std_logic_vector(8 downto 0) := (others => '0');
	signal pull_dat: std_logic := '0';
	signal done, err: std_logic := '0';

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
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			tx_state <= TX_IDLE;
			timer <= 0;
			bitn <= 0;
			sh <= (others => '0');
			pull_dat <= '0';
			done <= '0';
			err <= '0';
		elsif rising_edge(clk_i) then
			-- done and err are one-cycle pulses
			done <= '0';
			err <= '0';
			if (en_i = '0') then
				tx_state <= TX_IDLE;
				pull_dat <= '0';
			elsif (tx_state = TX_IDLE) then
				timer <= 0;
				if (valid_i = '1') then
					sh <= (not xor_bits(data_i)) & data_i; -- Parity '1' when the data has an even number of ones
					bitn <= 0;
					tx_state <= TX_INHIBIT;
				end if;
			elsif (timer = TIMEOUT_CYCLES) then
				tx_state <= TX_IDLE;
				pull_dat <= '0';
				err <= '1';
			else
				timer <= timer + 1;
				case tx_state is
					when TX_INHIBIT =>
						if (timer = INHIBIT_CYCLES - 1) then
							pull_dat <= '1'; -- Start bit
							tx_state <= TX_START;
						end if;
					when TX_START =>
						if (timer = INHIBIT_CYCLES + RELEASE_CYCLES - 1) then
							tx_state <= TX_BITS;
						end if;
					when TX_BITS =>
						if (fall_i = '1') then
							if (bitn = 9) then
								pull_dat <= '0'; -- Stop bit: let the line go high
								tx_state <= TX_ACK_DATA;
							else
								pull_dat <= not sh(bitn); -- Pull low to send a '0'
								bitn <= bitn + 1;
							end if;
						end if;
					when TX_ACK_DATA =>
						if (dat_lvl_i = '0') then
							tx_state <= TX_ACK_CLK;
						end if;
					when TX_ACK_CLK =>
						if (fall_i = '1') then
							tx_state <= TX_RELEASE;
						end if;
					when TX_RELEASE =>
						if ((clk_lvl_i = '1') and (dat_lvl_i = '1')) then
							done <= '1';
							tx_state <= TX_IDLE;
						end if;
					when others =>
						tx_state <= TX_IDLE;
				end case;
			end if;
		end if;
	end process;

	-- ready_o follows en_i in the same cycle (no register delay)
	ready_o <= '1' when ((tx_state = TX_IDLE) and (en_i = '1')) else '0';
	pull_clk_o <= '1' when ((tx_state = TX_INHIBIT) or (tx_state = TX_START)) else '0';
	pull_dat_o <= pull_dat;
	busy_o <= '0' when (tx_state = TX_IDLE) else '1';
	done_o <= done;
	err_o <= err;
end arch;

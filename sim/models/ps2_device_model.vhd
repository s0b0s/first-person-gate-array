--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    PS/2 Device Model
-- Module Name:    ps2_device_model
-- Project Name:   First-Person Gate Array
-- Target Devices: Simulation only (Vivado xsim)
-- Tool versions:  Vivado 2025.1 xsim, VHDL-2008
-- Description:    Behavioral PS/2 device (keyboard or mouse) on open-drain
--                 lines: it only drives '0' or 'Z'; the testbench adds
--                 the pull-ups as weak 'H' drivers.
--                 Device to host: each toggle of send_i sends send_byte_i
--                 as start, 8 data bits LSB first, odd parity, stop, at
--                 12.5 kHz (HALF_PERIOD 40 us). Data changes in the
--                 middle of the clock-high time. send_mode_i:
--                   0 normal, 1 wrong parity, 2 stop bit '0',
--                   3 truncated (only the first 5 bits, then silence)
--                 sent_o counts finished bytes (including automatic
--                 mouse replies), so a testbench waits for it to grow.
--                 Host to device: when the host holds the clock low and
--                 then releases it with data low, the model clocks in 8
--                 data bits, the parity bit and the stop bit (reading
--                 data while the clock is high), then acknowledges by
--                 pulling data low for one more clock pulse. rx_byte_o,
--                 rx_count_o and rx_parity_errors_o record what arrived.
--                 silent_i = true makes it ignore host requests (to test
--                 the host's 20 ms send timeout).
--                 MOUSE = true adds the mouse replies: FA to every byte,
--                 and after FF a self-test of BAT_DELAY, then AA 00.
--
-- Dependencies:   VHDL-2008, IEEE.std_logic_1164
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;

entity ps2_device_model is
	generic(
		HALF_PERIOD: time := 40 us; -- Half of the 12.5 kHz device clock
		MOUSE: boolean := false; -- Answer commands like a mouse
		REPLY_DELAY: time := 300 us; -- Command to FA
		BAT_DELAY: time := 3 ms; -- FA to AA after a reset command
		BYTE_GAP: time := 100 us -- Idle time after every byte sent
	);
	port(
		clk_io: inout std_logic; -- PS/2 clock line
		dat_io: inout std_logic; -- PS/2 data line
		send_i: in boolean; -- Toggle: send send_byte_i
		send_byte_i: in std_logic_vector(7 downto 0);
		send_mode_i: in natural; -- 0 good, 1 bad parity, 2 bad stop, 3 truncated
		silent_i: in boolean; -- Ignore host requests
		sent_o: out natural; -- Bytes sent so far
		rx_byte_o: out std_logic_vector(7 downto 0); -- Last byte from the host
		rx_count_o: out natural; -- Bytes received from the host
		rx_parity_errors_o: out natural -- Host bytes with bad parity
	);
end ps2_device_model;

architecture arch of ps2_device_model is
begin
	process
		variable last_send: boolean := false;
		variable sent: natural := 0;
		variable rx_count: natural := 0;
		variable rx_perr: natural := 0;
		variable b: std_logic_vector(7 downto 0);
		variable par: std_logic;

		procedure drive_clk(v: std_logic) is
		begin
			if (v = '0') then
				clk_io <= '0';
			else
				clk_io <= 'Z';
			end if;
		end procedure;

		procedure drive_dat(v: std_logic) is
		begin
			if (v = '0') then
				dat_io <= '0';
			else
				dat_io <= 'Z';
			end if;
		end procedure;

		procedure send_byte(data: std_logic_vector(7 downto 0); mode: natural) is
			variable frame: std_logic_vector(10 downto 0);
			variable nbits: natural;
		begin
			-- Wait while the host inhibits the bus
			if (to_x01(clk_io) = '0') then
				wait until (to_x01(clk_io) = '1');
				wait for 50 us;
			end if;
			-- Bit 0 goes first: start '0', data LSB first, odd parity, stop '1'
			frame := '1' & (not (xor data)) & data & '0';
			if (mode = 1) then
				frame(9) := not frame(9);
			elsif (mode = 2) then
				frame(10) := '0';
			end if;
			nbits := 11;
			if (mode = 3) then
				nbits := 5;
			end if;
			for i in 0 to nbits - 1 loop
				drive_dat(frame(i));
				wait for HALF_PERIOD / 2;
				drive_clk('0');
				wait for HALF_PERIOD;
				drive_clk('1');
				wait for HALF_PERIOD / 2;
			end loop;
			drive_dat('1');
			wait for BYTE_GAP;
			sent := sent + 1;
			sent_o <= sent;
		end procedure;

		procedure receive_byte is
			variable bits: std_logic_vector(9 downto 0); -- data, parity, stop
		begin
			wait for 50 us; -- Device notices the request
			for i in 0 to 9 loop
				drive_clk('0');
				wait for HALF_PERIOD;
				drive_clk('1');
				wait for 1 us;
				bits(i) := to_x01(dat_io); -- Host set it after the falling edge
				wait for HALF_PERIOD - 1 us;
			end loop;
			-- Acknowledge: data low for one more clock pulse
			drive_dat('0');
			wait for HALF_PERIOD / 2;
			drive_clk('0');
			wait for HALF_PERIOD;
			drive_clk('1');
			wait for HALF_PERIOD / 2;
			drive_dat('1');
			b := bits(7 downto 0);
			par := xor bits(8 downto 0); -- Odd parity: '1' when data plus parity is good
			rx_count := rx_count + 1;
			if ((par /= '1') or (bits(9) /= '1')) then
				rx_perr := rx_perr + 1;
			end if;
			rx_byte_o <= b;
			rx_count_o <= rx_count;
			rx_parity_errors_o <= rx_perr;
		end procedure;
	begin
		clk_io <= 'Z';
		dat_io <= 'Z';
		sent_o <= 0;
		rx_byte_o <= (others => '0');
		rx_count_o <= 0;
		rx_parity_errors_o <= 0;
		wait for 1 ns;
		loop
			if (send_i /= last_send) then
				last_send := send_i;
				send_byte(send_byte_i, send_mode_i);
			elsif (to_x01(clk_io) = '0') then
				-- Host holds the clock: a command follows if data goes low
				-- before the clock is released
				wait until (to_x01(clk_io) = '1');
				if (to_x01(dat_io) = '0') then
					if (silent_i) then
						wait until (to_x01(dat_io) = '1');
					else
						receive_byte;
						if (MOUSE) then
							wait for REPLY_DELAY;
							send_byte(x"FA", 0);
							if (b = x"FF") then
								wait for BAT_DELAY;
								send_byte(x"AA", 0);
								send_byte(x"00", 0);
							end if;
						end if;
					end if;
				end if;
			else
				wait on send_i, clk_io;
			end if;
		end loop;
	end process;
end arch;

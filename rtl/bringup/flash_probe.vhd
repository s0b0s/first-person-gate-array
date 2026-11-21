--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Flash JEDEC ID Probe
-- Module Name:    flash_probe
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Flash check: after reset (and on every start_i
--                 pulse) asks flash_reader for the 3-byte JEDEC ID and
--                 then the first 8 bytes of the game-data area at
--                 0x220000, and holds them for the bring-up page. The
--                 flash image builder puts a known test pattern there.
--                 States: PROBE_ID_REQ, PROBE_ID_DATA, PROBE_RD_REQ,
--                 PROBE_RD_DATA, PROBE_DONE.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Revision 1.01 - State type and state names renamed (<name>_state_type, prefixed states)
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.hw_pkg.all;

entity flash_probe is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		start_i: in std_logic; -- Pulse: read again
		-- flash_reader request and data ports
		req_valid_o: out std_logic;
		req_ready_i: in std_logic;
		req_id_o: out std_logic;
		req_addr_o: out std_logic_vector(23 downto 0);
		req_len_o: out std_logic_vector(23 downto 0);
		data_valid_i: in std_logic;
		data_ready_o: out std_logic;
		data_i: in std_logic_vector(7 downto 0);
		data_last_i: in std_logic;
		-- Results
		id_o: out std_logic_vector(23 downto 0); -- Manufacturer, type, capacity
		data_o: out std_logic_vector(63 downto 0); -- Bytes at 0x220000, first in 63:56
		done_o: out std_logic -- Both reads finished
	);
end flash_probe;

architecture arch of flash_probe is
	type probe_state_type is (PROBE_ID_REQ, PROBE_ID_DATA, PROBE_RD_REQ, PROBE_RD_DATA, PROBE_DONE);
	signal probe_state: probe_state_type := PROBE_ID_REQ;
	signal id: std_logic_vector(23 downto 0) := (others => '0');
	signal data: std_logic_vector(63 downto 0) := (others => '0');
begin
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			probe_state <= PROBE_ID_REQ;
			id <= (others => '0');
			data <= (others => '0');
		elsif rising_edge(clk_i) then
			case probe_state is
				when PROBE_ID_REQ =>
					if (req_ready_i = '1') then
						probe_state <= PROBE_ID_DATA;
					end if;
				when PROBE_ID_DATA =>
					-- Bytes arrive first to last; shift them in from the right
					if (data_valid_i = '1') then
						id <= id(15 downto 0) & data_i;
						if (data_last_i = '1') then
							probe_state <= PROBE_RD_REQ;
						end if;
					end if;
				when PROBE_RD_REQ =>
					if (req_ready_i = '1') then
						probe_state <= PROBE_RD_DATA;
					end if;
				when PROBE_RD_DATA =>
					if (data_valid_i = '1') then
						data <= data(55 downto 0) & data_i;
						if (data_last_i = '1') then
							probe_state <= PROBE_DONE;
						end if;
					end if;
				when PROBE_DONE =>
					if (start_i = '1') then
						probe_state <= PROBE_ID_REQ;
					end if;
			end case;
		end if;
	end process;

	req_valid_o <= '1' when ((probe_state = PROBE_ID_REQ) or (probe_state = PROBE_RD_REQ)) else '0';
	req_id_o <= '1' when (probe_state = PROBE_ID_REQ) else '0';
	req_addr_o <= std_logic_vector(to_unsigned(FLASH_DATA_BASE, 24));
	req_len_o <= std_logic_vector(to_unsigned(3, 24)) when (probe_state = PROBE_ID_REQ) else
		std_logic_vector(to_unsigned(8, 24));
	data_ready_o <= '1';
	id_o <= id;
	data_o <= data;
	done_o <= '1' when (probe_state = PROBE_DONE) else '0';
end arch;

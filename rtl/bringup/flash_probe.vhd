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
-- Description:    Stage-0 flash check: after reset (and on every start_i
--                 pulse) asks flash_reader for the 3-byte JEDEC ID and
--                 then the first 8 bytes of the game-data area at
--                 0x220000, and holds them for the bring-up page. The
--                 flash image builder puts a known test pattern there.
--                 States: S_ID_REQ, S_ID_DATA, S_RD_REQ, S_RD_DATA, S_DONE.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std, hw_pkg
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
	type state_t is (S_ID_REQ, S_ID_DATA, S_RD_REQ, S_RD_DATA, S_DONE);
	signal state: state_t := S_ID_REQ;
	signal id: std_logic_vector(23 downto 0) := (others => '0');
	signal data: std_logic_vector(63 downto 0) := (others => '0');
begin
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			state <= S_ID_REQ;
			id <= (others => '0');
			data <= (others => '0');
		elsif rising_edge(clk_i) then
			case state is
				when S_ID_REQ =>
					if (req_ready_i = '1') then
						state <= S_ID_DATA;
					end if;
				when S_ID_DATA =>
					-- Bytes arrive first to last; shift them in from the right
					if (data_valid_i = '1') then
						id <= id(15 downto 0) & data_i;
						if (data_last_i = '1') then
							state <= S_RD_REQ;
						end if;
					end if;
				when S_RD_REQ =>
					if (req_ready_i = '1') then
						state <= S_RD_DATA;
					end if;
				when S_RD_DATA =>
					if (data_valid_i = '1') then
						data <= data(55 downto 0) & data_i;
						if (data_last_i = '1') then
							state <= S_DONE;
						end if;
					end if;
				when S_DONE =>
					if (start_i = '1') then
						state <= S_ID_REQ;
					end if;
			end case;
		end if;
	end process;

	req_valid_o <= '1' when ((state = S_ID_REQ) or (state = S_RD_REQ)) else '0';
	req_id_o <= '1' when (state = S_ID_REQ) else '0';
	req_addr_o <= std_logic_vector(to_unsigned(FLASH_DATA_BASE, 24));
	req_len_o <= std_logic_vector(to_unsigned(3, 24)) when (state = S_ID_REQ) else
		std_logic_vector(to_unsigned(8, 24));
	data_ready_o <= '1';
	id_o <= id;
	data_o <= data;
	done_o <= '1' when (state = S_DONE) else '0';
end arch;

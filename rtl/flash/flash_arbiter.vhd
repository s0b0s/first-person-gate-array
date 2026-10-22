--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    Flash Arbiter
-- Module Name:    flash_arbiter
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Shares one flash_reader between two clients that use the
--                 flash_reader request/data ports: client 0 (audio sample
--                 refills, higher priority) and client 1 (asset loader).
--                 Whole commands are granted: when the reader is free, the
--                 request of client 0 (else client 1) is passed through;
--                 once it is taken, that client owns the reader until the
--                 last byte of its command has been delivered (data_last
--                 taken), and every data byte goes to it. The other client
--                 sees req_ready = '0' and data_valid = '0' meanwhile.
--                 States: S_IDLE (no command running), S_BUSY (owner set).
--                 Clock domain: clk_i (system). No added latency: requests
--                 and data pass through combinationally.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 None.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;

entity flash_arbiter is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		-- Client 0 (audio, priority)
		c0_req_valid_i: in std_logic;
		c0_req_ready_o: out std_logic;
		c0_req_id_i: in std_logic;
		c0_req_addr_i: in std_logic_vector(23 downto 0);
		c0_req_len_i: in std_logic_vector(23 downto 0);
		c0_data_valid_o: out std_logic;
		c0_data_ready_i: in std_logic;
		c0_data_o: out std_logic_vector(7 downto 0);
		c0_data_last_o: out std_logic;
		-- Client 1 (loader)
		c1_req_valid_i: in std_logic;
		c1_req_ready_o: out std_logic;
		c1_req_id_i: in std_logic;
		c1_req_addr_i: in std_logic_vector(23 downto 0);
		c1_req_len_i: in std_logic_vector(23 downto 0);
		c1_data_valid_o: out std_logic;
		c1_data_ready_i: in std_logic;
		c1_data_o: out std_logic_vector(7 downto 0);
		c1_data_last_o: out std_logic;
		-- To the flash_reader
		req_valid_o: out std_logic;
		req_ready_i: in std_logic;
		req_id_o: out std_logic;
		req_addr_o: out std_logic_vector(23 downto 0);
		req_len_o: out std_logic_vector(23 downto 0);
		data_valid_i: in std_logic;
		data_ready_o: out std_logic;
		data_i: in std_logic_vector(7 downto 0);
		data_last_i: in std_logic
	);
end flash_arbiter;

architecture arch of flash_arbiter is
	type state_t is (S_IDLE, S_BUSY);
	signal state: state_t := S_IDLE;
	signal owner: std_logic := '0'; -- Client that owns the running command
	signal pick: std_logic; -- Client offered to the reader while idle
begin
	-- While idle, client 0 wins whenever it asks
	pick <= '0' when (c0_req_valid_i = '1') else '1';

	req_valid_o <= '0' when (state = S_BUSY) else
		c0_req_valid_i when (pick = '0') else c1_req_valid_i;
	req_id_o <= c0_req_id_i when (pick = '0') else c1_req_id_i;
	req_addr_o <= c0_req_addr_i when (pick = '0') else c1_req_addr_i;
	req_len_o <= c0_req_len_i when (pick = '0') else c1_req_len_i;
	c0_req_ready_o <= req_ready_i when ((state = S_IDLE) and (pick = '0')) else '0';
	c1_req_ready_o <= req_ready_i when ((state = S_IDLE) and (pick = '1')) else '0';

	-- Data goes to the owner only
	c0_data_valid_o <= data_valid_i when ((state = S_BUSY) and (owner = '0')) else '0';
	c1_data_valid_o <= data_valid_i when ((state = S_BUSY) and (owner = '1')) else '0';
	c0_data_o <= data_i;
	c1_data_o <= data_i;
	c0_data_last_o <= data_last_i;
	c1_data_last_o <= data_last_i;
	data_ready_o <= '0' when (state = S_IDLE) else
		c0_data_ready_i when (owner = '0') else c1_data_ready_i;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			state <= S_IDLE;
			owner <= '0';
		elsif rising_edge(clk_i) then
			case state is
				when S_IDLE =>
					if ((req_ready_i = '1') and
						(((pick = '0') and (c0_req_valid_i = '1')) or
						((pick = '1') and (c1_req_valid_i = '1')))) then
						owner <= pick;
						state <= S_BUSY;
					end if;
				when S_BUSY =>
					-- The command ends when its last byte is taken
					if ((data_valid_i = '1') and (data_last_i = '1') and
						(((owner = '0') and (c0_data_ready_i = '1')) or
						((owner = '1') and (c1_data_ready_i = '1')))) then
						state <= S_IDLE;
					end if;
			end case;
		end if;
	end process;
end arch;

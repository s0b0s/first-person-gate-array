--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    SRAM Arbiter
-- Module Name:    sram_arbiter
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Shares the SRAM controller between four masters
--                 (numbers MASTER_* in game_pkg): 0 display line fetch,
--                 1 sprite art reads, 2 pixel writes, 3 loader / debug.
--                 Master port: hold req with we/addr/wdata until gnt is
--                 high for one cycle (the request is then taken; a master
--                 may present its next request in the following cycle).
--                 Read data returns on rvalid (one bit per master, shared
--                 rdata) in request order, a fixed SRAM latency after gnt
--                 (see sram_controller).
--                 Policy: master 0 wins whenever it asks, so the display
--                 is never starved and preempts bursts at the next access
--                 boundary. Otherwise the master that was served last
--                 keeps the bus while it keeps asking, for up to
--                 BURST_MAX accesses (this groups reads and writes into
--                 bursts so the read-to-write turnaround is rare). After
--                 that, or when it stops asking, the highest-priority
--                 other requester wins; the last master continues only
--                 if nobody else is waiting. So masters 1..3 wait at most
--                 two bursts of the others, plus the display's fetches.
--                 Also counts busy SRAM cycles for the debug overlay.
--                 Clock domain: clk_i (system). Grant is combinational
--                 from req (same cycle).
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

entity sram_arbiter is
	generic(
		BURST_MAX: positive := 32 -- Accesses a lower master may keep the bus
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		-- Masters (index 0 is highest priority)
		m_req_i: in std_logic_vector(3 downto 0); -- Request
		m_we_i: in std_logic_vector(3 downto 0); -- '1' write, '0' read
		m_addr_i: in std_logic_vector(4 * 19 - 1 downto 0); -- 19 bits per master
		m_wdata_i: in std_logic_vector(4 * 8 - 1 downto 0); -- 8 bits per master
		m_gnt_o: out std_logic_vector(3 downto 0); -- Request taken
		m_rvalid_o: out std_logic_vector(3 downto 0); -- Read data for this master
		m_rdata_o: out std_logic_vector(7 downto 0); -- Read data (shared)
		-- Controller command and response ports
		cmd_valid_o: out std_logic;
		cmd_ready_i: in std_logic;
		cmd_we_o: out std_logic;
		cmd_addr_o: out std_logic_vector(18 downto 0);
		cmd_wdata_o: out std_logic_vector(7 downto 0);
		cmd_tag_o: out std_logic_vector(1 downto 0);
		rsp_valid_i: in std_logic;
		rsp_data_i: in std_logic_vector(7 downto 0);
		rsp_tag_i: in std_logic_vector(1 downto 0);
		-- Utilization
		busy_i: in std_logic; -- Controller busy this cycle
		clear_count_i: in std_logic; -- Clear busy_count_o (e.g. once per frame)
		busy_count_o: out std_logic_vector(23 downto 0) -- Busy cycles since clear
	);
end sram_arbiter;

architecture arch of sram_arbiter is
	signal sel: natural range 0 to 3;
	signal last: natural range 0 to 3 := 3;
	signal burst: natural range 0 to BURST_MAX := 0;
	signal gnt: std_logic;
	signal busy_count: unsigned(23 downto 0) := (others => '0');
begin
	-- Choose the master for this cycle. When the last master's burst is
	-- used up, any other waiting master goes first, so a master that asks
	-- on every cycle (the SRAM self-test, a long sprite read) cannot
	-- starve the ones below it.
	process(m_req_i, last, burst)
		variable other: natural range 0 to 3;
		variable found: boolean;
	begin
		found := false;
		other := 3;
		for k in 1 to 3 loop
			if ((not found) and (m_req_i(k) = '1') and (k /= last)) then
				other := k;
				found := true;
			end if;
		end loop;
		if (m_req_i(0) = '1') then
			sel <= 0;
		elsif ((last /= 0) and (m_req_i(last) = '1') and ((burst < BURST_MAX) or (not found))) then
			sel <= last;
		else
			sel <= other;
		end if;
	end process;

	cmd_valid_o <= m_req_i(sel);
	cmd_we_o <= m_we_i(sel);
	-- Master sel's slices of the packed request buses (19 address bits, 8 data bits each)
	cmd_addr_o <= m_addr_i(sel * 19 + 18 downto sel * 19);
	cmd_wdata_o <= m_wdata_i(sel * 8 + 7 downto sel * 8);
	cmd_tag_o <= std_logic_vector(to_unsigned(sel, 2)); -- Comes back with the read data
	gnt <= m_req_i(sel) and cmd_ready_i;

	-- Grant decoder: only the selected master sees gnt
	process(sel, gnt)
	begin
		for k in 0 to 3 loop
			if (k = sel) then
				m_gnt_o(k) <= gnt;
			else
				m_gnt_o(k) <= '0';
			end if;
		end loop;
	end process;

	-- Burst tracking: count consecutive grants to the same master
	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			last <= 3;
			burst <= 0;
		elsif rising_edge(clk_i) then
			if (gnt = '1') then
				last <= sel;
				if (sel = last) then
					if (burst < BURST_MAX) then
						burst <= burst + 1;
					end if;
				else
					burst <= 1;
				end if;
			end if;
		end if;
	end process;

	-- Read responses go back to the master named by the tag
	process(rsp_valid_i, rsp_tag_i)
	begin
		for k in 0 to 3 loop
			if (k = to_integer(unsigned(rsp_tag_i))) then
				m_rvalid_o(k) <= rsp_valid_i;
			else
				m_rvalid_o(k) <= '0';
			end if;
		end loop;
	end process;

	m_rdata_o <= rsp_data_i;

	process(clk_i, rst_i)
	begin
		if (rst_i = '1') then
			busy_count <= (others => '0');
		elsif rising_edge(clk_i) then
			if (clear_count_i = '1') then
				busy_count <= (others => '0');
			elsif ((busy_i = '1') and (busy_count /= x"FFFFFF")) then
				busy_count <= busy_count + 1;
			end if;
		end if;
	end process;

	busy_count_o <= std_logic_vector(busy_count);
end arch;

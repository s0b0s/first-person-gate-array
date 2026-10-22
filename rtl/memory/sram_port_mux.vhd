--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    SRAM Port Multiplexer
-- Module Name:    sram_port_mux
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Shares one sram_arbiter master port between two clients
--                 (shooter_top: master 1 = boot art copy / frame renderer,
--                 master 3 = UART debug port / replay unit).
--                 Read data comes back on the shared rvalid a fixed time
--                 after the grant, in order, so it must go to the client
--                 that issued the read. The mux keeps an owner and counts
--                 the owner's reads in flight; ownership may move to the
--                 other client only when that count is zero, so every
--                 rvalid belongs to the current owner.
--                 Selection (combinational, so a grant still comes in the
--                 same cycle as the request, like the arbiter's):
--                   reads in flight          -> owner (the other waits)
--                   none, both requesting    -> the client that is not
--                                               the owner (alternates)
--                   none, one requesting     -> that client
--                 Clock domain: clk_i (system). No added latency.
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - Stage 2
-- Additional Comments:
--                 At most 15 reads in flight (the arbiter port allows
--                 far fewer: one per access, a few clocks of latency).
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity sram_port_mux is
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		-- Client A
		a_req_i: in std_logic;
		a_we_i: in std_logic;
		a_addr_i: in std_logic_vector(18 downto 0);
		a_wdata_i: in std_logic_vector(7 downto 0);
		a_gnt_o: out std_logic;
		a_rvalid_o: out std_logic;
		-- Client B
		b_req_i: in std_logic;
		b_we_i: in std_logic;
		b_addr_i: in std_logic_vector(18 downto 0);
		b_wdata_i: in std_logic_vector(7 downto 0);
		b_gnt_o: out std_logic;
		b_rvalid_o: out std_logic;
		-- Arbiter master port (read data is shared, wire it to both clients)
		m_req_o: out std_logic;
		m_we_o: out std_logic;
		m_addr_o: out std_logic_vector(18 downto 0);
		m_wdata_o: out std_logic_vector(7 downto 0);
		m_gnt_i: in std_logic;
		m_rvalid_i: in std_logic
	);
end sram_port_mux;

architecture arch of sram_port_mux is
	signal owner: std_logic := '0'; -- '0' client A, '1' client B
	signal pending: unsigned(3 downto 0) := (others => '0'); -- Owner's reads in flight
	signal sel: std_logic; -- Client on the port this cycle
	signal sel_we: std_logic;
begin
	process(owner, pending, a_req_i, b_req_i)
	begin
		if (pending /= 0) then
			sel <= owner;
		elsif ((a_req_i = '1') and (b_req_i = '1')) then
			sel <= not owner; -- Both waiting: take turns
		elsif (b_req_i = '1') then
			sel <= '1';
		elsif (a_req_i = '1') then
			sel <= '0';
		else
			sel <= owner;
		end if;
	end process;

	m_req_o <= b_req_i when (sel = '1') else a_req_i;
	sel_we <= b_we_i when (sel = '1') else a_we_i;
	m_we_o <= sel_we;
	m_addr_o <= b_addr_i when (sel = '1') else a_addr_i;
	m_wdata_o <= b_wdata_i when (sel = '1') else a_wdata_i;
	a_gnt_o <= m_gnt_i when (sel = '0') else '0';
	b_gnt_o <= m_gnt_i when (sel = '1') else '0';
	-- Every read in flight belongs to the owner, so rvalid follows owner, not sel
	a_rvalid_o <= m_rvalid_i when (owner = '0') else '0';
	b_rvalid_o <= m_rvalid_i when (owner = '1') else '0';

	-- A grant moves ownership to the selected client (only possible with
	-- no reads in flight, see sel); a read grant adds one in flight, an
	-- rvalid retires one
	process(clk_i, rst_i)
		variable p: unsigned(3 downto 0);
	begin
		if (rst_i = '1') then
			owner <= '0';
			pending <= (others => '0');
		elsif rising_edge(clk_i) then
			p := pending;
			if ((m_gnt_i = '1') and (sel_we = '0')) then
				p := p + 1;
			end if;
			if (m_rvalid_i = '1') then
				p := p - 1;
			end if;
			pending <= p;
			if (m_gnt_i = '1') then
				owner <= sel;
			end if;
		end if;
	end process;
end arch;

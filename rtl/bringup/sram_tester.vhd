--------------------------------------------------------------------------
-- Company:        Johns Hopkins University Whiting School of Engineering
--                 Department of Electrical and Computer Engineering
-- Engineer:       Matthew Gordon
--
-- Create Date:    10/21/2026
-- Design Name:    SRAM Tester
-- Module Name:    sram_tester
-- Project Name:   First-Person Gate Array
-- Target Devices: Digilent Cmod A7-35T, Artix-7 FPGAs
-- Tool versions:  Vivado 2025.1, VHDL-93
-- Description:    Stage-0 SRAM self-test, run as an SRAM arbiter master
--                 over the byte range FIRST..LAST, repeating forever:
--                   WALK  walking ones on the data bus: bytes FIRST..
--                         FIRST+7 get 01, 02, 04 .. 80
--                   ADDR  address in address: every byte gets
--                         a(7:0) xor a(15:8) xor a(18:16), so a stuck or
--                         swapped address line shows as a mismatch
--                   LFSR  pseudo-random bytes from a 16-bit LFSR
--                         (x^16 + x^15 + x^13 + x^4 + 1, XAPP052), with a
--                         new seed every pass
--                 Each phase writes the whole range, then reads it back.
--                 Reads are issued as fast as the arbiter grants them and
--                 checked in order as they return (reads return in
--                 request order), so the expected value is recomputed
--                 from a check counter and a second LFSR that advance on
--                 each returned byte.
--                 Reports passes, errors (saturating), the first failing
--                 address and the first expected/read pair.
--                 Clock domain: clk_i (system).
--
-- Dependencies:   VHDL-93, IEEE.std_logic_1164, IEEE.numeric_std
--
-- Revision:
-- Revision 0.01 - File Created
-- Revision 1.00 - First working version
-- Additional Comments:
--                 LAST - FIRST must be at least 7.
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity sram_tester is
	generic(
		FIRST: natural := 16#40000#; -- First byte tested
		LAST: natural := 16#7FFFF# -- Last byte tested
	);
	port(
		clk_i: in std_logic; -- System clock
		rst_i: in std_logic; -- Asynchronous reset, active high
		enable_i: in std_logic; -- '1' = run
		-- SRAM arbiter master port
		m_req_o: out std_logic;
		m_we_o: out std_logic;
		m_addr_o: out std_logic_vector(18 downto 0);
		m_wdata_o: out std_logic_vector(7 downto 0);
		m_gnt_i: in std_logic;
		m_rvalid_i: in std_logic;
		m_rdata_i: in std_logic_vector(7 downto 0);
		-- Results
		phase_o: out std_logic_vector(2 downto 0); -- 0..5: WALK W/R, ADDR W/R, LFSR W/R
		pass_count_o: out std_logic_vector(15 downto 0); -- Complete passes
		error_count_o: out std_logic_vector(15 downto 0); -- Bad bytes (saturating)
		first_error_addr_o: out std_logic_vector(18 downto 0); -- Address of the first bad byte
		first_error_data_o: out std_logic_vector(15 downto 0) -- Expected (15:8), read (7:0)
	);
end sram_tester;

architecture arch of sram_tester is
	type phase_t is (WALK_WR, WALK_RD, ADDR_WR, ADDR_RD, LFSR_WR, LFSR_RD);
	signal phase: phase_t := WALK_WR;
	signal req_addr: unsigned(18 downto 0) := to_unsigned(FIRST, 19); -- Next address to issue
	signal chk_addr: unsigned(18 downto 0) := to_unsigned(FIRST, 19); -- Next address to check
	signal issued_all: std_logic := '0'; -- All reads of this phase issued
	signal last_req: unsigned(18 downto 0);
	signal wr_lfsr: unsigned(15 downto 0) := x"ACE1";
	signal chk_lfsr: unsigned(15 downto 0) := x"ACE1";
	signal seed: unsigned(15 downto 0) := x"ACE1";
	signal passes: unsigned(15 downto 0) := (others => '0');
	signal errors: unsigned(15 downto 0) := (others => '0');
	signal first_addr: unsigned(18 downto 0) := (others => '0');
	signal first_data: std_logic_vector(15 downto 0) := (others => '0');
	signal req: std_logic;
	signal we: std_logic;
	signal wdata: std_logic_vector(7 downto 0);
	signal expected: std_logic_vector(7 downto 0);

	function lfsr_step(s: unsigned(15 downto 0)) return unsigned is
	begin
		return s(14 downto 0) & (s(15) xor s(14) xor s(12) xor s(3)); -- Taps 16, 15, 13, 4
	end function;

	function addr_pattern(a: unsigned(18 downto 0)) return std_logic_vector is
	begin
		return std_logic_vector(a(7 downto 0) xor a(15 downto 8) xor resize(a(18 downto 16), 8));
	end function;

	function walk_pattern(a: unsigned(18 downto 0)) return std_logic_vector is
		variable v: std_logic_vector(7 downto 0) := (others => '0');
	begin
		v(to_integer(a(2 downto 0) - to_unsigned(FIRST mod 8, 3))) := '1'; -- Byte FIRST + k gets bit k
		return v;
	end function;
begin
	-- The walking-ones phases cover only FIRST..FIRST+7
	last_req <= to_unsigned(FIRST + 7, 19) when ((phase = WALK_WR) or (phase = WALK_RD)) else
		to_unsigned(LAST, 19);

	------------------------------------------------------------------
	-- Requests and expected data (combinational)
	------------------------------------------------------------------
	process(phase, enable_i, issued_all, req_addr, chk_addr, wr_lfsr, chk_lfsr)
	begin
		req <= '0';
		we <= '0';
		wdata <= (others => '0');
		expected <= (others => '0');
		case phase is
			when WALK_WR =>
				req <= enable_i;
				we <= '1';
				wdata <= walk_pattern(req_addr);
			when ADDR_WR =>
				req <= enable_i;
				we <= '1';
				wdata <= addr_pattern(req_addr);
			when LFSR_WR =>
				req <= enable_i;
				we <= '1';
				wdata <= std_logic_vector(wr_lfsr(7 downto 0));
			when WALK_RD =>
				req <= enable_i and (not issued_all);
				expected <= walk_pattern(chk_addr);
			when ADDR_RD =>
				req <= enable_i and (not issued_all);
				expected <= addr_pattern(chk_addr);
			when LFSR_RD =>
				req <= enable_i and (not issued_all);
				expected <= std_logic_vector(chk_lfsr(7 downto 0));
		end case;
	end process;

	------------------------------------------------------------------
	-- Sequencing and checking
	------------------------------------------------------------------
	process(clk_i, rst_i)
		variable phase_done: boolean;
	begin
		if (rst_i = '1') then
			phase <= WALK_WR;
			req_addr <= to_unsigned(FIRST, 19);
			chk_addr <= to_unsigned(FIRST, 19);
			issued_all <= '0';
			wr_lfsr <= x"ACE1";
			chk_lfsr <= x"ACE1";
			seed <= x"ACE1";
			passes <= (others => '0');
			errors <= (others => '0');
			first_addr <= (others => '0');
			first_data <= (others => '0');
		elsif rising_edge(clk_i) then
			phase_done := false;
			case phase is
				when WALK_WR | ADDR_WR | LFSR_WR =>
					if (m_gnt_i = '1') then
						wr_lfsr <= lfsr_step(wr_lfsr);
						if (req_addr = last_req) then
							phase_done := true;
						else
							req_addr <= req_addr + 1;
						end if;
					end if;
				when WALK_RD | ADDR_RD | LFSR_RD =>
					if (m_gnt_i = '1') then
						if (req_addr = last_req) then
							issued_all <= '1';
						else
							req_addr <= req_addr + 1;
						end if;
					end if;
					if (m_rvalid_i = '1') then
						if (m_rdata_i /= expected) then
							if (errors = 0) then
								first_addr <= chk_addr;
								first_data <= expected & m_rdata_i; -- Expected in 15:8, read in 7:0
							end if;
							if (errors /= x"FFFF") then
								errors <= errors + 1;
							end if;
						end if;
						chk_lfsr <= lfsr_step(chk_lfsr);
						if (chk_addr = last_req) then
							phase_done := true;
						else
							chk_addr <= chk_addr + 1;
						end if;
					end if;
			end case;
			if (phase_done) then
				req_addr <= to_unsigned(FIRST, 19);
				chk_addr <= to_unsigned(FIRST, 19);
				issued_all <= '0';
				case phase is
					when WALK_WR =>
						phase <= WALK_RD;
					when WALK_RD =>
						phase <= ADDR_WR;
					when ADDR_WR =>
						phase <= ADDR_RD;
					when ADDR_RD =>
						phase <= LFSR_WR;
						wr_lfsr <= seed;
						chk_lfsr <= seed;
					when LFSR_WR =>
						phase <= LFSR_RD;
					when LFSR_RD =>
						-- New seed each pass (never zero: bit 0 forced to '1')
						phase <= WALK_WR;
						passes <= passes + 1;
						seed <= lfsr_step(seed) or x"0001";
				end case;
			end if;
		end if;
	end process;

	m_req_o <= req;
	m_we_o <= we;
	m_addr_o <= std_logic_vector(req_addr);
	m_wdata_o <= wdata;
	phase_o <= std_logic_vector(to_unsigned(phase_t'pos(phase), 3));
	pass_count_o <= std_logic_vector(passes);
	error_count_o <= std_logic_vector(errors);
	first_error_addr_o <= std_logic_vector(first_addr);
	first_error_data_o <= first_data;
end arch;
